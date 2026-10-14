// 中英文 README 的一致性校验（阶段 7）。
//
// 两份 README 是同一份文档的两个语言版本。它们**不需要逐句对应**（翻译本来就
// 不该逐字对齐），但**结构不变量必须一致** —— 否则会出现「中文版写了某个限制、
// 英文版没写」这类读者看不到的偏差。
//
// 校验的是结构不变量而不是文本：
// 1. 标题层级序列一致（哪一级、几个）；
// 2. 围栏代码块数量一致（命令示例不该只在一侧有）；
// 3. 链接 URL 集合一致（尤其是仓库地址与 issues/releases 链接）；
// 4. 两份都非空，且都有许可证与致谢这类必备章节。
//
// 刻意**不**断言标题文本、段落数量、行数 —— 那些会随翻译自然变化，
// 断言它们只会制造无意义的失败。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String name) {
  final file = File(name);
  expect(file.existsSync(), isTrue, reason: '$name 不存在');
  return file.readAsStringSync();
}

/// 标题层级序列，例如 `[2, 2, 3, 3, 2]`。
List<int> _headingLevels(String markdown) => [
      for (final match
          in RegExp(r'^(#{2,6}) ', multiLine: true).allMatches(markdown))
        match.group(1)!.length,
    ];

/// 围栏代码块的数量（``` 出现的次数）。
int _fenceCount(String markdown) =>
    RegExp(r'^```', multiLine: true).allMatches(markdown).length;

/// 文档里出现的全部 http(s) 链接（去重、排序）。
List<String> _urls(String markdown) {
  final urls = RegExp(r'https?://[^\s\)\]>"' "'" r']+')
      .allMatches(markdown)
      .map((m) => m.group(0)!)
      .toSet()
      .toList()
    ..sort();
  return urls;
}

void main() {
  group('README 中英文一致性', () {
    // 惰性求值：group 声明期不能调 `expect`（会在测试体外抛
    // OutsideTestException）。首次访问发生在测试体内，那时才是合法的。
    late final String zh;
    late final String en;
    setUpAll(() {
      zh = _read('README.md');
      en = _read('README_en.md');
    });

    test('两份都非空且体量相当（避免一侧被清空或截断）', () {
      expect(zh.trim(), isNotEmpty);
      expect(en.trim(), isNotEmpty);
      // 只做一个非常宽松的检查：体量差异超过 3 倍就说明有一侧不正常。
      final ratio = zh.length / en.length;
      expect(
        ratio,
        inInclusiveRange(1 / 3, 3),
        reason: '中英文字数比 ${ratio.toStringAsFixed(2)}，'
            '差得太多说明有一侧缺内容',
      );
    });

    test('标题层级序列一致', () {
      expect(
        _headingLevels(zh),
        _headingLevels(en),
        reason: '某一侧多了或少了一节 —— 结构不对应',
      );
    });

    test('围栏代码块数量一致（命令示例不该只在一侧）', () {
      expect(
        _fenceCount(zh),
        _fenceCount(en),
        reason: '代码块数量不同，说明有一侧缺了命令示例',
      );
    });

    test('链接 URL 集合一致（仓库地址 / issues / releases 必须同步）', () {
      expect(
        _urls(zh),
        _urls(en),
        reason: '两份文档指向的地址不同 —— 读者会点到一个不存在的页面',
      );
    });

    test('两份都包含必备章节（许可证与致谢）', () {
      // 用链接集合之外的方式确认必备章节存在：按标题文本匹配。
      expect(zh, contains('## 开源协议'));
      expect(en, contains('## License'));
      expect(zh, contains('## 致谢'));
      expect(en, contains('## Acknowledgements'));
    });
  });

  group('README 与仓库事实一致', () {
    test('README 里的仓库地址与 pubspec 的仓库地址一致', () {
      final pubspec = _read('pubspec.yaml');
      final urls = _urls(_read('README.md'));

      // pubspec 里若声明了 repository，README 里必须出现同一个地址。
      final match =
          RegExp(r'^repository:\s*(\S+)', multiLine: true).firstMatch(pubspec);
      if (match == null) return; // 没声明就不校验，不编造要求
      expect(
        urls,
        contains(match.group(1)),
        reason: 'pubspec 的 repository 没出现在 README 里',
      );
    });

    test('README 提到的许可证与 LICENSE 文件一致', () {
      final license = File('LICENSE');
      if (!license.existsSync()) return;
      final text = license.readAsStringSync().toLowerCase();
      final zh = _read('README.md');

      if (text.contains('mit license')) {
        expect(
          zh.contains('MIT'),
          isTrue,
          reason: 'LICENSE 是 MIT，但 README 里没写',
        );
      }
    });
  });
}
