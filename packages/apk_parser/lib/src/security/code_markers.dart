import 'package:analysis_model/analysis_model.dart';

/// 一个待匹配的代码标记。
///
/// [literal] 是**字面量子串**（区分大小写）。Java 标识符与 SDK 包名用字面量
/// 最可靠；正则太宽会把 `RECORD` 之类误判成 OCR。
///
/// 匹配时调用方会把 `/` 归一成 `.` 再比：DEX 里同一个 SDK 有两种写法 ——
/// 类型描述符用斜杠（`Lcom/google/mlkit/vision/text/TextRecognizer;`），
/// 字符串字面量用点号（`com.google.mlkit.vision.text`）。不归一化就会
/// 换一种写法整类漏掉，而真实的加固样本里两种形态都出现过。
class CodeMarker {
  /// 标记 id，例如 `ocr-mlkit`。与规则引擎的输入一一对应。
  final String id;

  final SecurityCategory category;

  /// 命中标记的说明（面向最终用户，例如「ML Kit 文字识别 SDK」）。
  final String description;

  final String literal;

  const CodeMarker(this.id, this.category, this.description, this.literal);
}

/// 全部代码标记。
///
/// **放在共享位置**：字符串扫描器（`DexClueScanner`）与方法引用扫描器
/// （`DexMethodScanner`）都要用它。两边各写一份必然漂移 —— 加了新标记却只改
/// 一处，结果是「字符串里命中了、代码引用里没命中」这种自相矛盾的结论。
const List<CodeMarker> codeMarkers = [
  // ---- OCR / 图像识别 ----
  CodeMarker('ocr-mlkit', SecurityCategory.ocrImage,
      'ML Kit text recognition SDK', 'com.google.mlkit'),
  CodeMarker('ocr-textrecognition', SecurityCategory.ocrImage,
      'text recognition API', 'TextRecognition'),
  CodeMarker('ocr-recognizetext', SecurityCategory.ocrImage,
      'text recognition call', 'recognizeText'),
  CodeMarker(
      'ocr-tesseract', SecurityCategory.ocrImage, 'Tesseract OCR', 'esseract'),
  CodeMarker('ocr-literal', SecurityCategory.ocrImage,
      'OCR literal in code/strings', 'OCR'),
  // ---- 截图 / 屏幕内容 ----
  CodeMarker('screenshot', SecurityCategory.ocrImage, 'screenshot capture',
      'creenshot'),
  CodeMarker('screencapture', SecurityCategory.ocrImage, 'screen capture',
      'MediaProjection'),
  // ---- 图片读取 ----
  CodeMarker('mediastore', SecurityCategory.photoAccess,
      'media database access', 'MediaStore'),
  CodeMarker('externalcontenturi', SecurityCategory.photoAccess,
      'external storage content URI', 'EXTERNAL_CONTENT_URI'),
  // ---- 上传 / 网络 ----
  CodeMarker('multipart', SecurityCategory.dataExfiltration,
      'multipart form upload', 'multipart/form-data'),
  CodeMarker('multipartbody', SecurityCategory.dataExfiltration,
      'multipart request body', 'MultipartBody'),
  CodeMarker(
      'okhttp', SecurityCategory.network, 'OkHttp HTTP client', 'okhttp3'),
  CodeMarker('retrofit', SecurityCategory.network, 'Retrofit HTTP client',
      'retrofit2'),
  CodeMarker('httpurlconnection', SecurityCategory.network, 'HttpURLConnection',
      'HttpURLConnection'),
  CodeMarker('volley', SecurityCategory.network, 'Volley HTTP client',
      'com.android.volley'),
  CodeMarker('uploadfile', SecurityCategory.dataExfiltration,
      'file upload call', 'ploadFile'),
  CodeMarker('uploadimage', SecurityCategory.dataExfiltration,
      'image upload call', 'ploadImage'),
  // ---- 后台 ----
  CodeMarker('jobscheduler', SecurityCategory.backgroundTask, 'JobScheduler',
      'JobScheduler'),
  CodeMarker('workmanager', SecurityCategory.backgroundTask, 'WorkManager',
      'androidx.work'),
  // ---- 第三方 SDK（只作事实记录，不作风险判定）----
  CodeMarker('sdk-firebase', SecurityCategory.thirdPartySdk, 'Firebase SDK',
      'com.google.firebase'),
  CodeMarker('sdk-umeng', SecurityCategory.thirdPartySdk, 'Umeng analytics SDK',
      'com.umeng'),
  CodeMarker('sdk-bugly', SecurityCategory.thirdPartySdk,
      'Bugly crash reporting SDK', 'com.tencent.bugly'),
];

/// 每个标记是否**必须**同时比「原文」与「归一化文本」，下标与 [codeMarkers]
/// 一一对应。
///
/// 判据是字面量里有没有 `.`：
///
/// - **没有 `.` 的标记比一次就够。** 归一化只把 `/` 换成 `.`；标记里既然没有
///   `.`，替换就不可能凭空造出一个匹配，也不会破坏原有匹配（能匹配上的那些
///   字符位置本来就不是 `/`）。因此原文与归一化文本对它**结论相同**。
/// - **含 `/` 的标记（`multipart/form-data`）只可能命中原文** —— 归一化之后
///   `/` 已经不存在了。
/// - **含 `.` 的标记才需要比两次**：归一化会把 `Lcom/google/mlkit/…` 变成
///   `Lcom.google.mlkit.…`，正是这类标记要抓的形态。
///
/// 23 个标记里有 16 个属于第一类，每个文本因此少跑 16 次子串搜索。在真实大包
/// 上这个函数会被调用上千万次（343 MB 的 APK 光 `method_ids` 就有 287 万条），
/// 这一项就是几秒钟。
final List<bool> _needsNormalized = [
  for (final marker in codeMarkers) marker.literal.contains('.'),
];

/// 找出 [text] 命中的标记（把 `/` 归一成 `.` 后再比）。
///
/// 两个扫描器共用这一份匹配逻辑，避免「同一段文本在两边命中不同的标记」。
/// 返回值**保持 [codeMarkers] 的顺序**（调用方目前不依赖顺序，但顺序稳定能
/// 免掉一整类难查的差异）。
List<CodeMarker> matchCodeMarkers(String text) {
  // 没有斜杠时归一化就是原文 —— 省掉一次分配与一遍扫描。
  // 字符串线索那一路（`DexClueScanner`）大量不带斜杠。
  final hasSlash = text.contains('/');
  final normalized = hasSlash ? text.replaceAll('/', '.') : text;

  List<CodeMarker>? out;
  for (var i = 0; i < codeMarkers.length; i++) {
    final marker = codeMarkers[i];
    final literal = marker.literal;
    final bool hit;
    if (_needsNormalized[i]) {
      hit = text.contains(literal) || normalized.contains(literal);
    } else {
      hit = text.contains(literal);
    }
    if (hit) (out ??= <CodeMarker>[]).add(marker);
  }
  // 没命中时返回 `const []`：这个函数在真实大包上会被调用几百万次，
  // 每次都分配一个空列表是纯浪费。
  return out ?? const <CodeMarker>[];
}
