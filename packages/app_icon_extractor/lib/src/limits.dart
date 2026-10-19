/// 图标提取的资源上限。
///
/// ## 为什么这些值要显式、可注入
///
/// 缩略图处理器跑在**文件管理器进程**里，输入是连用户自己都没打开过的文件。
/// 一个 3 GB 的伪造 APK 或一条被篡改的 ZIP 长度字段，就足以让「浏览文件夹」
/// 变成一次内存耗尽。因此这里的每个上限都是**在读取之前**生效的，
/// 而不是读进来之后再检查。
///
/// 值本身采自真实样本（见各字段注释），不是拍出来的整数。
class IconLimits {
  /// 整个输入文件的字节上限（512 MiB）。
  ///
  /// **实测依据**（本机 32 个真实样本）：最大的包是抖音 343 MB，
  /// 在 512 MiB 上限下仍能处理，端到端 0.63 s（冷）/ 0.12 s（热）。
  /// 128 MiB 会把这类大包直接挡掉，而它本来能出图 —— 这是首版 81% 覆盖率的
  /// 一部分原因。
  ///
  /// 真正的闸门不是文件大小，而是 [maxArchiveEntries] 与 `ZipBudget`：
  /// 解析只读 ZIP 中央目录与几个图标条目，不会把整包读进内存。
  final int maxFileBytes;

  /// 单个图标条目的字节上限（8 MiB）。
  ///
  /// 真实图标 PNG 在 20–400 KB；`Assets.car` 里的原图可能到几 MB。
  /// 8 MiB 之上几乎不可能是图标，更像是被塞了大文件。
  final int maxIconBytes;

  /// 图标的最大边长（4096）。
  ///
  /// 读 IHDR 即可判定，**不必解码**。超限时返回 `resourceLimit` 而不是
  /// 交给系统去解 —— 那个解码发生在 Explorer 里，代价由用户承担。
  final int maxIconPixels;

  /// 归档条目数上限（200,000）。
  ///
  /// 真实大包（55 个 DEX + 数万资源）在 5 万量级。20 万之上更像是
  /// 目录炸弹。
  final int maxArchiveEntries;

  /// 允许的扩展名（小写，含点）。
  ///
  /// 只认项目声明支持的两种。XAPK / APKM / APKS 是后续评估范围，
  /// 现在传进来会得到 `unsupported`，而不是被当成 APK 去解析。
  final Set<String> allowedExtensions;

  const IconLimits({
    this.maxFileBytes = 512 * 1024 * 1024,
    this.maxIconBytes = 8 * 1024 * 1024,
    this.maxIconPixels = 4096,
    this.maxArchiveEntries = 200000,
    this.allowedExtensions = const {'.apk', '.ipa'},
  });

  /// 给单元测试用的小预算（不必造 128 MiB 文件就能验证超限）。
  const IconLimits.tiny({
    this.maxFileBytes = 64 * 1024,
    this.maxIconBytes = 4096,
    this.maxIconPixels = 256,
    this.maxArchiveEntries = 16,
    this.allowedExtensions = const {'.apk', '.ipa'},
  });

  @override
  String toString() => 'IconLimits(file=$maxFileBytes, icon=$maxIconBytes, '
      'pixels=$maxIconPixels, entries=$maxArchiveEntries)';
}
