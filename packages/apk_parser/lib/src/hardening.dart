import 'package:archive_safety/archive_safety.dart';
import 'package:analysis_model/analysis_model.dart';

import 'package:archive/archive.dart';

/// 从容器结构中观察到的、与加固相关的特征。
///
/// **刻意不含任何厂商名。** 规范 4.2 明确要求「不要仅凭壳文件名、某个 SO
/// 或单一目录结构判断具体加固厂商」—— 把厂商写进枚举名，等于把那个被禁止的
/// 判定藏进了类型里。这里只描述可复现的结构事实。
enum HardeningSignal {
  /// 容器里没有 `classes.dex`。
  ///
  /// 正常构建的 APK 一定有它；缺失通常意味着主 DEX 被改名、移走或加密。
  missingPrimaryDex,

  /// 存在多个 `classesN.dex`（DEX 分片）。
  ///
  /// 单凭这一条**不足以**说明加固：未加固的现代应用因 64K 方法数上限也会分片。
  multipleDexFiles,

  /// 某个 DEX 文件的头部不是标准 `dex\n0xx` 魔数。
  ///
  /// 正常的构建流程不会产出这种文件，因此这条通常指向内容被加密或改写。
  dexHeaderNotStandard,

  /// `lib/<abi>/` 下存在不符合 `lib*.so` 命名约定的原生库。
  ///
  /// 只捕获**违反命名约定**的情况（例如 `lib/arm64-v8a/shell.so`）。
  /// **刻意不**匹配已知加固器的 SO 名 —— 那需要维护一份厂商名单，而规范
  /// 4.2 明确禁止据此类单一特征判定厂商。代价是漏报，换来的是不误导。
  unusualNativeLibraryName,

  /// `lib/<abi>/` 下的 `.so` **内容其实是 DEX 字节码**。
  ///
  /// 与 [dexHeaderNotStandard] 是两件事：
  ///
  /// | 信号 | 含义 |
  /// |---|---|
  /// | `dexHeaderNotStandard` | **文件名像 DEX**，但头部不是 `dex\n0xx`（被加密/改写） |
  /// | `dexDisguisedAsNativeLibrary` | **文件名像原生库**，但内容是真的 DEX |
  ///
  /// 后者是一种具体的隐藏手法：只扫 `classes*.dex` 的工具会完全看不到这段代码，
  /// 而运行时用 `DexClassLoader` 从 `lib/` 目录直接加载它。
  ///
  /// 实测来源：`抖音-v40.7.0` 的 `lib/arm64-v8a/libsm_impl.so`（162,912 字节，
  /// 头部 `dex\n035`）。**只看文件名的检查永远发现不了它。**
  dexDisguisedAsNativeLibrary,

  /// `assets/` 下存在代码类文件（`.dex` / `.jar` / `.so`）。
  ///
  /// `assets/` 是给应用读取的原始资源目录，正常构建不会往里放可执行代码。
  executableInAssets,

  /// 归档里存在「父路径同时也是一个文件条目」的条目。
  ///
  /// ZIP 的名字空间里，同一个字符串既被当作文件、又被当作目录前缀 ——
  /// 例如 `AndroidManifest.xml` 是文件，而 `AndroidManifest.xml/..xml`
  /// 又把它当目录。实测的真实加固样本里有 **216** 条这样的条目，
  /// 占全部 2242 条约 10%。
  ///
  /// 正常构建流程不会产出这种结构。它的唯一用处是让「按名字查找关键文件」的
  /// 工具读到诱饵：不同解压器对「同名文件与目录」的取舍不同，于是同一个包
  /// 在不同工具下会解析出不同结果。
  ///
  /// 只描述这个结构事实，不推断是哪家的加固器。
  decoyArchiveEntries,

  /// `AndroidManifest.xml` 的二进制布局不符合标准 AXML。
  ///
  /// 具体形态由证据文本给出，常见的有：`attributeStart` / `attributeSize`
  /// 被放大（属性区之前塞了诱饵字节）、出现标准范围之外的 chunk 类型。
  ///
  /// 与其它线索一样，只描述结构事实，不推断是哪家的加固器。这条来自
  /// **manifest 层**而不是容器层，因此由 [ManifestParser] 的解析结果提供，
  /// 见 `ApkMeta.manifestLayoutAnomalies`。
  manifestLayoutAnomaly,

  /// `resources.arsc` 缺失或异常小，而 DEX 规模不小。
  ///
  /// 资源表是 Android 应用的必备件；在 DEX 有相当体量的前提下它却几乎不存在，
  /// 通常说明资源表被剥离或替换。
  resourceTableAnomaly,
}

/// 一条观察到的加固特征及其证据。
///
/// [evidence] 是「可解释」的关键：用户看到的不该只是一句「可能被加固」，
/// 而是「因为看到了什么」。
class HardeningObservation {
  final HardeningSignal signal;

  /// 英文证据（日志、加固线索列表、报告的回退文本）。
  final String evidence;

  /// **结构化版本**：稳定 code + 参数，界面按 code 查本地化模板。
  ///
  /// `null` 表示这条证据还没有迁移 —— 此时界面会退回 [evidence] 的英文原文
  /// （见 [asNote]）。迁移是增量的，不必一次做完。
  final AnalysisNote? note;

  const HardeningObservation(this.signal, this.evidence, {this.note});

  /// 报告用的结构化说明：优先 [note]，否则把英文证据包成通用 code。
  ///
  /// 通用 code 的文案模板是「容器/解析异常可能影响覆盖完整性：{anomaly}」——
  /// 中文前缀 + 英文正文，比完全不显示要好，但仍不如 [note] 精确。
  AnalysisNote get asNote =>
      note ??
      AnalysisNote(
          'android.container.anomaly', evidence, {'anomaly': evidence});

  @override
  String toString() => '${signal.name}: $evidence';
}

/// 扫描归档结构，收集可解释的加固线索。
///
/// 只读条目名与 DEX 文件头，不额外解压任何内容（`Archive` 在解码阶段已经把
/// 条目内容物化在内存里），因此开销很低。
class HardeningScanner {
  HardeningScanner._();

  /// 判定 `resources.arsc` 「异常小」的阈值。
  ///
  /// 取 1 KiB 是刻意保守：真实应用的资源表几乎不会低于这个量级，
  /// 阈值定高了反而会把小体积应用误报成异常。
  static const int resourceTableMinPlausibleSize = 1024;

  /// 判定「DEX 规模不小」的阈值（64 KiB）。
  ///
  /// 只有 DEX 有体量时，资源表缺失才值得怀疑 —— 一个只有几行代码的
  /// 玩具应用完全可以没有资源表。
  static const int dexSubstantialSize = 64 * 1024;

  /// 检查「祖先路径是否为文件条目」时最多往前看几层。
  static const int _maxAncestorDepth = 8;

  static final _dexNamePattern = RegExp(r'^classes(\d*)\.dex$');
  static final _nativeLibPattern = RegExp(r'^lib/([^/]+)/([^/]+)$');

  static List<HardeningObservation> scan(
    Archive archive, {
    BoundedReadLedger? ledger,
  }) {
    final observations = <HardeningObservation>[];
    final readLedger = ledger ??
        BoundedReadLedger(maxTotalBytes: ZipBudgetLimits.maxSessionOutputBytes);

    final fileEntries = archive.files.where((f) => f.isFile).toList();

    // ---- DEX ----
    final dexEntries =
        fileEntries.where((f) => _dexNamePattern.hasMatch(f.name)).toList();

    if (dexEntries.isEmpty) {
      observations.add(const HardeningObservation(
        HardeningSignal.missingPrimaryDex,
        'no classes.dex / classesN.dex entry in the archive root',
        note: AnalysisNote(
          'android.container.missing_primary_dex',
          'no classes.dex / classesN.dex entry in the archive root',
        ),
      ));
    } else {
      if (dexEntries.length > 1) {
        final dexNames = dexEntries.map((f) => f.name).toList()..sort();
        final shown = '${dexNames.take(8).join(', ')}'
            '${dexNames.length > 8 ? ', …' : ''}';
        observations.add(HardeningObservation(
          HardeningSignal.multipleDexFiles,
          '${dexEntries.length} DEX entries: $shown',
          note: AnalysisNote(
            'android.container.multiple_dex_files',
            '${dexEntries.length} DEX entries: $shown',
            {
              'count': dexEntries.length,
              'names': dexNames.take(8).toList(),
            },
          ),
        ));
      }

      for (final entry in dexEntries) {
        final header = _readHeader(entry, 8, readLedger);
        if (header == null) {
          observations.add(HardeningObservation(
            HardeningSignal.dexHeaderNotStandard,
            '${entry.name}: entry could not be read',
            note: AnalysisNote(
              'android.container.dex_header_unreadable',
              '${entry.name}: entry could not be read',
              {'name': entry.name},
            ),
          ));
          continue;
        }
        if (!_hasDexMagic(header)) {
          observations.add(HardeningObservation(
            HardeningSignal.dexHeaderNotStandard,
            '${entry.name}: header is ${_hex(header)} '
            '(expected "dex\\n0xx")',
            note: AnalysisNote(
              'android.container.dex_header_not_standard',
              '${entry.name}: header is ${_hex(header)}',
              {'name': entry.name, 'header': _hex(header)},
            ),
          ));
        }
      }
    }

    // ---- 原生库命名 ----
    for (final entry in fileEntries) {
      final match = _nativeLibPattern.firstMatch(entry.name);
      if (match == null) continue;
      final fileName = match.group(2)!;
      // Android 约定：lib/ 下的共享库必须以 lib 开头、以 .so 结尾。
      if (!fileName.startsWith('lib') || !fileName.endsWith('.so')) {
        observations.add(HardeningObservation(
          HardeningSignal.unusualNativeLibraryName,
          entry.name,
          note: AnalysisNote(
            'android.container.unusual_native_library',
            entry.name,
            {'name': entry.name},
          ),
        ));
      }
    }

    // ---- 原生库内容其实是 DEX ----
    //
    // 只读前 8 字节（`dex\n0xx`），走同一套有界读取。
    // 这是**内容**判据，与上面的命名判据互补：命名的检查抓的是
    // `lib/arm64-v8a/shell.so` 这种不合约定，这里抓的是
    // `lib/arm64-v8a/libsm_impl.so` 这种**名字完全合规、内容是代码**的。
    for (final entry in fileEntries) {
      if (_nativeLibPattern.firstMatch(entry.name) == null) continue;
      final header = _readHeader(entry, 8, readLedger);
      if (header == null) continue;
      if (_hasDexMagic(header)) {
        observations.add(HardeningObservation(
          HardeningSignal.dexDisguisedAsNativeLibrary,
          '${entry.name}: content is DEX (${_hex(header)})',
          note: AnalysisNote(
            'android.container.dex_in_native_library',
            '${entry.name}: content is DEX, not a shared library',
            {'name': entry.name},
          ),
        ));
      }
    }

    // ---- assets 下的代码类文件 ----
    for (final entry in fileEntries) {
      if (!entry.name.startsWith('assets/')) continue;
      final lower = entry.name.toLowerCase();
      if (lower.endsWith('.dex') ||
          lower.endsWith('.jar') ||
          lower.endsWith('.so')) {
        observations.add(HardeningObservation(
          HardeningSignal.executableInAssets,
          entry.name,
          note: AnalysisNote(
            'android.container.executable_in_assets',
            entry.name,
            {'name': entry.name},
          ),
        ));
      }
    }

    // ---- 路径形状的诱饵条目 ----
    //
    // 判据是「某个祖先路径同时也是一个文件条目的名字」——一个自相矛盾的
    // 结构。不按「名字里有没有 `..`」判：那样会漏掉
    // `AndroidManifest.xml/ .xml` 这类不含点点的诱饵，也会误报
    // `assets/a..b.png` 这种正常文件。
    final fileNames =
        fileEntries.map((f) => f.name.replaceAll('\\', '/')).toSet();
    final decoyEntries = <String>[];
    for (final name in fileNames) {
      final parts = name.split('/');
      // 只往前看有限层：路径深度在正常包里很小，而恶意包可以把路径做得很深，
      // 没必要为此付出 O(深度) 的代价。
      final limit =
          parts.length <= _maxAncestorDepth ? parts.length : _maxAncestorDepth;
      for (var k = 1; k < limit; k++) {
        if (fileNames.contains(parts.sublist(0, k).join('/'))) {
          decoyEntries.add(name);
          break;
        }
      }
    }
    if (decoyEntries.isNotEmpty) {
      final samples = decoyEntries.take(4).join(', ');
      observations.add(HardeningObservation(
        HardeningSignal.decoyArchiveEntries,
        '${decoyEntries.length} entries use a file entry as a directory '
        'prefix, e.g. $samples',
        note: AnalysisNote(
          'android.container.decoy_entries',
          '${decoyEntries.length} entries use a file entry as a directory '
              'prefix, e.g. $samples',
          {'count': decoyEntries.length, 'samples': samples},
        ),
      ));
    }

    // ---- 资源表 ----
    final arsc = fileEntries.where((f) => f.name == 'resources.arsc').toList();
    final hasSubstantialDex =
        dexEntries.any((f) => f.size >= dexSubstantialSize);
    if (hasSubstantialDex) {
      if (arsc.isEmpty) {
        observations.add(const HardeningObservation(
          HardeningSignal.resourceTableAnomaly,
          'resources.arsc is missing while a DEX entry is >= 64 KiB',
          note: AnalysisNote(
            'android.container.resource_table_missing',
            'resources.arsc is missing while a DEX entry is >= 64 KiB',
          ),
        ));
      } else if (arsc.first.size < resourceTableMinPlausibleSize) {
        observations.add(HardeningObservation(
          HardeningSignal.resourceTableAnomaly,
          'resources.arsc is only ${arsc.first.size} bytes',
          note: AnalysisNote(
            'android.container.resource_table_too_small',
            'resources.arsc is only ${arsc.first.size} bytes',
            {'size': arsc.first.size},
          ),
        ));
      }
    }

    return observations;
  }

  /// 读取条目前 [length] 个字节。
  ///
  /// **走有界前缀读取**（V2.4.12）：此前这里用 `entry.content` —— 为了看 8 个
  /// 字节把整条 DEX 解压一遍（343 MB 的包实测 30ms → 896ms），而且是一条
  /// **无上限**的解压路径。现在只解到 64 KiB 就停。
  static List<int>? _readHeader(
    ArchiveFile entry,
    int length,
    BoundedReadLedger ledger,
  ) {
    final read = readEntryPrefix(
      entry,
      maxBytes: _headerProbeBytes,
      ledger: ledger,
    );
    final content = read.bytes;
    if (content == null || content.length < length) return null;
    return content.sublist(0, length);
  }

  /// 嗅探文件头时最多解压多少字节。
  ///
  /// 8 字节就够判断 DEX 魔数，给到 64 KiB 是为了让「一次 `decompress` 就能
  /// 拿到第一块」—— 再小也只是同一块，不会更快。
  static const int _headerProbeBytes = 64 * 1024;

  /// 标准 DEX 魔数为 `dex\n` + 版本号（ASCII 数字），例如 `dex\n035\0`。
  static bool _hasDexMagic(List<int> header) {
    if (header.length < 5) return false;
    return header[0] == 0x64 && // 'd'
        header[1] == 0x65 && // 'e'
        header[2] == 0x78 && // 'x'
        header[3] == 0x0A && // '\n'
        header[4] == 0x30; // '0'
  }

  static String _hex(List<int> bytes) =>
      bytes.map((b) => '0x${b.toRadixString(16).padLeft(2, '0')}').join(' ');
}
