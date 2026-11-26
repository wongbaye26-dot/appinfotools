// 从 `debug.log` 里挑出能回答「时间花在哪一段」的行。
//
// 不复制整份日志：日志里 `_buildMoreMenuButton` 之类每帧刷新的 FINE 行占
// 绝大多数，用户复制出来既难读，也容易被旧内容混进来。只保留带时间戳的
// `[PERF]` 行与解析起点（后者的 `total=` 用来反推每次调用属于哪个文件）。

const String _perfTag = '[PERF]';
const String _startTag = 'getApkInfo: apk=';

/// 返回最新的至多 [maxLines] 条相关行，按时间顺序排列；没有则返回空串。
String collectDiagnostics(String logText, {int maxLines = 40}) {
  final picked = <String>[];
  for (final line in logText.split(RegExp(r'\r?\n')).reversed) {
    if (!line.contains(_perfTag) && !line.contains(_startTag)) continue;
    final trimmed = line.trimRight();
    if (trimmed.isEmpty) continue;
    picked.add(trimmed);
    if (picked.length >= maxLines) break;
  }
  return picked.reversed.join('\n');
}
