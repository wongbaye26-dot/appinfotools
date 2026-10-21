import 'package:analysis_model/analysis_model.dart';

import 'code_markers.dart';
import 'native_symbol_scanner.dart' show NativeLibraryBytes;

/// 从原生库（`lib/**.so`）的 ASCII 字符串里找「盗 U」信号。
///
/// ## 为什么需要它
///
/// 钱包的密码学实现（libsecp256k1、BIP39 派生）在 Android 上**通常被静态
/// 链接进 App 自己的 `.so`**，符号是「定义」而不是「导入」—— 现有的原生
/// 符号审计只看导入（`st_shndx == 0`），看不到它们；release 包又常被 strip，
/// `.symtab` 也没了。
///
/// 但 `.rodata` / `.dynstr` 里的**字符串**还在：`secp256k1`、`bip39`、
/// `mnemonic` 这些常量名与错误文案不会因为 strip 消失。所以这条路能捞回
/// 一部分「逻辑在 native 里」的样本。
///
/// ## 它解决不了什么
///
/// 字符串被加密 / 拼接的样本照样看不到；这是静态分析的边界，不是这条扫描的
/// 缺陷。报告里的局限要照实说。
///
/// ## 预算
///
/// 与 DEX 侧同一个纪律：**先定预算再读**。单库 8 MiB、合计 32 MiB，
/// 超出的部分记进 [skippedLibraries]，由调用方写进报告 —— 悄悄只扫一半
/// 比不扫更糟。
class NativeCryptoScan {
  NativeCryptoScan._();

  /// 单库最多扫多少字节。
  static const int maxBytesPerLibrary = 8 * 1024 * 1024;

  /// 全部库合计最多扫多少字节。
  static const int maxTotalBytes = 32 * 1024 * 1024;

  /// 地址字面量最多保留多少条（与 DEX 侧一致）。
  static const int maxAddresses = 32;

  /// 每个标记最多留几条样本（够做证据）。
  static const int maxSamplesPerMarker = 3;

  /// 只扫加密资产类的标记 —— 别的类别与这条规则无关。
  static final List<CodeMarker> cryptoMarkers = [
    for (final marker in codeMarkers)
      if (marker.category == SecurityCategory.cryptoAsset) marker,
  ];

  static NativeCryptoScanResult scan(List<NativeLibraryBytes> libraries) {
    final samples = <String, Set<String>>{};
    final sources = <String, Set<String>>{};
    final addresses = <CryptoAddressHit>{};
    final addressSources = <CryptoAddressHit, Set<String>>{};
    final skipped = <String>[];
    final scannedNames = <String>[];

    var scannedBytes = 0;
    var stringCount = 0;

    for (final library in libraries) {
      if (scannedBytes >= maxTotalBytes) {
        skipped.add(library.name);
        continue;
      }
      final remaining = maxTotalBytes - scannedBytes;
      final perLibrary = library.bytes.length < maxBytesPerLibrary
          ? library.bytes.length
          : maxBytesPerLibrary;
      final limit = perLibrary < remaining ? perLibrary : remaining;
      if (limit < library.bytes.length) {
        // 只扫了前 limit 字节 —— 调用方要能说出来。
        skipped.add(library.name);
      }
      if (limit <= 0) continue;
      scannedBytes += limit;
      scannedNames.add(library.name);

      for (final text in AsciiStrings.extract(library.bytes, limit: limit)) {
        stringCount++;
        for (final marker in cryptoMarkers) {
          if (!text.contains(marker.literal)) continue;
          final bucket = samples.putIfAbsent(marker.id, () => <String>{});
          if (bucket.length < maxSamplesPerMarker) bucket.add(text);
          (sources[marker.id] ??= <String>{}).add(library.name);
        }
        if (addresses.length >= maxAddresses) continue;
        for (final hit in findCryptoAddresses(text)) {
          if (addresses.length >= maxAddresses) break;
          if (isKnownContractAddress(hit)) continue;
          if (addresses.add(hit)) {
            (addressSources[hit] ??= <String>{}).add(library.name);
          }
        }
      }
    }

    return NativeCryptoScanResult(
      samples: samples,
      sources: sources,
      addresses: addresses,
      addressSources: addressSources,
      scannedLibraries: scannedNames,
      skippedLibraries: skipped,
      scannedBytes: scannedBytes,
      totalLibraries: libraries.length,
      stringCount: stringCount,
    );
  }
}

/// [NativeCryptoScan.scan] 的结果。
class NativeCryptoScanResult {
  /// 标记 id → 命中样本。
  final Map<String, Set<String>> samples;

  /// 标记 id → 出现在哪些库。
  final Map<String, Set<String>> sources;

  final Set<CryptoAddressHit> addresses;
  final Map<CryptoAddressHit, Set<String>> addressSources;

  /// 实际扫过的库（有序，报告里按它给证据位置）。
  final List<String> scannedLibraries;

  /// 因预算只扫了一部分、或整个跳过的库。
  final List<String> skippedLibraries;

  final int scannedBytes;
  final int totalLibraries;

  /// 实际提取到的 ASCII 串条数。
  final int stringCount;

  const NativeCryptoScanResult({
    required this.samples,
    required this.sources,
    required this.addresses,
    required this.addressSources,
    required this.scannedLibraries,
    required this.skippedLibraries,
    required this.scannedBytes,
    required this.totalLibraries,
    required this.stringCount,
  });

  bool get isEmpty => samples.isEmpty && addresses.isEmpty;

  /// 命中的标记 id（按标记表顺序，稳定）。
  List<String> get markerIds => [
        for (final marker in NativeCryptoScan.cryptoMarkers)
          if (samples.containsKey(marker.id)) marker.id,
      ];

  /// 没有任何库可扫（没提供原生库）。
  bool get hasNoInput => totalLibraries == 0;

  /// 原生库**看起来被加密 / 加壳**了。
  ///
  /// 判据：扫了至少 1 MiB，但每 4 KiB 连一条 ASCII 串都提不出来。
  /// 正常编译出来的 `.so` 密度远高于此（字符串常量、符号名、错误文案都在
  /// `.rodata` / `.dynstr` 里）；密度低到这个程度，多半是整体加密或加壳。
  ///
  /// 这条**不是**结论，是「我们看不清」的诚实标记 —— 它只用来给报告加一句
  /// 「native 侧的结论可能偏保守」，不会改变判级。
  bool get looksPacked =>
      scannedBytes >= 1024 * 1024 && stringCount * 4096 < scannedBytes;
}

/// 一个空的扫描结果（没有原生库时用）。
const NativeCryptoScanResult emptyNativeCryptoScan = NativeCryptoScanResult(
  samples: {},
  sources: {},
  addresses: {},
  addressSources: {},
  scannedLibraries: [],
  skippedLibraries: [],
  scannedBytes: 0,
  totalLibraries: 0,
  stringCount: 0,
);
