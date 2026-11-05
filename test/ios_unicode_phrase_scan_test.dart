// iOS Unicode / 中文话术扫描的端到端接入测试。
//
// 三条链路要分别验证，因为任何一条单独挂掉都不会让另两条变红：
//   1. `__TEXT,__cstring` 形态的 UTF-8 中文（此前**完全看不到**）；
//   2. 散落在文件里的小端 UTF-16 中文；
//   3. `__TEXT,__ustring` 节里的大端 / 奇对齐 UTF-16 中文。
//
// 第 3 条需要一个带 `__ustring` 节的 Mach-O。仓库里的真实 dylib 夹具都是
// clang 编的 C 代码，没有这个节，所以这里只手搭**结构容器**（头 + 一个段
// 命令 + 一个节表项）来把字节送到节路径上；它不是「真实 App 样本」，
// 期望值也只是「我们放进去的原文能被捞出来」。

import 'dart:convert';
import 'dart:typed_data';

import 'package:analysis_model/analysis_model.dart';
import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/utils/analysis_report.dart';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ipa_parser/ipa_parser.dart';

const _bundlePath = 'Payload/Example.app';
const _exePath = '$_bundlePath/Example';

Uint8List _utf8Strings(List<String> texts) => Uint8List.fromList([
      // 每条后面留一个 NUL，模拟 `__cstring` 的 C 字符串边界。
      for (final text in texts) ...[...const Utf8Encoder().convert(text), 0],
    ]);

Uint8List _utf16Strings(List<String> texts, {required bool bigEndian}) {
  final out = <int>[];
  for (final text in texts) {
    for (final unit in text.codeUnits) {
      final low = unit & 0xff;
      final high = (unit >> 8) & 0xff;
      out.addAll(bigEndian ? [high, low] : [low, high]);
    }
    out.addAll([0, 0]);
  }
  return Uint8List.fromList(out);
}

/// 最小 Mach-O 容器：64 位小端头 + `LC_SEGMENT_64` + 一个 `__ustring` 节。
Uint8List _machOWithUstring(List<int> sectionData) {
  const headerSize = 32;
  const commandSize = 152; // 72 (segment_command_64) + 80 (section_64)
  const dataOffset = headerSize + commandSize;
  final out = Uint8List(dataOffset + sectionData.length);
  final data = ByteData.sublistView(out);

  void u32(int offset, int value) =>
      data.setUint32(offset, value, Endian.little);
  void u64(int offset, int value) =>
      data.setUint64(offset, value, Endian.little);
  void fixedName(int offset, String value) {
    for (var i = 0; i < 16; i++) {
      out[offset + i] = i < value.length ? value.codeUnitAt(i) : 0;
    }
  }

  // mach_header_64（文件本身小端：0xFEEDFACF 落盘为 CF FA ED FE）。
  u32(0, 0xFEEDFACF);
  u32(4, 0x0100000C); // CPU_TYPE_ARM64
  u32(8, 0);
  u32(12, 6); // MH_DYLIB
  u32(16, 1); // ncmds
  u32(20, commandSize); // sizeofcmds
  u32(24, 0); // flags
  u32(28, 0); // reserved

  // segment_command_64 @ 32
  u32(32, 0x19); // LC_SEGMENT_64
  u32(36, commandSize);
  fixedName(40, '__TEXT');
  u64(56, 0); // vmaddr
  u64(64, out.length); // vmsize
  u64(72, 0); // fileoff
  u64(80, out.length); // filesize
  u32(88, 7); // maxprot
  u32(92, 5); // initprot
  u32(96, 1); // nsects
  u32(100, 0); // flags

  // section_64 @ 104
  fixedName(104, '__ustring');
  fixedName(120, '__TEXT');
  u64(136, 0); // addr
  u64(144, sectionData.length); // size
  u32(152, dataOffset); // offset

  out.setRange(dataOffset, out.length, sectionData);
  return out;
}

SecurityAnalysisResult _audit(Uint8List bytes, {int? scanBudgetBytes}) {
  final bundle = const IosBundle(
    kind: IosBundleKind.mainApp,
    path: _bundlePath,
    name: 'Example.app',
  );
  final plist = const Utf8Encoder().convert(
    '<?xml version="1.0" encoding="UTF-8"?>'
    '<plist version="1.0"><dict>'
    '<key>CFBundleIdentifier</key><string>com.example.app</string>'
    '</dict></plist>',
  );
  final archive = Archive()
    ..addFile(ArchiveFile('$_bundlePath/Info.plist', plist.length, plist));

  return IosPrivacyAudit.audit(
    infoPlist: IpaInfoPlistReader.read(archive, bundle),
    executableBytes: bytes,
    executablePath: _exePath,
    scanBudgetBytes: scanBudgetBytes,
  );
}

SecurityFinding? _phrase(SecurityAnalysisResult result) {
  for (final f in result.findings) {
    if (f.ruleId == 'IOS-UNICODE-PHRASE') return f;
  }
  return null;
}

void main() {
  test('UTF-8 中文话术会产出 info 发现项，并把原文放进证据', () {
    final result = _audit(_utf8Strings([
      '客服解冻：资金冻结，请联系人工客服',
      '请输入助记词',
      '资金归集到归集地址',
    ]));

    final finding = _phrase(result);
    expect(finding, isNotNull, reason: 'UTF-8 中文此前完全看不到');
    expect(finding!.severity, SecuritySeverity.info);
    expect(finding.isMeta, isTrue);
    final evidence = finding.evidence.map((e) => e.detail).join('\n');
    expect(evidence, contains('资金冻结'));
    expect(evidence, contains('助记词'));
    expect(evidence, contains('资金归集'));

    final coverage = result.coverage.entry('ios.unicodeStrings');
    expect(coverage, isNotNull);
    expect(coverage!.status, CoverageStatus.covered);
    expect(coverage.covered, greaterThan(0));
    expect(coverage.limit, coverage.covered);
    expect(coverage.noteCode, 'ios.unicode_strings.scope');

    final source = result.cryptoTheft?.chain
        .firstWhere((e) => e.stage == ChainStage.source);
    expect(source?.evidence.map((e) => e.detail).join(' '),
        contains('unicode phrase'));
  });

  test('散落在文件里的小端 UTF-16 中文也能被捞到', () {
    final result = _audit(_utf16Strings(
      ['资金冻结', '助记词', '刷单返利'],
      bigEndian: false,
    ));
    expect(_phrase(result), isNotNull);
    expect(_phrase(result)!.evidence.map((e) => e.detail).join('\n'),
        contains('刷单返利'));
  });

  test('__ustring 节里的大端 UTF-16 中文靠四种组合扫描捞到', () {
    final section = _utf16Strings(
      ['资金冻结', '账户异常', '人工客服'],
      bigEndian: true,
    );
    final result = _audit(_machOWithUstring(section));
    final finding = _phrase(result);
    expect(finding, isNotNull, reason: '__ustring / BE 路径没有接上');
    expect(finding!.evidence.map((e) => e.detail).join('\n'), contains('账户异常'));
  });

  test('__ustring 节里奇对齐的小端中文同样捞得到', () {
    // 节内第一个字节是填充，宽字符串从奇数偏移开始。整文件的小端偶对齐
    // 遍历看不到它，只有节内四种组合扫描能覆盖。
    final section = Uint8List.fromList([
      0,
      ..._utf16Strings(['解冻', '保证金', '提现失败'], bigEndian: false),
    ]);
    final result = _audit(_machOWithUstring(section));
    final finding = _phrase(result);
    expect(finding, isNotNull, reason: '__ustring / 奇对齐路径没有接上');
    expect(finding!.evidence.map((e) => e.detail).join('\n'), contains('保证金'));
  });

  test('纯 ASCII 可执行文件：不产出话术发现项，但覆盖维度仍是 covered', () {
    final result = _audit(Uint8List.fromList(
      const Utf8Encoder()
          .convert('MetaMask\x00UIPasteboard\x00NSURLSession\x00'),
    ));
    expect(_phrase(result), isNull);
    final coverage = result.coverage.entry('ios.unicodeStrings')!;
    expect(coverage.status, CoverageStatus.covered, reason: '「没找到」不能显示成「没查」');
  });

  test('扫描预算截断时 Unicode 维度标 partial，说明里给出截断', () {
    final result = _audit(
      _utf8Strings(['资金冻结', '助记词', '人工客服']),
      scanBudgetBytes: 8,
    );
    final coverage = result.coverage.entry('ios.unicodeStrings')!;
    expect(coverage.status, CoverageStatus.partial);
    expect(coverage.noteCode, 'ios.unicode_strings.truncated');
    expect(coverage.note, contains('budget'));
  });

  test('读不到可执行内容时 Unicode 维度是 notCovered', () {
    final result = _audit(Uint8List(0));
    final coverage = result.coverage.entry('ios.unicodeStrings')!;
    expect(coverage.status, CoverageStatus.notCovered);
    expect(coverage.noteCode, 'ios.unicode_strings.no_content');
  });

  group('中文话术文案走本地化，不退回英文原文', () {
    SecurityFinding finding() => buildIosUnicodePhraseFindings(
          IosUnicodePhraseSignals()
            ..collect('资金冻结', 'Payload/App.app/App', unicode: true),
        ).single;

    test('zh-CN：三段都是中文，且没有未替换的占位符', () async {
      await LocaleSettings.setLocaleRaw('zh-CN');
      final f = finding();
      final text = AnalysisReport.findingText(f, t);
      expect(text, contains('中文钱包'));
      expect(text, isNot(contains('{')));
      expect(
        AnalysisReport.recommendationText(f, t),
        contains('上下文'),
      );
      expect(AnalysisReport.limitationText(f, t), contains('Swift'));
      expect(
        AnalysisReport.coverageDimensionLabel('ios.unicodeStrings', t),
        'Unicode 字符串',
      );
    });

    test('en：三段都是英文，中文界面不串到英文下', () async {
      await LocaleSettings.setLocaleRaw('en');
      final f = finding();
      expect(AnalysisReport.findingText(f, t), contains('UI copy clues'));
      expect(
        AnalysisReport.recommendationText(f, t),
        contains('seed phrase'),
      );
      expect(
        AnalysisReport.coverageDimensionLabel('ios.unicodeStrings', t),
        'Unicode strings',
      );
      await LocaleSettings.setLocaleRaw('en');
    });

    test('覆盖说明的三种 code 都有本地化句子', () async {
      await LocaleSettings.setLocaleRaw('zh-CN');
      for (final code in const [
        'ios.unicode_strings.scope',
        'ios.unicode_strings.truncated',
        'ios.unicode_strings.no_content',
      ]) {
        final note = AnalysisReport.coverageNote(
          CoverageEntry(
            id: 'ios.unicodeStrings',
            status: CoverageStatus.covered,
            noteCode: code,
            note: 'english fallback',
          ),
          t,
        );
        expect(note, isNot('english fallback'), reason: '$code 没注册');
        expect(note, contains(RegExp(r'[\u4e00-\u9fff]')));
      }
      await LocaleSettings.setLocaleRaw('en');
    });
  });
}
