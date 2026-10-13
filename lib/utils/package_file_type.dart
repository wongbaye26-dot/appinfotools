/// 本应用能打开哪些文件。
///
/// 抽成独立模块是因为这段判断原先有两份、且都埋在 `info_page.dart` 里：
/// 一份是文件选择器的扩展名白名单，一份是拖放时的一串 `endsWith`。两份都在
/// widget 的闭包里，只能靠真的点一次「打开」或拖一个文件进去才碰得到 ——
/// 于是「支持 IPA」这件事没有任何测试守着。
///
/// 两份**刻意保持不同**，不是重复代码：
/// - 文件对话框只认扩展名，必须逐个列出，且不能用 `.apk.1` 这种带点的写法
///   之外的形式；
/// - 拖放拿到的是一条完整路径，可以做后缀匹配，因此额外接受 `.zip`
///   （有些分发渠道把安装包打成 zip）。
library;

/// 文件选择器允许的扩展名。
///
/// `apk.1` / `apk.1.1` 是某些下载渠道给重名文件加的后缀，用户手里真实存在，
/// 因此一并接受。
const List<String> kPickableExtensions = [
  'apk',
  'xapk',
  'apkm',
  'apks',
  'ipa',
  'apk.1',
  'apk.1.1',
];

/// 重名后缀：`xxx.apk.1` / `xxx.apk.1.1` / …
final RegExp _renamedSuffix = RegExp(r'\.(apk|xapk|apkm|apks)(\.\d+)+$');

/// 拖放进来的路径是不是本应用能打开的类型。
///
/// 只按**扩展名**判断，不看内容 —— 真正的格式判定由解析器负责（它按结构
/// 识别，不信扩展名）。这里只决定「要不要拿它去解析」。
bool isSupportedPackagePath(String path) {
  final lowered = path.toLowerCase();
  if (_renamedSuffix.hasMatch(lowered)) return true;
  for (final extension in const [
    ...kPickableExtensions,
    // 拖放额外接受 zip。
    'zip',
  ]) {
    if (lowered.endsWith('.$extension')) return true;
  }
  return false;
}
