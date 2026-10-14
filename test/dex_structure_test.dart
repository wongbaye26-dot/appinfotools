// DEX 结构解析与边界校验。
//
// 正常样本是 `javac` + `d8` **真实产出**的 DEX（见 `test/fixtures/dex/README.md`），
// 期望值来自 `dexdump -f` 的输出 —— **不是**从本项目的解析器取的，那样等于自证。
//
// 畸形样本是手工改的：没有工具会产出「声明尺寸与实际不符」的 DEX，而这正是
// 要防的形态。每个畸变都先用 `dexdump` 核对过它的判断，期望值记在 README 里。
//
// 为什么值得单独钉住：DEX 头是一段**按偏移访问的二进制结构**，偏移写错不会
// 报错，只会读出一个看起来合理的错值（本人在写夹具时就把 88/92 记反过，
// 是 dexdump 的报错纠正了我）。用真实产物做样本，偏移错了就会被工具打脸。

import 'dart:io';
import 'dart:typed_data';

import 'package:apk_parser/apk_parser.dart';
import 'package:flutter_test/flutter_test.dart';

const String _fixtureDir = 'test/fixtures/dex';

Uint8List _fixture(String name) => File('$_fixtureDir/$name').readAsBytesSync();

DexStructure _read(String name) => DexStructure.read(name, _fixture(name));

/// 某条异常是否存在。
bool _has(DexStructure s, String code) =>
    s.anomalies.any((a) => a.code == code);

List<String> _codes(DexStructure s) => [for (final a in s.anomalies) a.code];

void main() {
  group('真实 DEX（javac + d8 产出）', () {
    test('头部字段与 dexdump 的结论一致', () {
      final s = _read('real-netprobe.dex');

      // dexdump -f 对这个文件输出：
      //   magic 'dex\n035\0' / file_size 1624 / header_size 112
      //   string_ids_size 30 / type_ids_size 12 / proto_ids_size 8
      //   field_ids_size 0 / method_ids_size 11 / class_defs_size 2
      expect(s.version, 35);
      expect(s.declaredFileSize, 1624);
      expect(s.byteLength, 1624);
      expect(s.declaredHeaderSize, 112);
      expect(s.endianTag, kDexEndianConstant);

      expect(s.section('string_ids')!.size, 30);
      expect(s.section('type_ids')!.size, 12);
      expect(s.section('proto_ids')!.size, 8);
      expect(s.section('field_ids')!.size, 0);
      expect(s.section('method_ids')!.size, 11);
      expect(s.section('class_defs')!.size, 2);
    });

    test('段偏移与 dexdump 一致（string 112 / type 232 / method 376 / class 464）', () {
      final s = _read('real-netprobe.dex');

      expect(s.section('string_ids')!.offset, 112);
      expect(s.section('type_ids')!.offset, 232);
      expect(s.section('proto_ids')!.offset, 280);
      expect(s.section('method_ids')!.offset, 376);
      expect(s.section('class_defs')!.offset, 464);
    });

    test('没有异常，且结构可遍历', () {
      final s = _read('real-netprobe.dex');

      expect(_codes(s), isEmpty);
      expect(s.isTraversable, isTrue);
      expect(s.usableSections, hasLength(6));
    });

    test('adler32 与外部实现一致', () {
      // dexdump 打印的 checksum 是 6bee065c，Python 的 zlib.adler32(raw[12:])
      // 也是 6bee065c。两者都与本项目无关 —— 这就是这条断言的意义。
      final bytes = _fixture('real-netprobe.dex');

      expect(adler32(bytes, start: 12), 0x6bee065c);
    });
  });

  group('畸形 DEX 必须被如实记下（期望值来自 dexdump）', () {
    /// 夹具 -> 期望的异常 code。
    ///
    /// 括号里是 `dexdump` 对同一个文件的结论，用来证明期望值不是编的。
    const cases = <String, String>{
      // File size is 800 but the header expects 1624
      'truncated.dex': 'dex.file_size_mismatch',
      // File size is 1624 but the header expects 999999
      'header-file-size-mismatch.dex': 'dex.file_size_mismatch',
      // Expected valid zip or dex file
      'bad-magic.dex': 'dex.bad_magic',
      // Header size is 64 but 112 was expected
      'header-size-not-standard.dex': 'dex.header_size_not_standard',
      // Offset(16777215) should be within file size(1624) for method-ids
      'method-ids-off-out-of-range.dex': 'dex.section_out_of_range',
      // Section end(16777591) should be within file size(1624) for method-ids
      'method-ids-size-absurd.dex': 'dex.section_out_of_range',
      // Bad offset for section: got 70, expected 0
      'string-ids-off-in-header.dex': 'dex.section_overlaps_header',
    };

    cases.forEach((file, code) {
      test('$file → $code', () {
        final s = _read(file);

        expect(
          _codes(s),
          contains(code),
          reason: '实际记下的是 ${s.anomalies}',
        );
        expect(
          s.anomalies.firstWhere((a) => a.code == code).blocking,
          isTrue,
          reason: '结构不可信时，任何「没发现线索」的结论都不成立',
        );
        expect(s.isTraversable, isFalse);
      });
    });

    test('异常说明里带上具体的数字，而不是只说「结构错误」', () {
      final s = _read('truncated.dex');
      final message = s.anomalies
          .firstWhere((a) => a.code == 'dex.file_size_mismatch')
          .message;

      expect(message, contains('1624'), reason: '头部声明的尺寸');
      expect(message, contains('800'), reason: '实际尺寸');
      // 截断后 adler32 必然也对不上 —— 这是顺带被发现的第二条，不是误报。
      expect(_has(s, 'dex.checksum_mismatch'), isTrue);
    });
  });

  group('边角情况', () {
    test('短于 112 字节时不越界读取，直接记「太短」', () {
      for (final length in [0, 1, 111]) {
        final s = DexStructure.read('tiny.dex', Uint8List(length));

        expect(s.version, isNull, reason: 'length=$length');
        expect(_codes(s), ['dex.too_short'], reason: 'length=$length');
        expect(s.isTraversable, isFalse, reason: 'length=$length');
      }
    });

    test('刚好 112 字节时能读出头部（不因长度而误判）', () {
      final full = _fixture('real-netprobe.dex');
      final headerOnly = Uint8List.sublistView(full, 0, 112);

      final s = DexStructure.read('header-only.dex', headerOnly);

      expect(s.version, 35);
      expect(s.declaredHeaderSize, 112);
      // 段表读出来了，但都在文件之外 —— 这才是这条样本的真实情况。
      expect(_has(s, 'dex.file_size_mismatch'), isTrue);
      expect(_has(s, 'dex.section_out_of_range'), isTrue);
    });

    test('同时有多处异常时全部报告，不是只报第一条', () {
      // dexdump 对同一个文件只输出第一条（Header size is 64 …），
      // 这里刻意报告全部 —— 排查时「还有哪些地方对不上」比「第一个对不上的」
      // 有用得多。
      final s = _read('multiple-anomalies.dex');

      expect(_has(s, 'dex.file_size_mismatch'), isTrue);
      expect(_has(s, 'dex.header_size_not_standard'), isTrue);
      expect(_has(s, 'dex.checksum_mismatch'), isTrue);
    });

    test('段规模是天文数字时稳稳判为越界', () {
      // method_ids_size = 0xFFFFFF、itemSize = 8。判定用的是除法，任何整数
      // 宽度下都等价于「装得下吗」，不会因为乘法形式而漏判。
      final s = _read('method-ids-size-absurd.dex');
      final section = s.section('method_ids')!;

      expect(section.size, 0xFFFFFF);
      expect(section.fitsWithin(s.byteLength), isFalse);
    });
  });

  group('校验和：只说事实，不当成恶意证据', () {
    test('校验和被清零时记一条**非阻断**异常', () {
      // dexdump: Bad checksum (6bee065c, expected 00000000)
      final s = _read('checksum-zeroed.dex');
      final anomaly = s.anomalies.firstWhere(
        (a) => a.code == 'dex.checksum_mismatch',
      );

      expect(
        anomaly.blocking,
        isFalse,
        reason: '校验和不符不代表结构不可信 —— 有些工具会把它清零，'
            '而且任何攻击者都能重算。为此拒绝解析只会丢掉信息。',
      );
      expect(s.isTraversable, isTrue, reason: '结构本身是好的，应当继续解析');
    });

    test('措辞里说清「不代表恶意」，并点出未验证 SHA-1', () {
      final s = _read('checksum-zeroed.dex');
      final message = s.anomalies
          .firstWhere((a) => a.code == 'dex.checksum_mismatch')
          .message;

      expect(message, contains('不代表恶意'));
      expect(
        message,
        contains('SHA-1'),
        reason: '只验了 adler32，没验签名 —— 局限必须写在结论旁边',
      );
    });
  });
}
