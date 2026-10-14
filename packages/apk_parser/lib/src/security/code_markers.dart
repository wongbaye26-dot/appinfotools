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

/// 找出 [text] 命中的标记（把 `/` 归一成 `.` 后再比）。
///
/// 两个扫描器共用这一份匹配逻辑，避免「同一段文本在两边命中不同的标记」。
List<CodeMarker> matchCodeMarkers(String text) {
  final normalized = text.replaceAll('/', '.');
  return [
    for (final marker in codeMarkers)
      if (text.contains(marker.literal) || normalized.contains(marker.literal))
        marker,
  ];
}
