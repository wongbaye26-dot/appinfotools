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
