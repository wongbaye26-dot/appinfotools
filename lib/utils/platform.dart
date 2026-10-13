import 'dart:io';

Future<void> openFileInExplorer(String filePath) async {
  try {
    if (Platform.isWindows) {
      await Process.run('explorer.exe', ['/select,', filePath]);
    } else if (Platform.isMacOS) {
      await Process.run('open', ['-R', filePath]);
    } else if (Platform.isLinux) {
      await Process.run('xdg-open', [Directory(filePath).parent.path]);
    }
  } catch (_) {
    // ignore
  }
}

/// 在系统文件管理器中打开 [dirPath] 目录**本身**。
///
/// 与 [openFileInExplorer] 的区别：后者语义是「定位到该条目」
/// （macOS `open -R`、Windows `/select,`），对目录会打开其父目录并选中它；
/// 本函数直接打开目录内容，用于「打开下载目录」这类入口。
///
/// 路径始终以参数数组形式传入，不经 shell 拼接。
Future<void> openDirectoryInExplorer(String dirPath) async {
  try {
    if (Platform.isWindows) {
      await Process.run('explorer.exe', [dirPath]);
    } else if (Platform.isMacOS) {
      await Process.run('open', [dirPath]);
    } else if (Platform.isLinux) {
      await Process.run('xdg-open', [dirPath]);
    }
  } catch (_) {
    // ignore
  }
}
