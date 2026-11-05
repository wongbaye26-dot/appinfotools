import 'package:analysis_model/analysis_model.dart';

/// Android APK 归档条目 → [ArtifactInventory]。
///
/// 这一层只回答**目录级事实**：路径、类型、来源、声明大小。它**不打开任何
/// 条目内容**、不算哈希（[ArtifactEntry.sha256] 恒为 `null`）、也不判断
/// 恶意性 —— 内容级信号由 `PayloadProbe`（有界头部）与 Phase C 的规则层
/// 负责。把「列了什么」与「扫到了什么」分开，报告才能如实说明覆盖范围。
///
/// 设计取舍：
/// - **只收文件**：目录条目对覆盖率的分子没有意义；`totalEntries` 用文件
///   条目数（目录不参与分母），否则一个多目录的包会把覆盖率稀释得像
///   「漏了一半」。
/// - **先排序再截断**：截断结果只取决于「包里有哪些条目」，与 ZIP 中央
///   目录的顺序无关 —— 同一份内容重打包后顺序可以变，结论不该跟着变。
/// - **跳过的条目不留 `skipCode`**：它们根本不在 `entries` 里，`skipCodes`
///   只用来解释「清单被截断」。
class AndroidArtifactInventoryScanner {
  AndroidArtifactInventoryScanner._();

  /// 清单条目上限。
  ///
  /// 正常 APK 的有意义条目在几十到几百条；2000 足够覆盖资源特别多的包，
  /// 同时兜住「几万个 assets」的畸形/投毒样本。超过时
  /// [ArtifactInventory.entriesComplete] 为 `false` 并给出 [truncatedCode]。
  static const int defaultMaxEntries = 2000;

  /// 清单被条目上限截断时的稳定 code。
  static const String truncatedCode = 'inventory.entries_truncated';

  /// 条目已进清单但**未做内容级扫描**的原因 code。
  ///
  /// 不用 `null`：契约里 `skipCode == null` 表示「进入过内容级扫描」。
  /// 本层从不读内容，留 `null` 会被下游读成「已扫过、没问题」。
  static const String notSelectedCode = 'not.selected';

  /// 把条目事实分类成制品清单。
  ///
  /// [entries] 应来自 `ApkReader.entryFacts()`（或测试合成）。目录条目会被
  /// 忽略；路径归一化为空串的条目也会被忽略（没有可比较的键）。
  static ArtifactInventory scan(
    List<ContainerEntryFact> entries, {
    int maxEntries = defaultMaxEntries,
  }) {
    final files = <ContainerEntryFact>[
      for (final entry in entries)
        if (entry.isFile && entry.path.isNotEmpty) entry,
    ];

    // 排序在截断**之前**：同一组条目重打包后中央目录顺序可以不同，
    // 若按输入顺序截断，「留下哪些」就会随打包器变化。
    final sorted = [...files]..sort((a, b) => a.path.compareTo(b.path));

    final candidates = <ArtifactEntry>[];
    for (final entry in sorted) {
      final artifact = _classify(entry);
      if (artifact != null) candidates.add(artifact);
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

  /// 单条路径 → 制品条目；不列入清单时返回 `null`。
  static ArtifactEntry? _classify(ContainerEntryFact entry) {
    final path = entry.path;
    final lower = path.toLowerCase();
    final extension = _extensionOf(_basename(path));

    // 两个根目录特殊文件按**原样精确匹配**：平台只认这两个名字，
    // 小写变体（`androidmanifest.xml`）不会被当作清单/资源表，
    // 把它们标成 manifest/resourceTable 会给出平台不认的结论。
    if (path == 'AndroidManifest.xml') {
      return _artifact(entry, ArtifactKind.manifest);
    }
    if (path == 'resources.arsc') {
      return _artifact(entry, ArtifactKind.resourceTable);
    }
    if (lower.startsWith('meta-inf/')) {
      return _classifyMetaInf(entry);
    }
    if (lower.startsWith('assets/')) {
      return _classifyAsset(entry, extension);
    }
    if (lower.startsWith('lib/')) {
      return _classifyLib(entry);
    }
    if (extension == '.dex') {
      // 非标准位置的 DEX（`res/raw/x.dex` 之类）也列出来：`DexClassLoader`
      // 能加载任意路径下的 DEX，「位置不标准」本身就是一条事实。
      return _artifact(entry, ArtifactKind.dex);
    }
    // 其余条目（`res/` 下的图片与布局、`META-INF/services`、Kotlin 元数据…）
    // 既不承载代码也不承载载荷，列进清单只会稀释报告。
    return null;
  }

  /// `META-INF/` 下的 v1 签名材料。
  static ArtifactEntry? _classifyMetaInf(ContainerEntryFact entry) {
    final rest = entry.path.substring('META-INF/'.length);
    // 只认 **META-INF 顶层**：平台只在那里找 v1 签名材料，子目录里的同名
    // 文件不生效。口径与 `ApkReader` 的 v1 探测保持一致。
    if (rest.isEmpty || rest.contains('/')) return null;
    final lower = rest.toLowerCase();
    if (lower.endsWith('.sf')) {
      return _artifact(entry, ArtifactKind.signatureBlock);
    }
    if (lower.endsWith('.rsa') ||
        lower.endsWith('.dsa') ||
        lower.endsWith('.ec')) {
      return _artifact(entry, ArtifactKind.signatureBlock);
    }
    if (lower.endsWith('.mf')) {
      // `MANIFEST.MF` 是逐条目的摘要清单，不是 AndroidManifest；
      // 枚举里没有单独的「摘要清单」类型，用 `manifest` 表示「清单类材料」。
      return _artifact(entry, ArtifactKind.manifest);
    }
    return null;
  }

  /// `assets/` 下的载荷：按扩展名粗略分类，认不出的扩展名保留为 `unknown`。
  ///
  /// 为什么认不出也保留：`assets/` 是载荷最常见的落点，**列出来**本身
  /// 就是覆盖范围的一部分；`unknown` 如实说明「不知道该当什么」，
  /// 而不是把它读成「没有风险」。
  static ArtifactEntry? _classifyAsset(
    ContainerEntryFact entry,
    String? extension,
  ) {
    final kind = switch (extension) {
      '.zip' ||
      '.jar' ||
      '.apk' ||
      '.aar' ||
      '.gz' ||
      '.tar' ||
      '.xz' ||
      '.bz2' ||
      '.7z' ||
      '.obb' =>
        ArtifactKind.assetArchive,
      '.sh' ||
      '.bash' ||
      '.zsh' ||
      '.py' ||
      '.lua' ||
      '.pl' ||
      '.rb' ||
      '.js' ||
      '.vbs' ||
      '.ps1' =>
        ArtifactKind.script,
      '.so' ||
      '.dex' ||
      '.elf' ||
      '.bin' ||
      '.dat' ||
      '.pak' ||
      '.db' ||
      '.sqlite' =>
        ArtifactKind.assetBinary,
      '.json' ||
      '.txt' ||
      '.xml' ||
      '.html' ||
      '.htm' ||
      '.csv' ||
      '.yml' ||
      '.yaml' ||
      '.properties' ||
      '.ini' ||
      '.conf' ||
      '.md' =>
        ArtifactKind.assetText,
      _ => ArtifactKind.unknown,
    };
    return _artifact(entry, kind, origin: ArtifactOrigin.assets);
  }

  /// `lib/<abi>/<name>.so` → ELF，架构取自路径里的 ABI 目录名。
  static ArtifactEntry? _classifyLib(ContainerEntryFact entry) {
    final parts = entry.path.split('/');
    if (parts.length < 3) return null;
    final abi = parts[1];
    if (abi.isEmpty) return null;
    // 大小写不敏感：历史包里出现过大写后缀，而扩展名不是安全判据。
    if (!entry.path.toLowerCase().endsWith('.so')) return null;
    // 再深一层的 `.so`（`lib/<abi>/sub/x.so`）也收：`dlopen` 能按任意路径
    // 加载；但只有 ABI 目录这一层参与 `System.loadLibrary` 的名字解析。
    return _artifact(entry, ArtifactKind.elf, arch: abi);
  }

  /// 统一的条目构造：本层恒不读内容，因此 `sha256`/`contentScanned` 固定。
  static ArtifactEntry _artifact(
    ContainerEntryFact entry,
    ArtifactKind kind, {
    ArtifactOrigin origin = ArtifactOrigin.embedded,
    String? arch,
  }) {
    return ArtifactEntry(
      path: entry.path,
      kind: kind,
      origin: origin,
      sizeBytes: entry.sizeBytes,
      arch: arch,
      sha256: null,
      contentScanned: false,
      skipCode: notSelectedCode,
    );
  }

  static String _basename(String path) {
    final slash = path.lastIndexOf('/');
    return slash < 0 ? path : path.substring(slash + 1);
  }

  /// 小写扩展名（含点）；没有扩展名或只是 `.bashrc` 这类隐藏文件时为 `null`。
  static String? _extensionOf(String name) {
    final dot = name.lastIndexOf('.');
    if (dot <= 0 || dot == name.length - 1) return null;
    return name.substring(dot).toLowerCase();
  }
}
