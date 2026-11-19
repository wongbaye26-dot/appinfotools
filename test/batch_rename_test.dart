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
      exists: (_) => false,
    );
    expect(plans[0].newName, '微信-8.0.1.apk');
    expect(plans[1].newName, '微信-8.0.1 (2).apk');
    expect(plans[2].newName, 'Bad_Name__.ipa');
  });

  test('`xxx.apk.1` 的复合后缀整体保留', () {
    final plans = buildBatchRenamePlans(
      [(path: '/tmp/x/wechat.apk.1', appName: 'WeChat', version: '8.0')],
      includeVersion: true,
      exists: (_) => false,
    );
    expect(plans.single.newName, 'WeChat-8.0.apk.1');
  });

  test('不包含版本时只用应用名', () {
    final plans = buildBatchRenamePlans(
      [(path: '/tmp/x/a.apk', appName: 'WeChat', version: '8.0')],
      includeVersion: false,
      exists: (_) => false,
    );
    expect(plans.single.newName, 'WeChat.apk');
  });

  test('目标名已被磁盘上的**其它**文件占用时追加序号', () {
    final plans = buildBatchRenamePlans(
      [(path: '/tmp/x/a.apk', appName: 'WeChat', version: '8.0')],
      includeVersion: true,
      exists: (path) => path == p.join('/tmp/x', 'WeChat-8.0.apk'),
    );
    expect(plans.single.newName, 'WeChat-8.0 (2).apk');
  });

  test('本批次自己的源名不算「已占用」（重跑同一批不会全变 (2)）', () {
    final plans = buildBatchRenamePlans(
      [
        (path: '/tmp/x/WeChat-8.0.apk', appName: 'WeChat', version: '8.0'),
        (path: '/tmp/x/other.apk', appName: 'WeChat', version: '8.0'),
      ],
      includeVersion: true,
      // 磁盘上确实存在 `WeChat-8.0.apk`，而它就是本批次第一个文件的源名。
      exists: (path) => path == p.join('/tmp/x', 'WeChat-8.0.apk'),
    );
    expect(plans[0].newName, 'WeChat-8.0.apk');
    expect(plans[0].isNoop, isTrue);
    expect(plans[1].newName, 'WeChat-8.0 (2).apk');
  });

  test('不同目录下的同名不算冲突', () {
    final plans = buildBatchRenamePlans(
      [
        (path: '/tmp/a/x.apk', appName: 'Same', version: '1'),
        (path: '/tmp/b/y.apk', appName: 'Same', version: '1'),
      ],
      includeVersion: true,
      exists: (_) => false,
    );
    expect(plans[0].newName, 'Same-1.apk');
    expect(plans[1].newName, 'Same-1.apk');
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

  test('超过 10 个文件也全部改名（回归：此前 10 个以上会整体失败）', () async {
    final dir = Directory.systemTemp.createTempSync('batch_rename_many');
    addTearDown(() => dir.deleteSync(recursive: true));
    const count = 24;
    final files = <File>[];
    for (var i = 0; i < count; i++) {
      files.add(File(p.join(dir.path, 'raw_$i.apk'))
        ..writeAsStringSync('content-$i'));
    }
    final plans = buildBatchRenamePlans(
      [
        for (var i = 0; i < count; i++)
          (path: files[i].path, appName: 'App $i', version: '1.0'),
      ],
      includeVersion: true,
    );
    expect(plans.length, count);
    final results = await batchRenameFiles(plans);
    final failed = results.where((r) => !r.ok).toList();
    expect(failed, isEmpty, reason: '$failed');
    for (var i = 0; i < count; i++) {
      final target = p.join(dir.path, 'App $i-1.0.apk');
      expect(File(target).existsSync(), isTrue, reason: target);
      expect(File(target).readAsStringSync(), 'content-$i');
      expect(files[i].existsSync(), isFalse);
    }
  });

  test('同一批里互换名字：两阶段改名，不互相覆盖', () async {
    final dir = Directory.systemTemp.createTempSync('batch_rename_swap');
    addTearDown(() => dir.deleteSync(recursive: true));
    final a = File(p.join(dir.path, 'a.apk'))..writeAsStringSync('A');
    final b = File(p.join(dir.path, 'b.apk'))..writeAsStringSync('B');

    final plans = buildBatchRenamePlans(
      [
        (path: a.path, appName: 'B', version: ''),
        (path: b.path, appName: 'A', version: ''),
      ],
      includeVersion: false,
    );
    final results = await batchRenameFiles(plans);
    expect(results.where((r) => !r.ok), isEmpty);
    // 内容必须真的跟着文件走 —— 直接逐个 rename 会把 b 覆盖掉。
    expect(File(p.join(dir.path, 'B.apk')).readAsStringSync(), 'A');
    expect(File(p.join(dir.path, 'A.apk')).readAsStringSync(), 'B');
    // 不留临时文件。
    final leftovers = dir
        .listSync()
        .whereType<File>()
        .where((f) => p.basename(f.path).startsWith('.appinfotool-rename-'))
        .toList();
    expect(leftovers, isEmpty);
  });

  test('目标位置被外部文件占用时拒绝执行，不覆盖', () async {
    final dir = Directory.systemTemp.createTempSync('batch_rename_taken');
    addTearDown(() => dir.deleteSync(recursive: true));
    final source = File(p.join(dir.path, 'a.apk'))..writeAsStringSync('new');
    final squatter = File(p.join(dir.path, 'App.apk'))
      ..writeAsStringSync('must survive');

    final plan = BatchRenamePlan(sourcePath: source.path, newName: 'App.apk');
    final results = await batchRenameFiles([plan]);
    expect(results.single.ok, isFalse);
    expect(results.single.reason, BatchRenameFailureReason.targetExists);
    expect(squatter.readAsStringSync(), 'must survive');
    expect(source.readAsStringSync(), 'new');
  });

  test('源文件不存在时报 sourceMissing', () async {
    final dir = Directory.systemTemp.createTempSync('batch_rename_missing');
    addTearDown(() => dir.deleteSync(recursive: true));
    final plan = BatchRenamePlan(
      sourcePath: p.join(dir.path, 'gone.apk'),
      newName: 'App.apk',
    );
    final results = await batchRenameFiles([plan]);
    expect(results.single.ok, isFalse);
    expect(results.single.reason, BatchRenameFailureReason.sourceMissing);
  });

  test('已经是目标名字时算成功且不动文件', () async {
    final dir = Directory.systemTemp.createTempSync('batch_rename_noop');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File(p.join(dir.path, 'App.apk'))..writeAsStringSync('x');
    final plans = buildBatchRenamePlans(
      [(path: file.path, appName: 'App', version: '')],
      includeVersion: false,
    );
    expect(plans.single.isNoop, isTrue);
    final results = await batchRenameFiles(plans);
    expect(results.single.ok, isTrue);
    expect(file.readAsStringSync(), 'x');
  });
}
