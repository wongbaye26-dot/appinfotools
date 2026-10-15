// 样本目录发现逻辑的测试。
//
// 这五种情况必须**分别**可辨认 —— 它们混在一起正是阶段 0 审计里
// 「缺 APK 样本导致 null-check 崩溃」的根因：
//   未配置 / 路径不存在 / 目录为空 / 有文件但无受支持样本 / 该类样本缺失
//
// 这里不碰任何真实样本目录，全部用临时目录构造。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'support/sample_directory.dart';

void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('appinfotool_samples_');
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  File touch(String name, [String content = 'x']) =>
      File(p.join(temp.path, name))..writeAsStringSync(content);

  group('未配置', () {
    test('null 与空串都算未配置，且不触碰文件系统', () {
      for (final value in <String?>[null, '']) {
        final scan = SampleDirectory.scan(path: value);
        expect(scan.status, SampleDirStatus.notConfigured);
        expect(scan.path, isNull);
        expect(scan.fileCount, 0);
        expect(scan.androidSamples, isEmpty);
        expect(scan.iosSamples, isEmpty);
      }
    });

    test('两类样本都给出「未设置环境变量」的原因', () {
      final scan = SampleDirectory.scan(path: null);
      for (final kind in SampleKind.values) {
        final reason = scan.skipReasonFor(kind);
        expect(reason, isNotNull);
        expect(reason, contains('APPINFOTOOL_SAMPLES'));
        expect(reason, contains('未执行'));
      }
    });
  });

  group('路径不存在', () {
    test('目录不存在时状态为 missing，且原因里带上路径', () {
      final ghost = p.join(temp.path, 'not-created');
      final scan = SampleDirectory.scan(path: ghost);

      expect(scan.status, SampleDirStatus.missing);
      final reason = scan.skipReasonFor(SampleKind.ios);
      expect(reason, contains('不存在'));
      expect(reason, contains(ghost));
    });

    test('路径指向一个文件而不是目录时同样算 missing', () {
      final file = touch('not-a-dir.apk');
      final scan = SampleDirectory.scan(path: file.path);

      expect(scan.status, SampleDirStatus.missing);
      expect(scan.androidSamples, isEmpty);
    });
  });

  group('目录为空', () {
    test('空目录与「有文件但没样本」是两种状态', () {
      final scan = SampleDirectory.scan(path: temp.path);
      expect(scan.status, SampleDirStatus.empty);
      expect(scan.fileCount, 0);
      expect(scan.skipReasonFor(SampleKind.ios), contains('没有任何文件'));
    });
  });

  group('有文件但没有受支持的样本', () {
    test('只放 txt 时状态为 noSupportedSamples，原因里列出认得的扩展名', () {
      touch('readme.txt');
      touch('notes.md');

      final scan = SampleDirectory.scan(path: temp.path);
      expect(scan.status, SampleDirStatus.noSupportedSamples);
      expect(scan.fileCount, 2);

      final reason = scan.skipReasonFor(SampleKind.android);
      expect(reason, contains('2 个文件'));
      expect(reason, contains('.apk'));
      expect(reason, contains('.ipa'));
    });
  });

  group('只有一类样本时，另一类给出「该类缺失」而不是「目录有问题」', () {
    test('只有 IPA：iOS 可跑，Android 的原因指明「没有 Android 样本」', () {
      touch('a.ipa');
      touch('b.ipa');

      final scan = SampleDirectory.scan(path: temp.path);
      expect(scan.status, SampleDirStatus.ready);
      expect(scan.iosSamples, hasLength(2));
      expect(scan.androidSamples, isEmpty);

      expect(scan.skipReasonFor(SampleKind.ios), isNull, reason: '有 IPA 就不该跳过');
      final reason = scan.skipReasonFor(SampleKind.android);
      expect(reason, isNotNull);
      expect(reason, contains('没有 Android'));
      expect(reason, contains('iOS'), reason: '原因里要说明另一类有几个，便于判断目录是否指对了');
      expect(reason, contains('2'));
    });

    test('只有 APK：Android 可跑，iOS 的原因指明「没有 iOS 样本」', () {
      touch('a.apk');

      final scan = SampleDirectory.scan(path: temp.path);
      expect(scan.skipReasonFor(SampleKind.android), isNull);
      final reason = scan.skipReasonFor(SampleKind.ios);
      expect(reason, contains('没有 iOS'));
    });
  });

  group('两类样本都有时都可以跑', () {
    test('同时存在 APK 与 IPA 时两个 skipReason 都是 null', () {
      touch('a.apk');
      touch('a.ipa');

      final scan = SampleDirectory.scan(path: temp.path);
      expect(scan.status, SampleDirStatus.ready);
      expect(scan.skipReasonFor(SampleKind.android), isNull);
      expect(scan.skipReasonFor(SampleKind.ios), isNull);
    });
  });

  group('扩展名识别', () {
    test('Android 认全家族：apk / xapk / apkm / apks', () {
      for (final ext in SampleKind.android.extensions) {
        final dir = Directory.systemTemp.createTempSync('appinfotool_ext_');
        addTearDown(() {
          if (dir.existsSync()) dir.deleteSync(recursive: true);
        });
        File(p.join(dir.path, 'sample$ext')).writeAsStringSync('x');

        final scan = SampleDirectory.scan(path: dir.path);
        expect(scan.androidSamples, hasLength(1),
            reason: '$ext 应当被认成 Android 样本');
        expect(scan.skipReasonFor(SampleKind.android), isNull);
      }
    });

    test('大小写不敏感', () {
      touch('APP.APK');
      touch('APP.IPA');

      final scan = SampleDirectory.scan(path: temp.path);
      expect(scan.androidSamples, hasLength(1));
      expect(scan.iosSamples, hasLength(1));
    });

    test('后缀必须完整匹配，不能把 .apk.bak 当成样本', () {
      touch('a.apk.bak');

      final scan = SampleDirectory.scan(path: temp.path);
      expect(scan.status, SampleDirStatus.noSupportedSamples);
    });
  });

  group('结果稳定性', () {
    test('样本按路径排序，多次扫描结果一致', () {
      touch('c.apk');
      touch('a.apk');
      touch('b.apk');

      final first = SampleDirectory.scan(path: temp.path).androidSamples;
      final second = SampleDirectory.scan(path: temp.path).androidSamples;

      expect(first.map((f) => p.basename(f.path)).toList(),
          ['a.apk', 'b.apk', 'c.apk']);
      expect(second.map((f) => f.path).toList(),
          first.map((f) => f.path).toList());
    });

    test('子目录里的文件不计入（不递归）', () {
      Directory(p.join(temp.path, 'nested')).createSync();
      File(p.join(temp.path, 'nested', 'inner.apk')).writeAsStringSync('x');

      final scan = SampleDirectory.scan(path: temp.path);
      expect(scan.status, SampleDirStatus.empty,
          reason: '子目录里的文件不算样本，否则 fileCount 会骗人');
    });
  });

  group('摘要可辨识', () {
    test('summary 同时给出状态与两类样本数量', () {
      touch('a.apk');
      touch('b.ipa');
      touch('c.ipa');

      final summary = SampleDirectory.scan(path: temp.path).summary;
      expect(summary, contains('可用'));
      expect(summary, contains('android=1'));
      expect(summary, contains('ios=2'));
    });
  });
}
