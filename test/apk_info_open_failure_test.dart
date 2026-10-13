// 验证容器层失败的原因能穿透到调用方（审计 5.4）。
//
// 背景：`getApkInfo` 过去在容器打开失败时一律返回 `null`，于是
// 「不是归档」「归档损坏」「命中解压预算」「IO 失败」四种情况在 UI 上
// 全部退化成同一句「解析失败」。现在它抛出携带 [ArchiveOpenResult] 的
// [ApkOpenException]，`info_page` 据此展示对应文案。
//
// 说明：这里不测「文件不存在」。`info_page.openApk` 会先做
// `file.existsSync()` 判断，缺失文件根本到不了 `getApkInfo`；
// 而 `getApkInfo` 开头的 `File(apk).lengthSync()` 在文件缺失时
// 会直接抛 FileSystemException。

import 'dart:io';

import 'package:apk_info_tool/apkparser/apk_info.dart';
import 'package:apk_parser/apk_parser.dart' show ArchiveOpenResult;
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('apk_info_open_failure_test');
  });

  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  Future<String> write(String name, List<int> bytes) async {
    final file = File('${tmp.path}/$name');
    await file.writeAsBytes(bytes);
    return file.path;
  }

  test('非归档内容 -> ApkOpenException(notArchive)', () async {
    final path = await write('fake.apk', 'definitely not an apk'.codeUnits);

    await expectLater(
      getApkInfo(path),
      throwsA(
        isA<ApkOpenException>().having(
          (e) => e.result,
          'result',
          ArchiveOpenResult.notArchive,
        ),
      ),
    );
  });

  test('异常文本含文件路径与原因，便于日志排查', () async {
    final path = await write('fake2.apk', 'nope'.codeUnits);

    try {
      await getApkInfo(path);
      fail('应当抛出 ApkOpenException');
    } on ApkOpenException catch (e) {
      expect(e.toString(), contains(path));
      expect(e.toString(), contains('not a ZIP archive'));
    }
  });
}
