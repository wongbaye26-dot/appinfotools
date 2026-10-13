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

  /// `assets/` 下存在代码类文件（`.dex` / `.jar` / `.so`）。
  ///
  /// `assets/` 是给应用读取的原始资源目录，正常构建不会往里放可执行代码。
  executableInAssets,

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
  final String evidence;

  const HardeningObservation(this.signal, this.evidence);

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

  static final _dexNamePattern = RegExp(r'^classes(\d*)\.dex$');
  static final _nativeLibPattern = RegExp(r'^lib/([^/]+)/([^/]+)$');

  static List<HardeningObservation> scan(Archive archive) {
    final observations = <HardeningObservation>[];

    final fileEntries = archive.files.where((f) => f.isFile).toList();

    // ---- DEX ----
    final dexEntries =
        fileEntries.where((f) => _dexNamePattern.hasMatch(f.name)).toList();

    if (dexEntries.isEmpty) {
      observations.add(const HardeningObservation(
        HardeningSignal.missingPrimaryDex,
        'no classes.dex / classesN.dex entry in the archive root',
      ));
    } else {
      if (dexEntries.length > 1) {
        final dexNames = dexEntries.map((f) => f.name).toList()..sort();
        observations.add(HardeningObservation(
          HardeningSignal.multipleDexFiles,
          '${dexEntries.length} DEX entries: ${dexNames.take(8).join(', ')}'
          '${dexNames.length > 8 ? ', …' : ''}',
        ));
      }

      for (final entry in dexEntries) {
        final header = _readHeader(entry, 8);
        if (header == null) {
          observations.add(HardeningObservation(
            HardeningSignal.dexHeaderNotStandard,
            '${entry.name}: entry could not be read',
          ));
          continue;
        }
        if (!_hasDexMagic(header)) {
          observations.add(HardeningObservation(
            HardeningSignal.dexHeaderNotStandard,
            '${entry.name}: header is ${_hex(header)} '
            '(expected "dex\\n0xx")',
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
        ));
      }
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
        ));
      } else if (arsc.first.size < resourceTableMinPlausibleSize) {
        observations.add(HardeningObservation(
          HardeningSignal.resourceTableAnomaly,
          'resources.arsc is only ${arsc.first.size} bytes',
        ));
      }
    }

    return observations;
  }

  /// 读取条目前 [length] 个字节。
  ///
  /// 内容在 `Archive` 解码阶段已被物化，这里不触发额外解压。
  static List<int>? _readHeader(ArchiveFile entry, int length) {
    try {
      final content = entry.content;
      if (content.length < length) return null;
      return content.sublist(0, length);
    } catch (_) {
      return null;
    }
  }

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
