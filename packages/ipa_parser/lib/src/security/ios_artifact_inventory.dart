import 'package:analysis_model/analysis_model.dart';

/// IPA 归档条目 → 制品清单（`ArtifactInventory`）。
///
/// ## 只读条目名，不读内容
///
/// 清单回答的是「包里有哪些有安全意义的文件、在哪、属于哪种布局」。
/// 内容的判定（魔数/熵/嵌套归档）在 `IosPayloadProbe` 里，两者刻意分开：
/// 清单阶段**不打开任何文件**，因此可以和归档遍历共用同一次扫描。
/// 也正因如此，[ArtifactEntry.arch] / [ArtifactEntry.sha256] 恒为 `null`、
/// [ArtifactEntry.contentScanned] 恒为 `false`、`skipCode` 恒为
/// `not.selected`（契约里 `skipCode == null` 表示「扫过了」）—— 这里填值
/// 就等于把「没查」谎报成「查过」。
///
/// ## iOS 没有字节码
///
/// 这里不产出 `dex` 之外的「类/方法」概念；`machO` 只表示「这是一个
/// Mach-O 可执行文件按布局放对了位置」。`dlopen`/`dlsym` 之类只有符号表
/// 线索，属于加载链（`IosLoadGraphScanner`）与 Phase C 的事，不在清单里猜。
///
/// ## 判据是布局
///
/// 与 `IpaLayoutReader` 同一口径：注入的 dylib 是「多出来的文件」，
/// 所以清单必须把 `.app` 根目录与 `Frameworks/` **分开记**（[ArtifactOrigin]
/// 的 `bundleRoot` / `frameworks` / `nestedBundle`）。这是规则层唯一能区分
/// 「正常构建」与「被打包工具塞进去」的输入。
///
/// ## 预算
///
/// 清单条目上限 [defaultMaxEntries]（契约 §5.2：≤2 000）。超出时
/// `entriesComplete=false` + `inventory.entries_truncated`，绝不把
/// 「只列了一部分」显示成「全部」。目录条目与路径归一化为空的条目不计入
/// 清单，也不计入 [ArtifactInventory.totalEntries]（分母是**文件**条目数）。
/// 截断发生在按路径排序**之后**：留下哪些不随 ZIP 中央目录顺序变化。
///
/// ## 不猜的地方
///
/// 主可执行文件的判据是「`.app` 根目录、无扩展名、与 `_CodeSignature/`
/// 同级」。没有 `_CodeSignature/` 时无法确认，本条记为
/// [ArtifactKind.unknown] + [ArtifactOrigin.unknown]，而不是硬说它是
/// Mach-O —— 主可执行文件判错会直接污染「注入」结论。
class IosArtifactInventoryScanner {
  IosArtifactInventoryScanner._();

  /// 默认清单上限（与契约 §5.2 的「清单 ≤2 000」一致）。
  static const int defaultMaxEntries = 2000;

  /// 清单被条目上限截断时写入 [ArtifactInventory.skippedCodes] 的稳定 code。
  static const String truncatedCode = 'inventory.entries_truncated';

  /// 条目已进清单但**未做内容级扫描**的原因 code。
  ///
  /// 不用 `null`：契约里 `skipCode == null` 表示「进入过内容级扫描」。
  /// 本层从不读内容，留 `null` 会被下游读成「已扫过、没问题」。
  static const String notSelectedCode = 'not.selected';

  /// 扫描条目，产出清单。**不读内容**，只做路径分类。
  static ArtifactInventory scan(
    List<ContainerEntryFact> entries, {
    int maxEntries = defaultMaxEntries,
  }) {
    // 分母：归档里的**文件**条目数。目录条目不是制品；路径归一化为空串的
    // 条目没有可比较的键，也不进分母（与 Android 侧同一口径）。
    final files = <ContainerEntryFact>[
      for (final entry in entries)
        if (entry.isFile && entry.path.isNotEmpty) entry,
    ];
    // 排序在截断**之前**：同一组条目重打包后中央目录顺序可以不同，
    // 若按输入顺序截断，「留下哪些」就会随打包器变化。
    final sorted = [...files]..sort((a, b) => a.path.compareTo(b.path));

    final layout = _Layout.read(sorted);
    final candidates = <ArtifactEntry>[];
    for (final entry in sorted) {
      final hit = _classify(entry.path, layout);
      if (hit == null) continue;
      candidates.add(ArtifactEntry(
        path: entry.path,
        kind: hit.kind,
        origin: hit.origin,
        sizeBytes: entry.sizeBytes,
        contentScanned: false,
        // 本层只分类、不读内容：`null` 会被读成「扫过了」。
        skipCode: notSelectedCode,
      ));
    }

    final limit = maxEntries < 0 ? 0 : maxEntries;
    final truncated = candidates.length > limit;
    final kept = truncated ? candidates.sublist(0, limit) : candidates;

    return ArtifactInventory(
      entries: kept,
      totalEntries: files.length,
      inventoriedEntries: kept.length,
      entriesComplete: !truncated,
      skippedCodes: truncated ? const [truncatedCode] : const [],
    );
  }

  // ---------------------------------------------------------------------
  // 分类
  // ---------------------------------------------------------------------

  static _Hit? _classify(String path, _Layout layout) {
    final scope = layout.scopeFor(path);
    final rel = scope == null ? path : path.substring(scope.root.length + 1);
    final segments = path.split('/');
    final base = _basename(rel);
    final extension = _extension(base);
    final inAssets = segments.any((s) => s.toLowerCase() == 'assets');
    final inFrameworks = rel.startsWith('Frameworks/');
    final inSignature =
        segments.contains('_CodeSignature') || segments.contains('SC_Info');
    final directChildOfBundle = scope != null && !rel.contains('/');

    ArtifactOrigin originFor({bool bundleRootDylib = false}) {
      // assets 的优先级最高：`assets/` 下的载荷先按资源载荷解释，
      // 注入信号仍可从路径本身（嵌套 bundle）看出来。
      if (inAssets) return ArtifactOrigin.assets;
      if (scope == null) return ArtifactOrigin.embedded;
      if (!scope.isMain) return ArtifactOrigin.nestedBundle;
      if (bundleRootDylib) return ArtifactOrigin.bundleRoot;
      if (inFrameworks) return ArtifactOrigin.frameworks;
      return ArtifactOrigin.embedded;
    }

    // 1) 签名材料。`_CodeSignature/` 下的都是签名清单/代码目录；
    //    `embedded.mobileprovision` 是描述文件；`SC_Info/` 是 FairPlay 的
    //    DRM 签名材料。三者都**只表示材料存在**，不表示签名有效。
    if (inSignature) {
      return _hit(ArtifactKind.signatureBlock, originFor());
    }
    if (extension == 'mobileprovision') {
      return _hit(ArtifactKind.signatureBlock, originFor());
    }

    // 2) `Info.plist`（含嵌套 framework / appex 的）。
    if (base == 'Info.plist') {
      return _hit(ArtifactKind.manifest, originFor());
    }

    // 3) `Assets.car`：编译后的资源归档。按契约在 assetArchive 与
    //    assetBinary 之间选一个 —— 选 `assetArchive`，因为它本身是一个
    //    **容器**（多张图/多套变体），不是一个不透明数据块；载荷探测把它
    //    当嵌套归档来处理也符合事实。
    if (base == 'Assets.car' || extension == 'car') {
      return _hit(ArtifactKind.assetArchive, originFor());
    }

    // 4) framework 主二进制：直接位于 `*.framework/` 下的无扩展名文件。
    //    规范布局里这样的文件只有 framework 自己的主二进制
    //    （`Foo.framework/Foo`）；带扩展名的是资源，走各自的分支。
    if (_isFrameworkBinary(rel)) {
      return _hit(ArtifactKind.framework, originFor());
    }

    // 5) `assets/` 下的载荷：按扩展名分流，媒体资源不占清单预算。
    if (inAssets) {
      final kind = _assetKind(extension);
      if (kind == null) return null;
      return _hit(kind, ArtifactOrigin.assets);
    }

    // 6) 脚本：任何位置都算（`.js` / `.lua` / `.sh` …）。
    if (_scriptExtensions.contains(extension)) {
      return _hit(ArtifactKind.script, originFor());
    }

    // 7) 动态库。`.app` 根目录 vs `Frameworks/` 是注入判据的核心区别，
    //    因此 origin 必须分开：根目录 → bundleRoot，Frameworks/ → frameworks。
    if (extension == 'dylib') {
      return _hit(
        ArtifactKind.dylib,
        originFor(
          // `directChildOfBundle` 为真时 `scope` 必然非空（同一条件里判过）。
          bundleRootDylib: directChildOfBundle && scope.isMain,
        ),
      );
    }

    // 8) 静态库。
    if (extension == 'a') {
      return _hit(ArtifactKind.staticLibrary, originFor());
    }

    // 9) 嵌套代码束（`.appex` / Watch 里的 `.app` / `.xpc`）的主可执行文件：
    //    直接位于嵌套 bundle 根目录、无扩展名。
    if (scope != null &&
        !scope.isMain &&
        directChildOfBundle &&
        extension.isEmpty &&
        !_nonExecutableRootNames.contains(base)) {
      return _hit(ArtifactKind.nestedCodeBundle, ArtifactOrigin.nestedBundle);
    }

    // 10) 主可执行文件：`.app` 根目录、无扩展名、与 `_CodeSignature/` 同级。
    //     `_CodeSignature/` 不存在时无法确认身份 → unknown，不硬判 Mach-O。
    if (scope != null &&
        scope.isMain &&
        directChildOfBundle &&
        extension.isEmpty &&
        !_nonExecutableRootNames.contains(base)) {
      if (!layout.hasCodeSignature(scope.root)) {
        return _hit(ArtifactKind.unknown, ArtifactOrigin.unknown);
      }
      return _hit(ArtifactKind.machO, ArtifactOrigin.embedded);
    }

    // 11) 明确的代码 / 归档扩展名（不在 assets 下也认）。
    if (extension == 'dex') return _hit(ArtifactKind.dex, originFor());
    if (extension == 'so' || extension == 'elf') {
      return _hit(ArtifactKind.elf, originFor());
    }
    if (_archiveExtensions.contains(extension)) {
      return _hit(ArtifactKind.assetArchive, originFor());
    }

    // 其余是普通资源（图片/nib/本地化字符串/字体…），不是安全意义上的制品。
    return null;
  }

  /// `assets/` 下的扩展名 → 载荷类别。`null` = 明确不是载荷候选。
  ///
  /// 图片/音视频/字体不进驻清单：它们数量大（Flutter 的
  /// `flutter_assets/assets/` 可以有上千张图），会把 2 000 条预算吃掉，
  /// 让真正需要探测的文件落不进清单 —— 那才是覆盖率的损失。
  static ArtifactKind? _assetKind(String extension) {
    if (extension.isEmpty) {
      // 无扩展名：按不透明数据块处理。**内容类型由载荷探测的魔数决定**，
      // 这里不猜（猜错会让规则层把文本当成二进制代码）。
      return ArtifactKind.assetBinary;
    }
    if (_archiveExtensions.contains(extension)) {
      return ArtifactKind.assetArchive;
    }
    if (_scriptExtensions.contains(extension)) return ArtifactKind.script;
    if (_textExtensions.contains(extension)) return ArtifactKind.assetText;
    if (_mediaExtensions.contains(extension)) return null;
    if (extension == 'dex') return ArtifactKind.dex;
    if (extension == 'so' || extension == 'elf') return ArtifactKind.elf;
    if (extension == 'dylib') return ArtifactKind.dylib;
    return ArtifactKind.assetBinary;
  }

  /// `rel` 是否是「直接位于 `*.framework/` 下的无扩展名文件」。
  static bool _isFrameworkBinary(String rel) {
    final segments = rel.split('/');
    if (segments.length < 2) return false;
    final dir = segments[segments.length - 2];
    if (!dir.toLowerCase().endsWith('.framework')) return false;
    // 带扩展名的是 framework 里的资源（Info.plist / 图片 / 代码签名）。
    return !segments.last.contains('.');
  }

  static _Hit _hit(ArtifactKind kind, ArtifactOrigin origin) =>
      _Hit(kind, origin);

  static String _basename(String path) {
    final slash = path.lastIndexOf('/');
    return slash < 0 ? path : path.substring(slash + 1);
  }

  static String _extension(String base) {
    final dot = base.lastIndexOf('.');
    // `dot == 0` 是 `.hidden` 这类隐藏文件，按「无扩展名」处理。
    if (dot <= 0 || dot == base.length - 1) return '';
    return base.substring(dot + 1).toLowerCase();
  }

  /// `.app` 根目录里**不是**可执行文件的已知无扩展名条目。
  static const Set<String> _nonExecutableRootNames = {'PkgInfo'};

  static const Set<String> _scriptExtensions = {
    'js',
    'mjs',
    'cjs',
    'ts',
    'lua',
    'py',
    'rb',
    'pl',
    'php',
    'sh',
    'bash',
    'zsh',
    'ps1',
    'bat',
    'cmd',
  };

  static const Set<String> _archiveExtensions = {
    'zip',
    'jar',
    'apk',
    'aar',
    'xapk',
    'apks',
    'ipa',
    'tar',
    'gz',
    'tgz',
    'bz2',
    'xz',
    '7z',
    'rar',
    'car',
  };

  static const Set<String> _textExtensions = {
    'json',
    'xml',
    'plist',
    'txt',
    'yaml',
    'yml',
    'html',
    'htm',
    'csv',
    'tsv',
    'md',
    'ini',
    'conf',
    'cfg',
    'properties',
    'strings',
  };

  /// 明确不是载荷候选的媒体/字体扩展名。
  static const Set<String> _mediaExtensions = {
    'png',
    'jpg',
    'jpeg',
    'gif',
    'webp',
    'heic',
    'heif',
    'bmp',
    'ico',
    'tiff',
    'tif',
    'svg',
    'pdf',
    'mp3',
    'mp4',
    'm4a',
    'mov',
    'avi',
    'webm',
    'wav',
    'aac',
    'caf',
    'aiff',
    'ttf',
    'otf',
    'woff',
    'woff2',
    'nib',
    'storyboardc',
    'momd',
    'metallib',
  };
}

class _Hit {
  const _Hit(this.kind, this.origin);

  final ArtifactKind kind;
  final ArtifactOrigin origin;
}

/// 一次遍历得到的布局事实：主 bundle + 所有代码 bundle 根 + 签名目录。
///
/// 全部来自条目名，不打开任何文件。bundle 根用「路径前缀」表达，
/// 因为清单输出的是**归档内路径**，不是文件系统路径。
class _Layout {
  const _Layout({
    required this.mainBundle,
    required this.bundleRoots,
    required this.signatureRoots,
  });

  /// 主应用 bundle，例如 `Payload/Foo.app`；判不出时为 `null`。
  final String? mainBundle;

  /// 所有代码 bundle 根（主 `.app` + 嵌套 `.app`/`.appex`/`.xpc`）。
  final List<String> bundleRoots;

  /// 存在 `_CodeSignature/` 的 bundle 根。
  final Set<String> signatureRoots;

  static _Layout read(List<ContainerEntryFact> entries) {
    final roots = <String>{};
    final signatures = <String>{};

    for (final entry in entries) {
      final path = entry.path;
      if (path.isEmpty) continue;

      final segments = path.split('/');
      final lastIndex = segments.length - 1;
      // 文件条目：bundle 根是它的某个**祖先**目录；目录条目：它本身
      // 也可能就是 bundle 根。两者都覆盖，避免依赖 ZIP 是否写目录项。
      for (var i = 0; i < segments.length; i++) {
        if (i == lastIndex && !entry.isDirectory) break;
        if (_isCodeBundleDir(segments[i])) {
          roots.add(segments.sublist(0, i + 1).join('/'));
        }
      }

      // `_CodeSignature/` 可能是目录条目，也可能是文件条目的祖先。
      final marker = path.indexOf('/_CodeSignature/');
      if (marker > 0) {
        signatures.add(path.substring(0, marker));
      } else if (path.endsWith('/_CodeSignature')) {
        signatures
            .add(path.substring(0, path.length - '/_CodeSignature'.length));
      }
    }

    final sorted = roots.toList()..sort();
    return _Layout(
      mainBundle: _pickMainBundle(sorted),
      bundleRoots: sorted,
      signatureRoots: signatures,
    );
  }

  bool hasCodeSignature(String bundleRoot) =>
      signatureRoots.contains(bundleRoot);

  /// 找路径最深的那个 bundle 根：嵌套 bundle 里的文件属于嵌套 bundle，
  /// 不能算在主 `.app` 上（否则 `.appex` 里的 dylib 会被当成主包根目录注入）。
  _BundleScope? scopeFor(String path) {
    String? best;
    for (final root in bundleRoots) {
      if (!path.startsWith('$root/')) continue;
      if (best == null || root.length > best.length) best = root;
    }
    if (best == null) return null;
    return _BundleScope(root: best, isMain: best == mainBundle);
  }

  /// 主 bundle：优先 `Payload/<X>.app`；否则取**最浅**的 `.app` 根。
  /// `.appex`/`.xpc` 永远不是主 bundle。
  static String? _pickMainBundle(List<String> roots) {
    for (final root in roots) {
      final parts = root.split('/');
      if (parts.length == 2 &&
          parts[0] == 'Payload' &&
          parts[1].toLowerCase().endsWith('.app')) {
        return root;
      }
    }
    String? best;
    for (final root in roots) {
      if (!root.toLowerCase().endsWith('.app')) continue;
      final depth = '/'.allMatches(root).length;
      if (best == null || depth < '/'.allMatches(best).length) best = root;
    }
    return best;
  }

  static bool _isCodeBundleDir(String segment) {
    final lower = segment.toLowerCase();
    return lower.endsWith('.app') ||
        lower.endsWith('.appex') ||
        lower.endsWith('.xpc');
  }
}

class _BundleScope {
  const _BundleScope({required this.root, required this.isMain});

  final String root;

  /// 是否为主应用的 `.app`（[scopeFor] 用最长前缀判定，嵌套 bundle 优先）。
  final bool isMain;
}
