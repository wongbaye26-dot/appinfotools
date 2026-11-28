import 'dart:convert';
import 'dart:io';

import 'package:apk_parser/apk_parser.dart';
import 'package:test/test.dart';

/// 上游 `matching-fixtures.json` 的 19 条匹配语义夹具。
///
/// 这份文件随数据分发，逐条断言的是「匹配规则」而不是「规则内容」：
/// 数据升级后夹具可能变，但语义（精确优先、整串锚定、跳过换行、按
/// priority 排序）不应该变。
void main() {
  final fixture = jsonDecode(
    File('test/fixtures/libchecker/matching-fixtures.json').readAsStringSync(),
  ) as Map<String, dynamic>;

  LibCheckerRules rulesOf(List<dynamic> rows) {
    return LibCheckerRules.fromBundle({
      'meta': {'dataVersion': 1},
      'rules': [
        for (final row in rows.cast<Map<String, dynamic>>())
          [
            row['id'],
            row['name'],
            'Label ${row['id']}',
            row['type'],
            null,
            0,
            -1,
            row['priority'],
          ],
      ],
      'regexIds': [
        for (final row in rows.cast<Map<String, dynamic>>())
          if (row['isRegexRule'] == true) row['id'],
      ],
      'details': const [],
    });
  }

  group('上游 matching-fixtures', () {
    for (final case_
        in (fixture['cases'] as List).cast<Map<String, dynamic>>()) {
      test(case_['name'] as String, () {
        final rules = rulesOf(case_['rules'] as List);
        final hit = rules.find(
          case_['type'] as int,
          case_['input'] as String,
          useRegex: case_['useRegex'] as bool? ?? true,
        );
        expect(hit?.id, case_['expected'], reason: '输入 ${case_['input']}');
      });
    }
  });

  group('LibCheckerRules', () {
    test('丢弃不参与匹配的类型', () {
      final rules = LibCheckerRules.fromBundle({
        'meta': {'dataVersion': 7},
        'rules': [
          [1, 'com.sec.android.permission.X', 'Permission', 7, null, 0, -1, 1],
          [2, 'libfoo.so', 'Foo', 0, 'ic_foo', 1, 0, 2],
        ],
        'regexIds': const [],
        'details': const [],
      });
      expect(rules.usableRuleCount, 1);
      expect(rules.dataVersion, 7);
      expect(rules.find(LibCheckerRuleType.native, 'libfoo.so')?.label, 'Foo');
    });

    test('精确表包含正则规则的字面名', () {
      final rules = LibCheckerRules.fromBundle({
        'meta': const {},
        'rules': [
          [1, r'foo|bar', 'Regex', 0, null, 0, -1, 1],
        ],
        'regexIds': [1],
        'details': const [],
      });
      // 字面量 `foo|bar` 精确命中，而不是被正则拆成 foo / bar。
      expect(
        rules.find(LibCheckerRuleType.native, 'foo|bar')?.id,
        1,
      );
      expect(rules.find(LibCheckerRuleType.native, 'foo')?.id, 1);
      expect(rules.find(LibCheckerRuleType.native, 'baz'), isNull);
    });

    test('正则按 priority 升序而非 id', () {
      final rules = LibCheckerRules.fromBundle({
        'meta': const {},
        'rules': [
          [9, r'com\..*', 'Low', 5, null, 0, -1, 50],
          [3, r'com\.example.*', 'High', 5, null, 0, -1, 1],
        ],
        'regexIds': [9, 3],
        'details': const [],
      });
      expect(rules.find(LibCheckerRuleType.dex, 'com.example.app')?.id, 3);
    });

    test('名字含换行时跳过正则但保留精确匹配', () {
      final rules = LibCheckerRules.fromBundle({
        'meta': const {},
        'rules': [
          [1, r'.*', 'Any', 0, null, 0, -1, 1],
        ],
        'regexIds': [1],
        'details': const [],
      });
      expect(rules.find(LibCheckerRuleType.native, 'libfoo.so'), isNotNull);
      expect(rules.find(LibCheckerRuleType.native, 'libfoo.so\n'), isNull);
      expect(rules.find(LibCheckerRuleType.native, 'lib\u2028foo'), isNull);
    });

    test(r'\d 归一化后仍能匹配数字', () {
      final rules = LibCheckerRules.fromBundle({
        'meta': const {},
        'rules': [
          [1, r'lib\d+\.so', 'Digits', 0, null, 0, -1, 1],
        ],
        'regexIds': [1],
        'details': const [],
      });
      expect(rules.find(LibCheckerRuleType.native, 'lib42.so')?.id, 1);
      expect(rules.find(LibCheckerRuleType.native, 'libx.so'), isNull);
      expect(rules.regexCompileFailures, isEmpty);
    });

    test('详情语言回退：zh-Hans → en → 第一项', () {
      final rules = LibCheckerRules.fromBundle({
        'meta': const {},
        'rules': [
          [1, 'libfoo.so', 'Foo', 0, 'ic_foo', 0, 0, 1],
          [2, 'libbar.so', 'Bar', 0, 'ic_bar', 0, 1, 2],
        ],
        'regexIds': const [],
        'details': [
          {
            'zh-Hans': [
              'Foo',
              '开发者甲',
              '说明甲',
              'https://a',
              ['贡献者甲']
            ],
            'en': [
              'Foo',
              'Dev A',
              'Desc A',
              'https://a',
              ['Contrib']
            ],
          },
          {
            'fr': ['Bar', 'Dev B', 'Desc B', null, null],
          },
        ],
      });
      final foo = rules.rules.firstWhere((r) => r.id == 1);
      final bar = rules.rules.firstWhere((r) => r.id == 2);
      expect(rules.detailFor(foo, 'zh-Hans')?.description, '说明甲');
      expect(rules.detailFor(foo, 'en')?.developer, 'Dev A');
      expect(rules.detailFor(foo, 'ja')?.developer, 'Dev A');
      expect(rules.detailFor(bar, 'ja')?.developer, 'Dev B');
      expect(rules.detailFor(bar, 'ja')?.contributors, isEmpty);
    });
  });
}
