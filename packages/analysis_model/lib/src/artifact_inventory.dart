import 'dart:typed_data';

/// 包里「有安全意义的制品」清单。
///
/// 清单只回答**事实**：路径、类型、来源、大小、是否扫过内容。它不判断
/// 恶意性；`mismatch`/`suspicious` 由后续的规则层产出。
///
/// 设计约束（与 [ContainerEntryFact] 一致）：
/// - `sha256 == null` 表示**没算**（未做/超预算），不是空串；
/// - [ArtifactInventory.entriesComplete] 为 false 时，报告必须同时给出
///   [ArtifactInventory.skippedCodes]，不能把「只列了一部分」显示成「全部」。
class ArtifactInventory {
  /// 有安全意义的条目（代码、资源表、清单、签名材料、assets 载荷）。
  final List<ArtifactEntry> entries;

  /// 归档条目总数（覆盖率分母）。
  final int totalEntries;

  /// 实际进入清单的条目数。
  final int inventoriedEntries;

  /// 清单是否完整（没有被条目上限/预算截断）。
  final bool entriesComplete;

  /// 清单被截断/跳过时的稳定 code。
  final List<String> skippedCodes;

  const ArtifactInventory({
    this.entries = const [],
    this.totalEntries = 0,
    this.inventoriedEntries = 0,
    this.entriesComplete = true,
    this.skippedCodes = const [],
  });

  bool get isEmpty => entries.isEmpty;

  /// 按类型计数（稳定排序，便于报告）。
  Map<ArtifactKind, int> get countByKind {
    final counts = <ArtifactKind, int>{};
    for (final entry in entries) {
      counts[entry.kind] = (counts[entry.kind] ?? 0) + 1;
    }
    return counts;
  }

  /// 按路径查条目；找不到返回 `null`。
  ArtifactEntry? entryForPath(String path) {
    for (final entry in entries) {
      if (entry.path == path) return entry;
    }
    return null;
  }

  /// 是否存在某个 basename 的制品（用于把 `System.loadLibrary("x")`
  /// 解析到 `lib/<abi>/libx.so`）。
  ArtifactEntry? entryForBasename(String basename) {
    for (final entry in entries) {
      final slash = entry.path.lastIndexOf('/');
      final name = slash < 0 ? entry.path : entry.path.substring(slash + 1);
      if (name == basename) return entry;
    }
    return null;
  }

  @override
  String toString() => 'ArtifactInventory(${entries.length} entries, '
      'total=$totalEntries, complete=$entriesComplete)';
}

/// 制品类型。
enum ArtifactKind {
  dex,
  elf,
  machO,
  dylib,
  framework,
  staticLibrary,
  nestedCodeBundle,
  assetArchive,
  assetBinary,
  assetText,
  script,
  resourceTable,
  manifest,
  signatureBlock,
  unknown;

  String get label => switch (this) {
        ArtifactKind.dex => 'DEX',
        ArtifactKind.elf => 'ELF',
        ArtifactKind.machO => 'Mach-O',
        ArtifactKind.dylib => 'dylib',
        ArtifactKind.framework => 'framework',
        ArtifactKind.staticLibrary => 'static library',
        ArtifactKind.nestedCodeBundle => 'nested code bundle',
        ArtifactKind.assetArchive => 'asset archive',
        ArtifactKind.assetBinary => 'asset binary',
        ArtifactKind.assetText => 'asset text',
        ArtifactKind.script => 'script',
        ArtifactKind.resourceTable => 'resource table',
        ArtifactKind.manifest => 'manifest',
        ArtifactKind.signatureBlock => 'signature block',
        ArtifactKind.unknown => 'unknown',
      };

  /// 是否是可执行代码制品（决定是否进入内容级扫描/密封校验）。
  bool get isCode => switch (this) {
        ArtifactKind.dex ||
        ArtifactKind.elf ||
        ArtifactKind.machO ||
        ArtifactKind.dylib ||
        ArtifactKind.framework ||
        ArtifactKind.staticLibrary ||
        ArtifactKind.nestedCodeBundle =>
          true,
        _ => false,
      };
}

/// 制品来源。iOS 的「注入」判据依赖来源（bundleRoot vs frameworks）。
enum ArtifactOrigin {
  /// 正常包内路径。
  embedded,

  /// iOS `.app` 根目录（正常构建不会把 dylib 放这里）。
  bundleRoot,

  /// iOS `Frameworks/`。
  frameworks,

  /// 嵌套 `.appex` / Watch / 嵌套 app。
  nestedBundle,

  /// `assets/` 下的载荷。
  assets,

  /// 仅被加载链引用、包内不存在。
  remoteReferenced,

  unknown;

  String get label => switch (this) {
        ArtifactOrigin.embedded => 'embedded',
        ArtifactOrigin.bundleRoot => 'bundle root',
        ArtifactOrigin.frameworks => 'Frameworks/',
        ArtifactOrigin.nestedBundle => 'nested bundle',
        ArtifactOrigin.assets => 'assets/',
        ArtifactOrigin.remoteReferenced => 'referenced, not in package',
        ArtifactOrigin.unknown => 'unknown',
      };
}

/// 一条制品记录。
class ArtifactEntry {
  final String path;
  final ArtifactKind kind;
  final ArtifactOrigin origin;
  final int sizeBytes;

  /// 架构名（`arm64-v8a` / `arm64` / `x86_64`）；不适用时为 `null`。
  final String? arch;

  /// 小写 hex SHA-256；`null` = 没算（不是空串）。
  final String? sha256;

  /// 是否进入内容级扫描（字符串/熵/魔数）。
  final bool contentScanned;

  /// 未进入内容级扫描的原因 code；扫描过时为 `null`。
  final String? skipCode;

  /// 载荷探测产生的稳定 code（`payload.encrypted` 等）。
  final List<String> suspicionCodes;

  const ArtifactEntry({
    required this.path,
    required this.kind,
    this.origin = ArtifactOrigin.embedded,
    this.sizeBytes = 0,
    this.arch,
    this.sha256,
    this.contentScanned = false,
    this.skipCode,
    this.suspicionCodes = const [],
  });

  bool get isCode => kind.isCode;

  @override
  String toString() => 'ArtifactEntry($path, ${kind.name}, '
      '${origin.name}, $sizeBytes bytes)';
}

/// 载荷探测看到的**文件类型**（按魔数，不按扩展名）。
enum PayloadKind { dex, zip, apk, jar, elf, machO, script, unknown }

/// 一条载荷探测信号。
///
/// 它只描述「内容像什么」；是否恶意由规则层结合加载链/钱包语境判断。
class PayloadSignal {
  final String path;
  final PayloadKind kind;

  /// 稳定 code，例如 `payload.magicMismatch` / `payload.nestedArchive` /
  /// `payload.encrypted` / `payload.executableInAssets`。
  final String code;

  final int sizeBytes;

  /// 头部字节的 Shannon 熵（0–8）；无法计算时为 `null`。
  final double? entropy;

  /// 代码需要的参数（扩展名、声明大小等）。
  final Map<String, Object> args;

  const PayloadSignal({
    required this.path,
    required this.kind,
    required this.code,
    this.sizeBytes = 0,
    this.entropy,
    this.args = const {},
  });

  @override
  String toString() =>
      'PayloadSignal($path, ${kind.name}, $code, entropy=$entropy)';
}

/// 一次载荷探测的输入：条目的**有界头部字节**。
///
/// 调用方负责先套预算（manifest 上限 4 KiB）；这里不读文件、不解压。
class PayloadProbeInput {
  final String path;
  final int sizeBytes;

  /// 头部字节（最多 4 KiB）；读不到时为空。
  final Uint8List headBytes;

  /// 扩展名（含点，小写）；没有扩展名时为 null。
  final String? declaredExtension;

  const PayloadProbeInput({
    required this.path,
    required this.headBytes,
    this.sizeBytes = 0,
    this.declaredExtension,
  });
}

/// 载荷探测结果。
class PayloadProbeResult {
  final List<PayloadSignal> signals;
  final int entriesProbed;
  final int entriesTotal;
  final bool complete;
  final List<String> noteCodes;

  const PayloadProbeResult({
    this.signals = const [],
    this.entriesProbed = 0,
    this.entriesTotal = 0,
    this.complete = true,
    this.noteCodes = const [],
  });

  bool get isEmpty => signals.isEmpty;
}
