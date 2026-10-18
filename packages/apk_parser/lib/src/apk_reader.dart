import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:logging/logging.dart';
import 'package:archive_safety/archive_safety.dart';

import 'container_structure.dart';
import 'icp_filing.dart';
import 'hardening.dart';
import 'manifest_parser.dart';
import 'arsc_parser.dart';
import 'apk_signing_block.dart';
import 'models.dart';
import 'security/network_security_config.dart';

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

  /// [open] 传进来的路径；[openBytes] 时为 `null`。
  ///
  /// 解析 APK Signing Block 需要随机读文件尾部 —— 归档对象本身不保留原始
  /// 字节（`decodeStream`），所以只能记路径、事后再读两次小范围。
  String? _filePath;

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

  /// 最近一次 [parse] 里 manifest 未能解析的原因；成功时为 `null`。
  ///
  /// [parse] 在「文件里没有 manifest」与「manifest 解析失败」两种情况下都
  /// 返回 `null`，但这两件事的措辞不该一样 —— 前者是事实，后者意味着
  /// 我们没读到。调用方读这个字段来区分。
  String? manifestFailure;

  /// 最近一次 [parse] 里 `resources.arsc` 解析失败的原因；成功或没有该文件
  /// 时为 `null`。
  ///
  /// 与「资源表里没有这一项」分开：`ApkMeta.hasNightMode` 保持 `null` 表示
  /// 「没读到」，而这个字段说明**为什么**没读到。
  String? arscParseFailure;

  /// 最近一次 [open] / [openBytes] 因解压预算被拒绝时的**具体原因**；
  /// 其余情况为 `null`。
  ///
  /// 只返回 `resourceBudgetExceeded` 这个枚举值时，界面只能显示「超出安全
  /// 解压上限」—— 用户既不知道是哪个条目，也不知道超了多少，更没法判断这
  /// 是不是自己那个包本身有问题。这里补上「哪个条目 + 声明/实际多少字节 +
  /// 上限多少」。
  String? budgetFailure;

  /// 打开 APK 文件（ZIP 格式）。
  ///
  /// 返回具体的失败原因而非笼统的 `false`：调用方需要区分
  /// 「不是归档」「归档损坏」「命中解压预算」「IO 失败」。
  Future<ArchiveOpenResult> open(String filePath) async {
    InputFileStream? inputStream;
    budgetFailure = null;
    _filePath = filePath;
    try {
      if (!looksLikeZip(await readArchiveHeader(filePath))) {
        return ArchiveOpenResult.notArchive;
      }
      final length = await File(filePath).length();
      inputStream = InputFileStream(filePath);
      _ledger = BoundedReadLedger(
        maxTotalBytes: ZipBudgetLimits.maxSessionOutputBytes,
      );
      final archive = ZipDecoder().decodeStream(inputStream);
      if (looksStructurallyBroken(archive, length)) {
        _log.warning('open failed: $filePath looks structurally broken');
        _archive = null;
        return ArchiveOpenResult.corrupt;
      }
      final violation = ZipBudget.check(archive);
      if (violation != null) {
        budgetFailure = violation.describe();
        _log.warning('open refused: $filePath — $budgetFailure');
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
    budgetFailure = null;
    try {
      if (!looksLikeZip(data)) {
        return ArchiveOpenResult.notArchive;
      }
      _ledger = BoundedReadLedger(
        maxTotalBytes: ZipBudgetLimits.maxSessionOutputBytes,
      );
      final archive = ZipDecoder().decodeBytes(data);
      if (looksStructurallyBroken(archive, data.length)) {
        return ArchiveOpenResult.corrupt;
      }
      final violation = ZipBudget.check(archive);
      if (violation != null) {
        budgetFailure = violation.describe();
        _log.warning('openBytes refused: $budgetFailure');
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
    if (manifestFile == null) {
      // 「文件里没有」与「我们没读到」要分得开：两者都会让 parse 返回 null，
      // 但原因不同，报告里的措辞也该不同。
      manifestFailure = 'AndroidManifest.xml not found in the archive';
      return null;
    }
    // **有界读取**（V2.4.12）：manifest 也可能被零填充到几十 MB，
    // 而 `file.content` 是无上限的。
    final manifestRead = ZipBudget.readEntry(manifestFile, ledger: _ledger);
    if (!manifestRead.isOk) {
      manifestFailure = 'AndroidManifest.xml was refused: '
          '${manifestRead.failure?.describe()}';
      _log.warning('parse: $manifestFailure');
      return null;
    }
    final rawManifestBytes = manifestRead.bytes!;
    final manifestBytes =
        rawManifestBytes.buffer.lengthInBytes == rawManifestBytes.length
            ? rawManifestBytes
            : Uint8List.fromList(rawManifestBytes);
    final meta = ManifestParser.parse(manifestBytes);
    if (meta.manifestUnparsed) {
      manifestFailure = 'AndroidManifest.xml could not be parsed: '
          '${meta.manifestParseFailure}';
      return null;
    }
    manifestFailure = null;
    // 记下来供 scanHardeningSignals 使用 —— manifest 层的加固线索只能在
    // 解析之后才有，而那个方法是在 parse 之后被调用的。
    _meta = meta;

    // 1.5 APK Signing Block（v2 / v3 签名方案）。
    //
    // **失败不阻断解析**：这一段回答的是「有没有 v2+ 签名块」，
    // 读不出来时记下原因即可 —— 基本信息与安全分析都不该因此拿不到。
    meta.signingSchemes = _readSigningSchemes();
    if (meta.signingSchemes != null && !meta.signingSchemes!.parsed) {
      _log.warning('signing block: ${meta.signingSchemes!.failure}');
    }

    // 2. 读取并解析 resources.arsc
    onStage?.call(ApkParseStage.resources);
    final arscFile = archive.findFile('resources.arsc');
    if (arscFile != null) {
      // 确保 arscBytes 是独立的 Uint8List（而非底层 ZIP 缓冲区的 view），
      // 避免 ByteDataReader 操作时因 buffer offset 不一致导致 RangeError。
      final arscRead = ZipBudget.readEntry(arscFile, ledger: _ledger);
      if (!arscRead.isOk) {
        arscParseFailure = 'resources.arsc was refused: '
            '${arscRead.failure?.describe()}';
        _log.warning('parse: $arscParseFailure');
      }
      final rawArscBytes = arscRead.bytes ?? Uint8List(0);
      final arscBytes = rawArscBytes.buffer.lengthInBytes == rawArscBytes.length
          ? rawArscBytes
          : Uint8List.fromList(rawArscBytes);
      final parser = ArscParser(arscBytes);
      if (parser.parseFailure != null) {
        // 资源表读不出来不影响基本信息，但要把原因记下来 ——
        // 「资源表解析失败」与「资源表里没有这一项」是两件事。
        arscParseFailure = parser.parseFailure;
        _log.warning('arsc parse failed: ${parser.parseFailure}');
      } else {
        _arscParser = parser;
        _resolveLabel(meta);
        _resolveIconPaths(meta);
        meta.locales = parser.getLocales().toList();
        meta.densities = parser.getDensities().toList();
        // 只有资源表真的解析成功了才设这两项 —— 保持 `null` 表示「没读到」，
        // 免得把「资源表解析失败」呈现成「没有夜间资源」。
        meta.hasNightMode = parser.hasNightModeResources;
        meta.uiModeTypes = parser.getUiModeTypes();
        // ICP 备案号：只能从字符串池里找（manifest 里没有标准字段）。
        // 放在这一支里是因为它要用刚解析好的字符串池 —— 没读到资源表就没有。
        meta.icpFilings = IcpFilingScanner.scan(parser.globalStringPool);
        // 网络安全配置：声明了它之后 `usesCleartextTraffic` 就被平台忽略，
        // 明文策略完全由这份 XML 决定。必须真的打开它，否则规则 D 在
        // 真实包上要么误报、要么静默失效（实测 3/5 个真实包属于这种情况）。
        _resolveNetworkSecurityConfig(meta);
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
      // 字符串版与结构化版**按下标一一对应**（`manifest_parser` 同时填两份）。
      for (final (i, evidence)
          in (_meta?.manifestLayoutAnomalies ?? const <String>[]).indexed)
        HardeningObservation(
          HardeningSignal.manifestLayoutAnomaly,
          evidence,
          note: i < (_meta?.manifestLayoutNotes.length ?? 0)
              ? _meta!.manifestLayoutNotes[i]
              : null,
        ),
    ];
  }

  /// 本次打开期间的**共享**读取预算（V2.4.12）。
  ///
  /// 同一个归档里的所有条目共用一个 ledger —— 否则「几千个条目各自在限额内、
  /// 加起来几十 GiB」就没人管。每次 `open` / `openBytes` 重置。
  BoundedReadLedger _ledger = BoundedReadLedger(
    maxTotalBytes: ZipBudgetLimits.maxSessionOutputBytes,
  );

  Uint8List? readFile(String fileName) {
    final file = _archive?.findFile(fileName);
    if (file == null) return null;
    // **两道闸**：声明值 + 实际产出。中央目录可以撒谎 —— 实测把 100 MiB 条目的
    // CD `uncompressedSize` 改成 1024，`ZipBudget.check` 会放行。见
    // `ZipBudget.readEntry` 的注释（含「峰值内存仍不受限」这条已知局限）。
    final read = ZipBudget.readEntry(file, ledger: _ledger);
    if (!read.isOk) {
      _log.warning('readFile refused: ${read.failure?.describe()}');
      return null;
    }
    return read.bytes;
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

  /// 列出匹配扩展名的条目及其**声明的**解压后尺寸。
  ///
  /// 存在的理由是**预算必须在读取之前判定** —— 读进来才知道大小就已经晚了，
  /// 那正是「先分配再检查」的老问题。尺寸取自 ZIP 头部（`ZipFile.size`），
  /// 因此是**声明值**：少报时无法阻止分配，只能读完复核（与归档层的取舍一致）。
  List<({String name, int size})> listFilesWithSize({String? extension}) {
    final files = _archive?.files ?? [];
    final lowerExt = extension?.toLowerCase();
    return [
      for (final file in files)
        if (file.isFile &&
            (lowerExt == null || file.name.toLowerCase().endsWith(lowerExt)))
          (name: file.name, size: file.size),
    ];
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

  /// 读 APK Signing Block。返回 `null` 表示**没法读**（不是「没有签名」）。
  ///
  /// 走两次有界读：先读 EOCD（尾部 ≤64 KiB），再按需读签名块本身。
  /// 不把整份文件读进内存 —— 真实 APK 有几百 MB。
  ApkSigningSchemes? _readSigningSchemes() {
    final path = _filePath;
    if (path == null) return null;
    RandomAccessFile? raf;
    try {
      raf = File(path).openSync();
      final length = raf.lengthSync();
      return parseApkSigningBlock(
        fileLength: length,
        read: (offset, count) {
          // 边界钳制：任何越界都返回空，由解析器报「读不到」，
          // 而不是让 RangeError 冒到这里。
          if (offset < 0 || count <= 0 || offset + count > length) {
            return Uint8List(0);
          }
          raf!.setPositionSync(offset);
          return raf.readSync(count);
        },
      );
    } catch (e) {
      _log.warning('read signing block failed: $e');
      return ApkSigningSchemes.unreadable('I/O error: $e');
    } finally {
      raf?.closeSync();
    }
  }

  /// 展开 `<application android:networkSecurityConfig>` 指向的 XML。
  ///
  /// 链路：资源 id → `resources.arsc` 里的文件路径 → 归档条目 → AXML。
  /// **每一步都可能失败**，而失败必须被记下来：`ApkMeta.networkSecurityConfigInfo`
  /// 的 `failure` 非空即表示「声明了但没读到」，与「没声明」（`null`）
  /// 是两件事，规则引擎与界面都要能分辨。
  void _resolveNetworkSecurityConfig(ApkMeta meta) {
    final resId = meta.networkSecurityConfigResId;
    if (resId == null) return;
    final parser = _arscParser;
    final archive = _archive;
    if (parser == null || archive == null) return;

    final path = parser.getFilePath(resId);
    if (path == null) {
      meta.networkSecurityConfigInfo = NetworkSecurityConfigInfo(
        path: '@res/0x${resId.toRadixString(16)}',
        failure: 'the resource id does not resolve to a file path',
      );
      return;
    }

    final entry = archive.findFile(path);
    if (entry == null) {
      meta.networkSecurityConfigInfo = NetworkSecurityConfigInfo(
        path: path,
        failure: 'the resolved path is not present in the archive',
      );
      return;
    }
    // 与 manifest 一样走**有界读取**：这条 XML 同样可以被零填充撑大。
    final read = ZipBudget.readEntry(entry, ledger: _ledger);
    if (!read.isOk) {
      meta.networkSecurityConfigInfo = NetworkSecurityConfigInfo(
        path: path,
        failure: 'the entry was refused: ${read.failure?.describe()}',
      );
      return;
    }
    meta.networkSecurityConfigInfo =
        parseNetworkSecurityConfig(read.bytes, path: path);
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
