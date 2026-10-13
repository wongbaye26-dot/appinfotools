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
