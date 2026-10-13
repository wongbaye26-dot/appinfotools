/// 格式化文件大小为人类可读字符串。
///
/// 单位逐级提升，并在四舍五入后跨越单位边界时上提一级，
/// 避免出现 `1024 KB` 这类不符合直觉的显示（应为 `1 MB`）。
String formatFileSize(int? bytes) {
  if (bytes == null) return "";
  if (bytes < 0) return "-${formatFileSize(-bytes)}";

  const units = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
  var size = bytes.toDouble();
  var unitIndex = 0;

  while (size >= 1024.0 && unitIndex < units.length - 1) {
    size /= 1024.0;
    unitIndex++;
  }

  // 保留两位小数时可能把 1023.999 舍入成 "1024.00"，
  // 此时应直接提升到下一个单位。
  if (unitIndex > 0 &&
      unitIndex < units.length - 1 &&
      (size * 100).round() >= 102400) {
    size /= 1024.0;
    unitIndex++;
  }

  if (unitIndex == 0) {
    return '${size.toInt()} ${units[unitIndex]}';
  }

  var text = size.toStringAsFixed(2);
  if (text.contains('.')) {
    text = text.replaceAll(RegExp(r'0+$'), '');
    text = text.replaceAll(RegExp(r'\.$'), '');
  }
  return '$text ${units[unitIndex]}';
}
