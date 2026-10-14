import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:logging/logging.dart';
import 'package:archive_safety/archive_safety.dart';

import 'container_structure.dart';
import 'hardening.dart';
import 'manifest_parser.dart';
import 'arsc_parser.dart';
import 'models.dart';

final _log = Logger('ApkReader');

/// 解析推进到的阶段。
///
/// 用途是向 UI 报告**真实**进度，因此只暴露实际可观测的边界，
/// 不提供虚构的百分比。
enum ApkParseStage {
  /// 打开归档容器（由调用方在 [ApkReader.open] 前后报告）。
  openContainer,

  /// 解析 `AndroidManifest.xml`。
  manifest,

  /// 解析 `resources.arsc` 资源表 —— 通常是耗时最长的一步。
  resources,

  /// 扫描 `lib/` 下的原生库，得到 ABI 列表。
  nativeLibraries,

  /// 全部完成。
  done,
}

/// APK 文件读取和解析的统一入口
class ApkReader {
  Archive? _archive;

  /// 最近一次 [parse] 的结果。
  ///
  /// 保存它是为了让 [scanHardeningSignals] 能带上 manifest 层的线索 ——
  /// 那一层的信息只有在 manifest 解出来之后才存在。
  ApkMeta? _meta;
  ArscParser? _arscParser;

  /// 最近一次打开时发现的**结构异常**说明；正常时为 `null`。
  ///
  /// 目前只有一项：EOCD 声明的条目数与实际解析出的不一致（被裁剪或拼接的
  /// 归档）。**不拒绝打开** —— 这类不一致在正常打包工具产出的包里几乎不会
  /// 出现，但也不是绝对不可能（某些自研打包器会留下不一致的注释长度），
  /// 因此记为异常供上层参考，而不是直接判死。
  String? structureAnomaly;

  /// 打开 APK 文件（ZIP 格式）。
  ///
  /// 返回具体的失败原因而非笼统的 `false`：调用方需要区分
  /// 「不是归档」「归档损坏」「命中解压预算」「IO 失败」。
  Future<ArchiveOpenResult> open(String filePath) async {
    InputFileStream? inputStream;
    try {
      if (!looksLikeZip(await readArchiveHeader(filePath))) {
        return ArchiveOpenResult.notArchive;
      }
      final length = await File(filePath).length();
      inputStream = InputFileStream(filePath);
      final archive = ZipDecoder().decodeStream(inputStream);
      if (looksStructurallyBroken(archive, length)) {
        _log.warning('open failed: $filePath looks structurally broken');
        _archive = null;
        return ArchiveOpenResult.corrupt;
      }
      if (ZipBudget.isExceeded(archive)) {
        _log.warning(
            'open refused: $filePath exceeds the decompression budget');
        _archive = null;
        return ArchiveOpenResult.resourceBudgetExceeded;
      }
      // 流式解码拿不到原始字节，改为**只读文件尾部**再找 EOCD —— 读
      // `maxTailBytes`（约 64 KiB）就够，不必把几百 MB 的包读进内存。
      structureAnomaly =
          await _checkEntryCountFromFile(filePath, archive.files.length);
      if (structureAnomaly != null) {
        _log.warning('open: structural anomaly: $structureAnomaly');
      }
      _archive = archive;
      return ArchiveOpenResult.ok;
    } on FileSystemException catch (e) {
      _log.warning('open failed (io): $e');
      return ArchiveOpenResult.ioError;
    } catch (e, stackTrace) {
      _log.warning('open failed: $e\n$stackTrace');
      return ArchiveOpenResult.corrupt;
    } finally {
      inputStream?.closeSync();
    }
  }

  /// 从内存数据打开（用于嵌套 ZIP 场景）
  ArchiveOpenResult openBytes(Uint8List data) {
    try {
      if (!looksLikeZip(data)) {
        return ArchiveOpenResult.notArchive;
      }
      final archive = ZipDecoder().decodeBytes(data);
      if (looksStructurallyBroken(archive, data.length)) {
        return ArchiveOpenResult.corrupt;
      }
      if (ZipBudget.isExceeded(archive)) {
        _archive = null;
        return ArchiveOpenResult.resourceBudgetExceeded;
      }
      // EOCD 声明的条目数与实际条目数比对（这里手上就有完整字节）。
      structureAnomaly =
          ZipStructure.checkEntryCount(data, archive.files.length);
      if (structureAnomaly != null) {
        _log.warning('openBytes: structural anomaly: $structureAnomaly');
      }
      _archive = archive;
      return ArchiveOpenResult.ok;
    } catch (e, stackTrace) {
      _log.warning('openBytes failed: $e\n$stackTrace');
      return ArchiveOpenResult.corrupt;
    }
  }

  /// 只读文件尾部，比对 EOCD 声明的条目数与实际条目数。
  ///
  /// 供流式路径 [open] 使用：`ZipDecoder().decodeStream` 不保留原始字节，
  /// 但 EOCD 必然位于文件末尾 [ZipStructure.maxTailBytes] 字节以内，因此
  /// 单独读这一小段即可。
  ///
  /// 读不到 EOCD（例如调用方传了个不完整的尾部）时返回 `null` ——
  /// **不把「读不到」当异常**，避免误报。
  Future<String?> _checkEntryCountFromFile(
    String filePath,
    int actualCount,
  ) async {
    RandomAccessFile? raf;
    try {
      final length = await File(filePath).length();
      if (length < ZipStructure.eocdLength) return null;
      final tailLength = length < ZipStructure.maxTailBytes
          ? length
          : ZipStructure.maxTailBytes;

      raf = await File(filePath).open();
      await raf.setPosition(length - tailLength);
      final tail = await raf.read(tailLength);
      return ZipStructure.checkEntryCount(tail, actualCount);
    } catch (e) {
      // 读尾部失败只是少了一项检查，不该让整个打开流程失败。
      _log.warning('_checkEntryCountFromFile failed: $e');
      return null;
    } finally {
      await raf?.close();
    }
  }

  /// 解析 APK 基础信息。
  ///
  /// [onStage] 在每个阶段**开始时**被调用，用于向调用方报告真实进度。
  ///
  /// 刻意不提供百分比：各阶段耗时分布极不均匀（`resources.arsc` 通常占绝大
  /// 部分），编一个百分比只会误导用户。阶段本身就是最细的可信粒度。
  Future<ApkMeta?> parse({void Function(ApkParseStage stage)? onStage}) async {
    final archive = _archive;
    if (archive == null) return null;

    // 1. 读取并解析 AndroidManifest.xml
    onStage?.call(ApkParseStage.manifest);
    final manifestFile = archive.findFile('AndroidManifest.xml');
    if (manifestFile == null) return null;
    final rawManifestBytes = manifestFile.content;
    final manifestBytes =
        rawManifestBytes.buffer.lengthInBytes == rawManifestBytes.length
            ? rawManifestBytes
            : Uint8List.fromList(rawManifestBytes);
    final meta = ManifestParser.parse(manifestBytes);
    // 记下来供 scanHardeningSignals 使用 —— manifest 层的加固线索只能在
    // 解析之后才有，而那个方法是在 parse 之后被调用的。
    _meta = meta;

    // 2. 读取并解析 resources.arsc
    onStage?.call(ApkParseStage.resources);
    final arscFile = archive.findFile('resources.arsc');
    if (arscFile != null) {
      // 确保 arscBytes 是独立的 Uint8List（而非底层 ZIP 缓冲区的 view），
      // 避免 ByteDataReader 操作时因 buffer offset 不一致导致 RangeError。
      final rawArscBytes = arscFile.content;
      final arscBytes = rawArscBytes.buffer.lengthInBytes == rawArscBytes.length
          ? rawArscBytes
          : Uint8List.fromList(rawArscBytes);
      try {
        _arscParser = ArscParser(arscBytes);
        _resolveLabel(meta);
        _resolveIconPaths(meta);
        meta.locales = _arscParser!.getLocales().toList();
        meta.densities = _arscParser!.getDensities().toList();
        // 只有资源表真的解析成功了才设这两项 —— 保持 `null` 表示「没读到」，
        // 免得把「资源表解析失败」呈现成「没有夜间资源」。
        meta.hasNightMode = _arscParser!.hasNightModeResources;
        meta.uiModeTypes = _arscParser!.getUiModeTypes();
      } catch (e, stackTrace) {
        // arsc 解析失败不影响基本信息，但记录详细错误便于排查
        _log.warning('arsc parse failed: $e\n$stackTrace');
      }
    }

    // 3. 扫描 lib/ 目录获取 native codes
    onStage?.call(ApkParseStage.nativeLibraries);
    meta.nativeCodes = _scanNativeCodes();

    onStage?.call(ApkParseStage.done);
    return meta;
  }

  ArscParser? get arscParser => _arscParser;

  /// 收集容器结构信息（DEX 数量、原生库、ABI、顶层目录、解压后总字节数）。
  ///
  /// 需要在 [open] 之后调用；未打开时返回空结构。
  ContainerStructure collectStructure() {
    final archive = _archive;
    if (archive == null) return const ContainerStructure();
    return ContainerStructureCollector.collect(archive);
  }

  /// 扫描容器结构，收集可解释的加固线索。
  ///
  /// 需要在 [open] 之后调用；未打开时返回空列表。
  ///
  /// 只观察结构事实（DEX 分片与头部、原生库命名、assets 布局、资源表），
  /// **不做厂商判定** —— 见 [HardeningSignal] 的说明。
  List<HardeningObservation> scanHardeningSignals() {
    final archive = _archive;
    if (archive == null) return const [];

    return [
      // 容器层的结构事实（条目名、DEX、SO、资源表）。
      ...HardeningScanner.scan(archive),
      // manifest 层的结构事实（非标准 AXML 布局）。
      //
      // 与容器层分开是因为它们来自不同的解析阶段：容器层只看条目名，
      // 这一层要先把 manifest 解出来。两处的判据都是「正常构建流程不会
      // 产出这个结构」，与具体是哪家的加固器无关。
      for (final evidence in _meta?.manifestLayoutAnomalies ?? const [])
        HardeningObservation(
          HardeningSignal.manifestLayoutAnomaly,
          evidence,
        ),
    ];
  }

  Uint8List? readFile(String fileName) {
    final file = _archive?.findFile(fileName);
    return file?.content;
  }

  List<String> listFiles({String? extension}) {
    final files = _archive?.files ?? [];
    final lowerExt = extension?.toLowerCase();
    return files
        .where((f) => f.isFile)
        .map((f) => f.name)
        .where(
            (name) => lowerExt == null || name.toLowerCase().endsWith(lowerExt))
        .toList();
  }

  void _resolveLabel(ApkMeta meta) {
    final parser = _arscParser;
    if (parser == null) return;

    if (meta.label != null && meta.label!.startsWith('@res/0x')) {
      final resId = int.tryParse(meta.label!.substring(7), radix: 16);
      if (resId != null) {
        final resolved = parser.getStringValue(resId);
        if (resolved != null) meta.label = resolved;

        for (final locale in parser.getLocales()) {
          final localizedLabel = parser.getStringValue(resId, locale: locale);
          if (localizedLabel != null) {
            meta.labels[locale] = localizedLabel;
          }
        }
      }
    }
  }

  void _resolveIconPaths(ApkMeta meta) {
    final parser = _arscParser;
    if (parser == null) return;

    final iconRef = meta.applicationIcon;
    if (iconRef == null || !iconRef.startsWith('@res/0x')) return;

    final resId = int.tryParse(iconRef.substring(7), radix: 16);
    if (resId == null) return;

    final paths = parser.getAllFilePaths(resId);
    for (final entry in paths) {
      meta.iconPaths[entry.key] = entry.value;
    }
  }

  List<String> _scanNativeCodes() {
    final archive = _archive;
    if (archive == null) return [];

    final abis = <String>{};
    for (final file in archive.files) {
      if (!file.isFile) continue;
      final name = file.name;
      if (name.startsWith('lib/')) {
        final parts = name.split('/');
        if (parts.length >= 3) {
          abis.add(parts[1]);
        }
      }
    }
    return abis.toList()..sort();
  }

  void close() {
    _archive?.clearSync();
    _archive = null;
    _arscParser = null;
  }
}
