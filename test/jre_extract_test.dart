// JRE 归档的解包约定。
//
// Adoptium 的 zip 只有一个顶层目录（`jdk-17.0.20.1+1-jre/`），而
// `ToolPaths.getDownloadedJavaPath` 期望 `java` 落在 `<安装目录>/jre/bin/java`。
// 中间这一层没剥掉的话，下载完探测不到 —— 用户会看到「已下载但仍未找到」，
// 而这种缺陷在界面上完全看不出原因。

import 'dart:io';

import 'package:apk_info_tool/utils/tool_downloader.dart';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

ArchiveFile _file(String name, List<int> bytes) =>
    ArchiveFile(name, bytes.length, bytes);

Future<File> _zipOf(Directory dir, Archive archive) async {
  final file = File(p.join(dir.path, 'jre.zip'));
  final bytes = ZipEncoder().encode(archive);
  await file.writeAsBytes(bytes);
  return file;
}

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('jre_extract_');
  });

  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  test('剥掉唯一的顶层目录，java 落在 jre/bin/java', () async {
    final zip = await _zipOf(
      tmp,
      Archive()
        ..addFile(_file('jdk-17.0.20.1+1-jre/bin/java', [1, 2, 3, 4]))
        ..addFile(_file('jdk-17.0.20.1+1-jre/lib/modules', [5, 6])),
    );

    final out = p.join(tmp.path, 'out');
    await ToolDownloader.extractJre(zip, out);

    expect(File(p.join(out, 'jre', 'bin', 'java')).existsSync(), isTrue);
    expect(File(p.join(out, 'jre', 'lib', 'modules')).existsSync(), isTrue);
    // 顶层目录本身不该留下来。
    expect(
      Directory(p.join(out, 'jre', 'jdk-17.0.20.1+1-jre')).existsSync(),
      isFalse,
    );
  });

  test('顶层目录不唯一时不剥，避免把真实目录结构吃掉', () async {
    final zip = await _zipOf(
      tmp,
      Archive()
        ..addFile(_file('bin/java', [1, 2]))
        ..addFile(_file('lib/modules', [3, 4])),
    );

    final out = p.join(tmp.path, 'out');
    await ToolDownloader.extractJre(zip, out);

    expect(File(p.join(out, 'jre', 'bin', 'java')).existsSync(), isTrue);
  });
}
