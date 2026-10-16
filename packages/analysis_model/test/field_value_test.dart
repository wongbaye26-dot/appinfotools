// `FieldValue` 的「值 + 状态 + 来源 + 诊断」四件套（含阶段 5 之后的
// `diagnosticCode` / `diagnosticArgs`）。
//
// 这一组的重点是**七个构造器一个都不能漏** —— `diagnosticCode` 是可选参数，
// 漏掉某个构造器不会有任何编译错误，只会让那一类字段的诊断悄悄退回英文原文。

import 'package:analysis_model/analysis_model.dart';
import 'package:test/test.dart';

/// 七个构造器各造一个实例，附带它们的名字（失败信息里要用）。
List<({String name, FieldValue<Object?> value})> _allConstructors() => [
      (
        name: 'extracted',
        value: FieldValue<Object?>.extracted(
          'v',
          source: FieldSource.builtinParser,
          diagnostic: 'D',
          diagnosticCode: 'c',
          diagnosticArgs: {'k': 'v'},
        ),
      ),
      (
        name: 'absent',
        value: const FieldValue<Object?>.absent(
          diagnostic: 'D',
          diagnosticCode: 'c',
          diagnosticArgs: {'k': 'v'},
        ),
      ),
      (
        name: 'wrongType',
        value: const FieldValue<Object?>.wrongType(
          diagnostic: 'D',
          diagnosticCode: 'c',
          diagnosticArgs: {'k': 'v'},
        ),
      ),
      (
        name: 'unsupported',
        value: const FieldValue<Object?>.unsupported(
          diagnostic: 'D',
          diagnosticCode: 'c',
          diagnosticArgs: {'k': 'v'},
        ),
      ),
      (
        name: 'failed',
        value: const FieldValue<Object?>.failed(
          diagnostic: 'D',
          diagnosticCode: 'c',
          diagnosticArgs: {'k': 'v'},
        ),
      ),
      (
        name: 'hardenedUnknown',
        value: const FieldValue<Object?>.hardenedUnknown(
          diagnostic: 'D',
          diagnosticCode: 'c',
          diagnosticArgs: {'k': 'v'},
        ),
      ),
      (
        name: 'notRequested',
        value: const FieldValue<Object?>.notRequested(
          diagnostic: 'D',
          diagnosticCode: 'c',
          diagnosticArgs: {'k': 'v'},
        ),
      ),
    ];

void main() {
  group('FieldValue 的诊断标识', () {
    test('七个构造器都带上了 diagnosticCode 与 diagnosticArgs', () {
      final all = _allConstructors();
      expect(all.length, 7, reason: '构造器数量变了，这个测试要跟着改');
      for (final entry in all) {
        expect(entry.value.diagnosticCode, 'c', reason: entry.name);
        expect(entry.value.diagnosticArgs, {'k': 'v'}, reason: entry.name);
        expect(entry.value.diagnostic, 'D', reason: entry.name);
      }
    });

    test('不传时 diagnosticCode 为 null、args 为空表', () {
      const v = FieldValue<Object?>.absent();
      expect(v.diagnosticCode, isNull);
      expect(v.diagnosticArgs, isEmpty);
    });

    test('toString 带上 code，便于排查时看出走没走本地化', () {
      expect(
        const FieldValue<Object?>.notRequested(
          diagnostic: 'D',
          diagnosticCode: 'c',
        ).toString(),
        contains('diagnosticCode: c'),
      );
      expect(
        const FieldValue<Object?>.notRequested(diagnostic: 'D').toString(),
        isNot(contains('diagnosticCode')),
      );
    });

    test('默认 args 是同一个不可变空表，不会被调用方改坏', () {
      const a = FieldValue<Object?>.absent();
      const b = FieldValue<Object?>.failed(diagnostic: 'x');
      expect(identical(a.diagnosticArgs, b.diagnosticArgs), isTrue);
      expect(() => a.diagnosticArgs['x'] = 1, throwsUnsupportedError);
    });

    test('overriddenBy 仍然只认有值的候选（不受诊断字段影响）', () {
      const good = FieldValue<Object?>.extracted(
        'v',
        source: FieldSource.builtinParser,
      );
      const bad = FieldValue<Object?>.unsupported(
        diagnostic: 'D',
        diagnosticCode: 'c',
      );
      expect(good.overriddenBy(bad), same(good));
      expect(bad.overriddenBy(good), same(good));
    });
  });
}
