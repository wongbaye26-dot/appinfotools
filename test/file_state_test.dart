// FileState 的值语义测试（审计 5.9）。
//
// 两件事：`copyWith` 必须能**清空**字段（旧的 `??` 写法做不到），以及实现
// `==` 之后「内容没变」不再触发通知 —— Riverpod 的 `updateShouldNotify`
// 默认就是 `previous != next`，所以 `==` 直接决定了会不会多余重建。

import 'package:apk_info_tool/apkparser/apk_info.dart';
import 'package:apk_info_tool/providers/info_page_provider.dart';
import 'package:apk_info_tool/utils/signature_analyzer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('FileState.copyWith 的置空语义', () {
    test('不传参数时保留原值', () {
      final base = FileState(filePath: '/a.apk', fileSize: 10, md5Hash: 'm');

      final copy = base.copyWith();

      expect(copy.filePath, '/a.apk');
      expect(copy.fileSize, 10);
      expect(copy.md5Hash, 'm');
    });

    test('显式传 null 能清空字段，未传的字段保持不变', () {
      final base = FileState(filePath: '/a.apk', md5Hash: 'm', sha1Hash: 's');

      final copy = base.copyWith(filePath: null, md5Hash: null);

      expect(copy.filePath, isNull);
      expect(copy.md5Hash, isNull);
      expect(copy.sha1Hash, 's', reason: '未传的字段应保留');
    });

    test('可以清空 signature —— 切文件时不会留下上一个文件的签名结果', () {
      final base = FileState(signature: SignatureAnalysis.toolUnavailable('x'));

      expect(base.copyWith(signature: null).signature, isNull);
      expect(base.copyWith().signature, isNotNull);
    });

    test('非空值正常覆盖', () {
      final base = FileState(md5Hash: 'old');

      expect(base.copyWith(md5Hash: 'new').md5Hash, 'new');
      expect(base.copyWith(fileSize: 42).fileSize, 42);
    });
  });

  group('FileState 值语义', () {
    test('字段相同的两个实例相等，hashCode 一致', () {
      final a = FileState(filePath: '/a.apk', fileSize: 1, md5Hash: 'm');
      final b = FileState(filePath: '/a.apk', fileSize: 1, md5Hash: 'm');

      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
    });

    test('任一字段不同即不相等', () {
      final base = FileState(filePath: '/a.apk', md5Hash: 'm');

      expect(base == base.copyWith(md5Hash: 'x'), isFalse);
      expect(base == base.copyWith(fileSize: 5), isFalse);
      expect(base == base.copyWith(sha256Hash: 'z'), isFalse);
    });

    test('apkInfo 按引用比较：实例不同即视为不同结果', () {
      expect(
        FileState(apkInfo: ApkInfo()) == FileState(apkInfo: ApkInfo()),
        isFalse,
        reason: '两次独立解析是两次不同的结果，即使字段看起来一样',
      );

      final shared = ApkInfo();
      expect(
        FileState(apkInfo: shared) == FileState(apkInfo: shared),
        isTrue,
      );
    });

    test('isComputingHash 的变化被识别，重复设同值则视为无变化', () {
      const computing = FileState(isComputingHash: true);
      final done = computing.copyWith(isComputingHash: false);

      expect(done == computing, isFalse);
      // 关键：没有变化时不应通知监听者，避免多余重建
      expect(done == done.copyWith(isComputingHash: false), isTrue);
    });

    test('默认构造与空副本相等（无变化时不通知监听者）', () {
      const empty = FileState();

      expect(empty == empty.copyWith(), isTrue);
    });
  });
}
