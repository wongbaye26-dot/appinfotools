// ApkParseTask 的单元测试。
//
// 覆盖三件事：事件顺序（阶段真实推进）、失败分类（容器层原因可区分）、
// 以及取消 —— 取消是这次改动的核心目的之一，必须验证它真的会产生
// 终止事件而不是被后续事件覆盖。

import 'dart:async';
import 'dart:io';

import 'package:apk_info_tool/apkparser/parse_task.dart';
import 'package:apk_parser/apk_parser.dart';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

/// 写入一个 ZIP。`bigEntryBytes > 0` 时额外塞一个可压缩的大条目，
/// 让 worker 的解码阶段耗时明显长于主 isolate 发起取消的耗时。
Future<String> _writeZip(
  Directory dir,
  String name,
  Map<String, String> files, {
  int bigEntryBytes = 0,
}) async {
  final archive = Archive();
  files.forEach(
    (fileName, content) =>
        archive.addFile(ArchiveFile.string(fileName, content)),
  );
  if (bigEntryBytes > 0) {
    archive.addFile(ArchiveFile.string('big.bin', 'x' * bigEntryBytes));
  }
  final file = File('${dir.path}/$name');
  await file.writeAsBytes(ZipEncoder().encode(archive));
  return file.path;
}

Future<String> _writeBytes(Directory dir, String name, List<int> bytes) async {
  final file = File('${dir.path}/$name');
  await file.writeAsBytes(bytes);
  return file.path;
}

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('apk_parse_task_test');
  });

  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  group('事件顺序', () {
    test('缺少 manifest 的 ZIP：openContainer -> manifest -> ParseFailed',
        () async {
      final path = await _writeZip(tmp, 'no-manifest.zip', {'x.txt': 'hi'});

      final task = await ApkParseTask.start(path);
      final events = await task.events.toList();

      expect(
        events.whereType<ParseStageReached>().map((e) => e.stage).toList(),
        [ApkParseStage.openContainer, ApkParseStage.manifest],
        reason: '没有 manifest 就不该声称进入了 resources 阶段',
      );
      expect(events.last, isA<ParseFailed>());
    });

    test('每个任务都以终止事件收尾', () async {
      final path = await _writeZip(tmp, 'no-manifest2.zip', {'x.txt': 'hi'});
      final task = await ApkParseTask.start(path);
      final events = await task.events.toList();

      expect(events, isNotEmpty);
      expect(
        events.last,
        anyOf(isA<ParseSucceeded>(), isA<ParseFailed>(), isA<ParseOpenFailed>(),
            isA<ParseCancelled>()),
      );
    });
  });

  group('失败分类', () {
    test('非归档文件 -> ParseOpenFailed(notArchive)', () async {
      final path = await _writeBytes(tmp, 'fake.apk', 'not a zip'.codeUnits);

      final task = await ApkParseTask.start(path);
      final events = await task.events.toList();

      expect(events, hasLength(2)); // openContainer 阶段 + 终止事件
      expect(
        (events.last as ParseOpenFailed).result,
        ArchiveOpenResult.notArchive,
      );
    });

    test('文件不存在 -> ParseOpenFailed(ioError)，而不是 corrupt', () async {
      final task = await ApkParseTask.start('${tmp.path}/missing.apk');
      final events = await task.events.toList();

      expect(events, hasLength(2));
      expect(
        (events.last as ParseOpenFailed).result,
        ArchiveOpenResult.ioError,
      );
    });
  });

  group('取消', () {
    test('取消以 ParseCancelled 收尾，且不出现成功/失败事件', () async {
      // 用一个几 MB 的条目让 worker 明显滞后于主 isolate 的取消调用。
      final path = await _writeZip(
        tmp,
        'big.zip',
        {'x.txt': 'hi'},
        bigEntryBytes: 4 * 1024 * 1024,
      );

      final task = await ApkParseTask.start(path);
      final events = <ParseEvent>[];
      final done = Completer<void>();
      task.events.listen(events.add, onDone: done.complete);

      task.cancel();

      await done.future.timeout(const Duration(seconds: 10));

      expect(events.last, isA<ParseCancelled>());
      expect(events.whereType<ParseSucceeded>(), isEmpty);
      expect(events.whereType<ParseFailed>(), isEmpty);
      expect(events.whereType<ParseOpenFailed>(), isEmpty);
    });

    test('重复 cancel 只产生一个 ParseCancelled', () async {
      final path = await _writeZip(
        tmp,
        'big2.zip',
        {'x.txt': 'hi'},
        bigEntryBytes: 4 * 1024 * 1024,
      );

      final task = await ApkParseTask.start(path);
      final events = <ParseEvent>[];
      final done = Completer<void>();
      task.events.listen(events.add, onDone: done.complete);

      task.cancel();
      task.cancel();
      task.cancel();

      await done.future.timeout(const Duration(seconds: 10));

      expect(events.whereType<ParseCancelled>(), hasLength(1));
    });

    test('任务正常结束后再 cancel 不会追加事件', () async {
      final path = await _writeBytes(tmp, 'fake2.apk', 'nope'.codeUnits);

      final task = await ApkParseTask.start(path);
      final events = await task.events.toList();
      final countAfterFinish = events.length;

      task.cancel(); // 已完成，应为 no-op

      expect(events, hasLength(countAfterFinish));
      expect(events.whereType<ParseCancelled>(), isEmpty);
    });
  });
}
