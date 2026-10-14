import 'package:archive/archive.dart';

/// 归档解压的资源预算。
///
/// 归档内容完全由不可信输入控制（用户打开的 APK / XAPK / IPA，或远程下载的
/// platform-tools / build-tools 压缩包），因此必须防止声明的解压体积、条目数
/// 或压缩比异常导致内存或磁盘被耗尽（ZIP 炸弹）。
///
/// **这是唯一的实现。** 应用层（`lib/utils/zip_guard.dart`）与解析器
/// （`ApkReader`）都复用它。历史上两边各写了一份逻辑等价但常量重复的判定，
/// 任何一边调整阈值都不会同步到另一边。
class ZipBudget {
  ZipBudget._();

  /// 单个归档允许的解压后总字节数上限（1 GiB）。
  static const int maxTotalUncompressed = 1024 * 1024 * 1024;

  /// 单个归档允许的最大条目数。
  static const int maxEntryCount = 100000;

  /// 触发压缩比检查的最小解压体积（16 MiB）。
  ///
  /// 小体积文件即使压缩比很高也通常是合法资源（例如大面积为零的
  /// `resources.arsc`），不加以区分会产生误报。
  static const int ratioCheckMinSize = 16 * 1024 * 1024;

  /// 允许的最大压缩比（100:1）。
  static const int maxCompressionRatio = 100;

  /// 单个条目允许的解压后字节数上限（256 MiB）。
  ///
  /// 总量上限（1 GiB）拦不住「一个 900 MiB 的条目」—— 读取那一条时仍会
  /// 一次性吃掉内存。而 APK / IPA 里最大的条目通常是 `resources.arsc`
  /// 或几 MB 的原生库，256 MiB 已远超正常值。
  static const int maxSingleEntryUncompressed = 256 * 1024 * 1024;

  /// 判定归档是否超出预算。
  ///
  /// 只读取归档头部声明的尺寸，不实际解压，因此开销可忽略。
  static bool isExceeded(Archive archive) {
    var totalUncompressed = 0;
    var count = 0;
    for (final file in archive.files) {
      count++;
      if (count > maxEntryCount) return true;
      if (!file.isFile) continue;
      // ArchiveFile.size 为解压后的尺寸（解码时取自 ZipFile.uncompressedSize）。
      final uncompressed = file.size;
      if (uncompressed < 0) return true;
      if (uncompressed > maxSingleEntryUncompressed) return true;
      totalUncompressed += uncompressed;
      if (totalUncompressed > maxTotalUncompressed) return true;
      final raw = file.rawContent;
      if (raw is ZipFile) {
        final compressed = raw.compressedSize;
        if (uncompressed > ratioCheckMinSize &&
            compressed > 0 &&
            uncompressed > compressed * maxCompressionRatio) {
          return true;
        }
      }
    }
    return false;
  }

  /// 超出预算则抛出 [ZipBombException]。
  ///
  /// 用于解包到磁盘之前的前置校验 —— 一旦开始写入就已经太晚了。
  static void ensureWithin(Archive archive, {String? source}) {
    if (isExceeded(archive)) {
      throw ZipBombException(
        'Refusing to open archive: decompression bomb detected',
        source: source,
      );
    }
  }
}

/// 跨多层归档累计的解压预算。
///
/// **为什么需要它**：`ZipBudget.isExceeded` 只看单个归档，于是「每层都刚好
/// 不超限」的嵌套归档（APK 里套 ZIP、ZIP 里再套 ZIP）能累计耗尽资源 ——
/// 每层各自通过检查，总量却失控。
///
/// 用法：为**一次解包流程**创建一个实例，每打开一层归档就 `add` 一次。
/// 不要跨流程复用 —— 那会把两次无关的解包算到一起，产生误报。
class ZipBudgetTracker {
  int _totalUncompressed = 0;
  int _entryCount = 0;
  final List<String> _layers = [];

  /// 已累计的解压后总字节数。
  int get totalUncompressed => _totalUncompressed;

  /// 已累计的条目数。
  int get entryCount => _entryCount;

  /// 已累计的层标签，按加入顺序。
  List<String> get layers => List.unmodifiable(_layers);

  /// 累计一层归档；超出累计预算时抛 [ZipBombException]。
  ///
  /// [label] 会在异常里指出是**哪一层**把总量顶爆的 —— 嵌套解包时只报
  /// 「总量超限」没有可操作性。
  void add(Archive archive, {required String label}) {
    var layerBytes = 0;
    var layerCount = 0;

    for (final file in archive.files) {
      layerCount++;
      if (!file.isFile) continue;
      final uncompressed = file.size;
      if (uncompressed < 0) {
        throw ZipBombException(
          'Refusing to open archive: entry declares a negative size',
          source: label,
        );
      }
      if (uncompressed > ZipBudget.maxSingleEntryUncompressed) {
        throw ZipBombException(
          'Refusing to open archive: a single entry exceeds '
          '${ZipBudget.maxSingleEntryUncompressed ~/ (1024 * 1024)} MiB',
          source: label,
        );
      }
      layerBytes += uncompressed;
    }

    _totalUncompressed += layerBytes;
    _entryCount += layerCount;
    _layers.add(label);

    if (_totalUncompressed > ZipBudget.maxTotalUncompressed) {
      throw ZipBombException(
        'Refusing to open archive: cumulative uncompressed size across '
        '${_layers.length} nested layers exceeds the budget',
        source: label,
      );
    }
    if (_entryCount > ZipBudget.maxEntryCount) {
      throw ZipBombException(
        'Refusing to open archive: cumulative entry count across '
        '${_layers.length} nested layers exceeds the budget',
        source: label,
      );
    }
  }
}

/// 归档命中了解压预算上限。
///
/// 单独成类型，是为了让调用方能把它与「不是归档」「归档损坏」「IO 失败」
/// 区分开：这是**安全拒绝**，不是解析故障。
class ZipBombException implements Exception {
  final String message;

  /// 触发拒绝的来源说明（例如 `platform-tools`、`build-tools 35.0.0`）。
  final String? source;

  ZipBombException(this.message, {this.source});

  @override
  String toString() =>
      'ZipBombException: $message${source == null ? '' : ' ($source)'}';
}
