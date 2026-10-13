import 'package:archive/archive.dart';

/// IPA 中一个 bundle 的种类。
///
/// 分类依据是**路径位置**，不是猜测：`.appex` 一定是扩展；`Payload/` 直属的
/// `.app` 才是主应用。不根据名字里有没有 "Watch" 之类的字样去猜。
enum IosBundleKind {
  /// 主应用：`Payload/<name>.app`。
  mainApp,

  /// 应用扩展：`.appex`（少数老包也用 `.app`，但位置在 `PlugIns/` 下）。
  appExtension,

  /// Watch 应用：位于 `Watch/` 目录下的 `.app`。
  watchApp,

  /// 嵌套在别处的 `.app`（不在 `Payload/` 直属，也不在 `Watch/` 下）。
  nestedApp,

  /// 动态框架：`.framework`。
  framework,
}

/// IPA 中一个 bundle 的结构描述。
///
/// 只描述**结构**：路径、条目数、体积、签名材料是否存在。
/// 字段值（`CFBundleIdentifier` 等）来自 `Info.plist`，由 plist 层负责 ——
/// 这里不读内容，因此不需要解压任何东西。
class IosBundle {
  final IosBundleKind kind;

  /// bundle 根目录的条目名前缀，例如 `Payload/MyApp.app`。
  final String path;

  /// bundle 目录名，例如 `MyApp.app`。
  final String name;

  /// `Info.plist` 的条目名；不存在时为 `null`。
  final String? infoPlistPath;

  /// `Info.plist` 声明的解压后大小；不存在时为 `null`。
  final int? infoPlistSize;

  /// bundle 内的文件条目数（**含嵌套 bundle 内的条目** —— 它们确实在这个
  /// bundle 目录里，不计入会让体积统计失真）。
  final int fileCount;

  /// bundle 内文件声明的解压后总字节数。
  final int uncompressedBytes;

  /// 是否存在 `_CodeSignature/` 目录。
  ///
  /// **只表示材料存在，不表示签名有效** —— 是否有效必须由 `codesign` 或静态
  /// 材料分析来判定，见规范 5.5。
  final bool hasCodeSignatureDirectory;

  /// 是否存在 `embedded.mobileprovision`。
  ///
  /// 注意：App Store 分发的 IPA **没有**这个文件是正常的（授权信息在签名里），
  /// 因此它的缺失不能判为异常。
  final bool hasEmbeddedProvision;

  const IosBundle({
    required this.kind,
    required this.path,
    required this.name,
    this.infoPlistPath,
    this.infoPlistSize,
    this.fileCount = 0,
    this.uncompressedBytes = 0,
    this.hasCodeSignatureDirectory = false,
    this.hasEmbeddedProvision = false,
  });

  /// 是否含有签名材料（`_CodeSignature/` 或 `embedded.mobileprovision`）。
  bool get hasSignatureMaterials =>
      hasCodeSignatureDirectory || hasEmbeddedProvision;

  @override
  String toString() => 'IosBundle(${kind.name}, $path, $fileCount files, '
      '$uncompressedBytes B)';
}

/// IPA 容器的结构。
class IpaContainer {
  /// 全部 bundle。主应用排在最前，其余按路径排序。
  final List<IosBundle> bundles;

  /// `Payload/` 直属的全部 `.app`。
  ///
  /// 规范 5.1 明确要求「不假设 ZIP 中只有一个 app」，因此这里保留全部，
  /// 而不是只留一个。多于一个时 [hasMultipleMainApps] 为 true。
  final List<IosBundle> payloadApps;

  /// 是否包含 `Payload/` 目录。
  ///
  /// 为 false 说明这不是标准 IPA（可能是直接把 `.app` 打包的 zip，或文件
  /// 结构异常）。**不因此判定为恶意**，只是如实记录。
  final bool hasPayloadDirectory;

  final int fileEntryCount;
  final int totalUncompressedBytes;

  const IpaContainer({
    this.bundles = const [],
    this.payloadApps = const [],
    this.hasPayloadDirectory = false,
    this.fileEntryCount = 0,
    this.totalUncompressedBytes = 0,
  });

  /// 主应用。
  ///
  /// 多个候选时取**路径排序后第一个**，并且**不做「哪个才是真的」的推断** ——
  /// 仅凭结构无法可靠判断，猜测只会掩盖异常。调用方应通过
  /// [hasMultipleMainApps] 决定是否提示用户。
  IosBundle? get mainApp => payloadApps.isEmpty ? null : payloadApps.first;

  /// 是否存在多个 `Payload/*.app`。标准 IPA 只有一个，多于一个值得注意。
  bool get hasMultipleMainApps => payloadApps.length > 1;

  List<IosBundle> get appExtensions => _ofKind(IosBundleKind.appExtension);

  List<IosBundle> get watchApps => _ofKind(IosBundleKind.watchApp);

  List<IosBundle> get nestedApps => _ofKind(IosBundleKind.nestedApp);

  List<IosBundle> get frameworks => _ofKind(IosBundleKind.framework);

  List<IosBundle> _ofKind(IosBundleKind kind) =>
      bundles.where((b) => b.kind == kind).toList();

  /// 是否存在任何签名材料（任一 bundle 上）。
  bool get hasAnySignatureMaterials =>
      bundles.any((b) => b.hasSignatureMaterials);
}

/// 从归档条目列表解析 IPA 容器结构。
///
/// **只读条目名与声明尺寸，不解压任何内容。** 因此这一层不存在路径穿越风险
/// （不往磁盘写东西）；真正需要路径校验的是解包，由 `archive_safety` 的
/// `ZipGuard.safeJoin` 负责。
class IpaContainerReader {
  IpaContainerReader._();

  /// 会被当作 bundle 根目录的目录名后缀。
  static const List<String> _bundleSuffixes = ['.app', '.appex', '.framework'];

  static const String _payloadPrefix = 'Payload/';

  static IpaContainer read(Archive archive) {
    final fileEntries = archive.files.where((f) => f.isFile).toList();

    // 条目名统一成正斜杠：ZIP 规范要求 `/`，但现实里存在用反斜杠的包。
    final names = <String>[];
    final sizes = <int>[];
    var totalUncompressed = 0;
    for (final entry in fileEntries) {
      names.add(_normalize(entry.name));
      sizes.add(entry.size);
      totalUncompressed += entry.size;
    }

    // 一个条目可能同时属于多个 bundle（嵌套），因此逐个累积。
    final entriesByRoot = <String, List<int>>{};
    for (var i = 0; i < names.length; i++) {
      for (final root in _bundleRootsIn(names[i])) {
        entriesByRoot.putIfAbsent(root, () => []).add(i);
      }
    }

    final nameSet = names.toSet();
    final bundles = <IosBundle>[];
    for (final root in entriesByRoot.keys) {
      bundles.add(_buildBundle(
        root,
        entriesByRoot[root]!,
        names,
        sizes,
        nameSet,
      ));
    }

    // 主应用优先，其余按路径排序 —— 顺序稳定，便于断言与展示。
    bundles.sort((a, b) {
      if (a.kind == IosBundleKind.mainApp && b.kind != IosBundleKind.mainApp) {
        return -1;
      }
      if (b.kind == IosBundleKind.mainApp && a.kind != IosBundleKind.mainApp) {
        return 1;
      }
      return a.path.compareTo(b.path);
    });

    final payloadApps = bundles
        .where((b) => b.kind == IosBundleKind.mainApp)
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));

    return IpaContainer(
      bundles: bundles,
      payloadApps: payloadApps,
      hasPayloadDirectory: names.any((n) => n.startsWith(_payloadPrefix)),
      fileEntryCount: fileEntries.length,
      totalUncompressedBytes: totalUncompressed,
    );
  }

  static IosBundle _buildBundle(
    String root,
    List<int> entryIndices,
    List<String> names,
    List<int> sizes,
    Set<String> nameSet,
  ) {
    final rootPrefix = '$root/';
    var fileCount = 0;
    var uncompressed = 0;
    var hasCodeSignature = false;
    var hasProvision = false;

    for (final index in entryIndices) {
      fileCount++;
      uncompressed += sizes[index];

      final relative = names[index].substring(rootPrefix.length);
      if (relative.startsWith('_CodeSignature/')) {
        hasCodeSignature = true;
      } else if (relative == 'embedded.mobileprovision') {
        hasProvision = true;
      }
    }

    final infoPlistPath = '$root/Info.plist';
    final hasInfoPlist = nameSet.contains(infoPlistPath);
    final infoPlistIndex = hasInfoPlist ? names.indexOf(infoPlistPath) : -1;

    return IosBundle(
      kind: _classify(root),
      path: root,
      name: root.substring(root.lastIndexOf('/') + 1),
      infoPlistPath: hasInfoPlist ? infoPlistPath : null,
      infoPlistSize: infoPlistIndex >= 0 ? sizes[infoPlistIndex] : null,
      fileCount: fileCount,
      uncompressedBytes: uncompressed,
      hasCodeSignatureDirectory: hasCodeSignature,
      hasEmbeddedProvision: hasProvision,
    );
  }

  /// 按路径位置分类，不靠名字猜。
  static IosBundleKind _classify(String root) {
    final segments = root.split('/');
    final dirName = segments.last;

    if (dirName.endsWith('.framework')) return IosBundleKind.framework;
    if (dirName.endsWith('.appex')) return IosBundleKind.appExtension;

    // 主应用：`Payload/<x>.app`，正好两段。
    if (segments.length == 2 &&
        segments.first == 'Payload' &&
        dirName.endsWith('.app')) {
      return IosBundleKind.mainApp;
    }

    // Watch 应用：路径中任意一段是 `Watch`。
    if (dirName.endsWith('.app') && segments.contains('Watch')) {
      return IosBundleKind.watchApp;
    }

    // 扩展偶尔以 `.app` 出现在 PlugIns/ 下。
    if (dirName.endsWith('.app') && segments.contains('PlugIns')) {
      return IosBundleKind.appExtension;
    }

    return IosBundleKind.nestedApp;
  }

  /// 返回条目名中所有「bundle 根目录」前缀。
  ///
  /// 一个条目可能同时属于多个 bundle：`Payload/A.app/PlugIns/B.appex/Info.plist`
  /// 既在 `A.app` 里也在 `B.appex` 里，两者都要算 —— 忽略嵌套会让外层 bundle
  /// 的体积统计偏小。
  static List<String> _bundleRootsIn(String name) {
    final segments = name.split('/');
    final roots = <String>[];
    var prefix = '';

    // 最后一段是文件名，不作为 bundle 目录名。
    for (var i = 0; i < segments.length - 1; i++) {
      prefix = prefix.isEmpty ? segments[i] : '$prefix/${segments[i]}';
      if (_bundleSuffixes.any(segments[i].endsWith)) roots.add(prefix);
    }
    return roots;
  }

  /// 把条目名统一成正斜杠，并去掉冗余分隔符。
  static String _normalize(String name) {
    var normalized = name.replaceAll('\\', '/');
    while (normalized.contains('//')) {
      normalized = normalized.replaceAll('//', '/');
    }
    if (normalized.startsWith('/')) normalized = normalized.substring(1);
    return normalized;
  }
}
