// 包级测试：两份包之间的结构化差异（V2.4.0 阶段 5.1）。
//
// 这个包是零依赖的，因此这里的测试也只用 `package:test` ——
// 差异逻辑不认识任何平台概念，只认「字段 id → 带状态的值」与「集合 id → 成员」。

import 'package:analysis_model/analysis_model.dart';
import 'package:test/test.dart';

FieldValue<Object?> _has(Object? v) =>
    FieldValue<Object?>.extracted(v, source: FieldSource.builtinParser);

const _absent = FieldValue<Object?>.absent();
const _unsupported = FieldValue<Object?>.unsupported(
  diagnostic: 'aapt2 does not report this field',
);

/// 集合也要带状态：`absent`（文件里确实没有）与 `unsupported`（来源不报）
/// 对差异的含义完全相反。
FieldValue<List<String>> _members(List<String> v) =>
    FieldValue<List<String>>.extracted(v, source: FieldSource.builtinParser);

DiffSubject _subject({
  List<({String id, FieldValue<Object?> value})> fields = const [],
  Map<String, FieldValue<List<String>>> sets = const {},
}) =>
    DiffSubject(fields: fields, sets: sets);

void main() {
  group('字段级差异', () {
    test('左边没有、右边有 → added', () {
      final diff = diffSubjects(
        _subject(fields: [(id: 'a', value: _absent)]),
        _subject(fields: [(id: 'a', value: _has(1))]),
      );
      expect(diff.fields.single.kind, DiffKind.added);
      expect(diff.hasChanges, isTrue);
    });

    test('左边有、右边没有 → removed', () {
      final diff = diffSubjects(
        _subject(fields: [(id: 'a', value: _has(1))]),
        _subject(fields: [(id: 'a', value: _absent)]),
      );
      expect(diff.fields.single.kind, DiffKind.removed);
      expect(diff.hasChanges, isTrue);
    });

    test('两侧都有值但不同 → changed', () {
      final diff = diffSubjects(
        _subject(fields: [(id: 'a', value: _has(21))]),
        _subject(fields: [(id: 'a', value: _has(34))]),
      );
      expect(diff.fields.single.kind, DiffKind.changed);
    });

    test('两侧相同 → same，且不算差异', () {
      final diff = diffSubjects(
        _subject(fields: [(id: 'a', value: _has(21))]),
        _subject(fields: [(id: 'a', value: _has(21))]),
      );
      expect(diff.fields.single.kind, DiffKind.same);
      expect(diff.hasChanges, isFalse);
    });

    test('两侧都没有 → same（文件里都没有，不是差异）', () {
      final diff = diffSubjects(
        _subject(fields: [(id: 'a', value: _absent)]),
        _subject(fields: [(id: 'a', value: _absent)]),
      );
      expect(diff.fields.single.kind, DiffKind.same);
    });

    test('一侧「没读到」→ unknown，且不计入 hasChanges 但要单独报出来', () {
      final diff = diffSubjects(
        _subject(fields: [(id: 'a', value: _unsupported)]),
        _subject(fields: [(id: 'a', value: _has(1))]),
      );
      expect(
        diff.fields.single.kind,
        DiffKind.unknown,
        reason: '「左边没读到」不能读成「左边没有」，因此不能判成 added',
      );
      expect(diff.fields.single.isComparable, isFalse);
      expect(
        diff.hasChanges,
        isFalse,
        reason: 'unknown 不是差异 —— 它是「这次说不清」',
      );
      expect(diff.unknownFieldCount, 1, reason: '必须能单独数出来');
      // 两侧原始状态都带在结果里，界面才能显示「左边：unsupported（原因）」。
      expect(diff.fields.single.left.status, FieldStatus.unsupported);
      expect(diff.fields.single.left.diagnostic, isNotNull);
    });

    test('右侧独有的字段也计入差异', () {
      final diff = diffSubjects(
        _subject(),
        _subject(fields: [(id: 'only.right', value: _has(1))]),
      );
      expect(diff.fields.single.id, 'only.right');
      expect(diff.fields.single.kind, DiffKind.added);
    });

    test('输出顺序 = 左侧字段顺序', () {
      final diff = diffSubjects(
        _subject(fields: [
          (id: 'a', value: _has(1)),
          (id: 'b', value: _has(2)),
          (id: 'c', value: _has(3)),
        ]),
        _subject(fields: [
          (id: 'c', value: _has(3)),
          (id: 'b', value: _has(2)),
          (id: 'a', value: _has(1)),
        ]),
      );
      expect(diff.fields.map((f) => f.id), ['a', 'b', 'c']);
      expect(diff.hasChanges, isFalse);
    });
  });

  group('集合级差异', () {
    test('added / removed / common 各就位', () {
      final diff = diffSubjects(
          _subject(sets: {
            'permissions': _members(['A', 'B', 'C']),
          }),
          _subject(sets: {
            'permissions': _members(['B', 'C', 'D']),
          }));

      final s = diff.sets.single;
      expect(s.added, ['D']);
      expect(s.removed, ['A']);
      expect(s.common, ['B', 'C']);
      expect(s.isSame, isFalse);
      expect(diff.hasChanges, isTrue);
    });

    test('顺序沿用来源顺序，不重排', () {
      // 域名是按扫描到的顺序来的；重排会让「同一个包两次比较」输出不一致。
      final diff = diffSubjects(
          _subject(sets: {
            'domains': _members(['z.example', 'a.example']),
          }),
          _subject(sets: {
            'domains': _members(['a.example', 'z.example']),
          }));
      final s = diff.sets.single;
      expect(s.isSame, isTrue);
      expect(s.common, ['z.example', 'a.example'], reason: '按左侧顺序');
    });

    test('集合相同 → isSame，且不算差异', () {
      final diff = diffSubjects(
        _subject(sets: {
          'x': _members(['A'])
        }),
        _subject(sets: {
          'x': _members(['A'])
        }),
      );
      expect(diff.sets.single.isSame, isTrue);
      expect(diff.hasChanges, isFalse);
    });

    test('一侧「没读到」→ comparable 为 false，且不给 added/removed', () {
      // 左边读到了权限、右边这个来源不报权限。**绝不能**说成
      // 「右边的这些权限被删掉了」—— 那是把「没查到」当成「没有」。
      final diff = diffSubjects(
          _subject(sets: {
            'permissions': _members(['A', 'B']),
          }),
          _subject(sets: {
            'permissions': const FieldValue<List<String>>.unsupported(
              diagnostic: 'this source does not report permissions',
            ),
          }));

      final s = diff.sets.single;
      expect(s.comparable, isFalse);
      expect(s.added, isEmpty, reason: '不能把「没读到」算成对方新增');
      expect(s.removed, isEmpty, reason: '不能把「没读到」算成对方删除');
      expect(
        diff.hasChanges,
        isFalse,
        reason: '不可比不是差异 —— 它是「这次说不清」',
      );
    });

    test('右侧独有的集合维度也出现，不被静默丢掉', () {
      final diff = diffSubjects(
        _subject(sets: {
          'a': _members(['1'])
        }),
        _subject(sets: {
          'a': _members(['1']),
          'b': _members(['2'])
        }),
      );
      expect(diff.sets.map((s) => s.id), ['a', 'b']);
      expect(diff.sets.last.added, ['2']);
    });
  });
}
