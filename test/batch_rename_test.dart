import 'dart:io';

import 'package:apk_info_tool/utils/batch_rename.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('生成安全计划：保留扩展名、版本可选、冲突加序号', () {
    final plans = buildBatchRenamePlans(
      [
        (path: '/tmp/A.apk', appName: '微信', version: '8.0.1'),
        (path: '/tmp/B.apk', appName: '微信', version: '8.0.1'),
        (path: '/tmp/c.ipa', appName: 'Bad/Name:*', version: ''),
      ],
      includeVersion: true,
    );
    expect(plans[0].newName, '微信-8.0.1.apk');
    expect(plans[1].newName, '微信-8.0.1 (2).apk');
    expect(plans[2].newName, 'Bad_Name__.ipa');
  });

  test('批量重命名实际落盘', () async {
    final dir = Directory.systemTemp.createTempSync('batch_rename');
    addTearDown(() => dir.deleteSync(recursive: true));
    final a = File(p.join(dir.path, 'a.apk'))..writeAsStringSync('a');
    final b = File(p.join(dir.path, 'b.apk'))..writeAsStringSync('b');
    final plans = buildBatchRenamePlans(
      [
        (path: a.path, appName: 'App', version: '1'),
        (path: b.path, appName: 'App', version: '2'),
      ],
      includeVersion: true,
    );
    final results = await batchRenameFiles(plans);
    expect(results.every((r) => r.ok), isTrue);
    expect(File(p.join(dir.path, 'App-1.apk')).existsSync(), isTrue);
    expect(File(p.join(dir.path, 'App-2.apk')).existsSync(), isTrue);
  });
}
