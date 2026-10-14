// DEX 指令遍历：宽度表与载荷识别。
//
// 这一层最容易出的错不是「报错」，而是**静默错位**：指令长度 1–5 个代码单元，
// 宽度表错一格就会在指令中间停下，把别的指令的操作数当成方法索引 ——
// 结果看起来完全正常，却是错的。因此这里有三道防线：
//
// 1. 真实 DEX 上把每一步的偏移与 `dexdump -d` 逐个对照（下面内嵌了基准）；
// 2. 遍历必须**正好**落在 `insns_size` 末尾，否则 `reachedEnd` 为 false；
// 3. 载荷（switch / fill-array-data）单独识别 —— 首单元低字节是 0x00，
//    按 opcode 读会被当成 `nop`。
//
// 基准来源：`dexdump -d test/fixtures/dex/real-opcodes.dex` 的 `|XXXX:` 列，
// 十六进制转十进制。**不是**从本项目解析器取的。

import 'dart:io';
import 'dart:typed_data';

import 'package:apk_parser/apk_parser.dart';
import 'package:flutter_test/flutter_test.dart';

const String _fixtureDir = 'test/fixtures/dex';

Uint8List _bytes(String name) => File('$_fixtureDir/$name').readAsBytesSync();

DexStructure _structure(String name, [Uint8List? bytes]) =>
    DexStructure.read(name, bytes ?? _bytes(name));

/// `dexdump -d real-opcodes.dex` 里全部 101 条指令的代码单元偏移。
///
/// 覆盖 53 种助记符、8 个方法体，其中含一个 `sparse-switch-data` 载荷。
const List<int> _dexdumpOpcodeOffsets = [
  0,
  2,
  4,
  6,
  8,
  10,
  0,
  3,
  0,
  2,
  3,
  4,
  6,
  8,
  10,
  12,
  14,
  16,
  18,
  20,
  22,
  23,
  28,
  29,
  30,
  32,
  34,
  35,
  36,
  37,
  38,
  39,
  40,
  41,
  0,
  2,
  4,
  6,
  9,
  10,
  11,
  12,
  0,
  2,
  3,
  5,
  7,
  9,
  10,
  11,
  13,
  15,
  17,
  18,
  19,
  20,
  22,
  24,
  26,
  27,
  0,
  2,
  4,
  5,
  6,
  8,
  10,
  12,
  14,
  16,
  17,
  0,
  2,
  5,
  6,
  8,
  10,
  12,
  15,
  16,
  18,
  21,
  23,
  24,
  27,
  28,
  0,
  3,
  5,
  6,
  8,
  9,
  11,
  12,
  14,
  15,
  17,
  18,
  20,
  21,
  22,
];

void main() {
  group('宽度表', () {
    test('256 个 opcode 全部有宽度，没有留 0', () {
      expect(DexInstructionTable.widths, hasLength(256));
      final missing = <int>[
        for (var opcode = 0; opcode < 256; opcode++)
          if (DexInstructionTable.widthOf(opcode) == 0) opcode,
      ];
      expect(
        missing,
        isEmpty,
        reason: '宽度为 0 会让遍历原地打转。缺的 opcode：'
            '${missing.map((o) => '0x${o.toRadixString(16)}').toList()}',
      );
    });

    test('宽度都在 1–5 之间（DEX 规范的格式范围）', () {
      for (var opcode = 0; opcode < 256; opcode++) {
        final width = DexInstructionTable.widthOf(opcode);
        expect(width, inInclusiveRange(1, 5),
            reason: 'opcode 0x${opcode.toRadixString(16)}');
      }
    });

    test('抽查若干 opcode 的宽度（对照规范格式）', () {
      // 10x / 12x / 11n 等单单元形式
      expect(DexInstructionTable.widthOf(0x00), 1, reason: 'nop(10x)');
      expect(DexInstructionTable.widthOf(0x01), 1, reason: 'move(12x)');
      expect(DexInstructionTable.widthOf(0x12), 1, reason: 'const/4(11n)');
      expect(DexInstructionTable.widthOf(0x0e), 1, reason: 'return-void(10x)');
      // 两单元
      expect(DexInstructionTable.widthOf(0x13), 2, reason: 'const/16(21s)');
      expect(DexInstructionTable.widthOf(0x1a), 2, reason: 'const-string(21c)');
      expect(DexInstructionTable.widthOf(0x90), 2, reason: 'add-int(23x)');
      // 三单元
      expect(DexInstructionTable.widthOf(0x14), 3, reason: 'const(31i)');
      expect(DexInstructionTable.widthOf(0x1b), 3,
          reason: 'const-string/jumbo(31c)');
      expect(DexInstructionTable.widthOf(0x2c), 3,
          reason: 'sparse-switch(31t)');
      expect(DexInstructionTable.widthOf(0x6e), 3,
          reason: 'invoke-virtual(35c)');
      expect(DexInstructionTable.widthOf(0x78), 3,
          reason: 'invoke-interface/range(3rc)');
      // 四单元与五单元
      expect(DexInstructionTable.widthOf(0xfa), 4,
          reason: 'invoke-polymorphic(45cc)');
      expect(DexInstructionTable.widthOf(0x18), 5, reason: 'const-wide(51l)');
    });
  });

  group('载荷识别', () {
    test('真正的 nop 不是载荷', () {
      expect(DexInstructionTable.isPayloadHeader(0x0000), isFalse);
    });

    test('三个载荷标识都能识别', () {
      expect(
        DexInstructionTable.isPayloadHeader(
            DexInstructionTable.packedSwitchPayload),
        isTrue,
      );
      expect(
        DexInstructionTable.isPayloadHeader(
            DexInstructionTable.sparseSwitchPayload),
        isTrue,
      );
      expect(
        DexInstructionTable.isPayloadHeader(
            DexInstructionTable.fillArrayDataPayload),
        isTrue,
      );
    });

    test('packed-switch-payload 的长度是 2 + size × 2', () {
      // ident(0x0100) + size(3) + 3 个 u32 目标
      final insns = Uint16List.fromList([0x0100, 3, 0, 0, 0, 0, 0, 0]);
      expect(DexInstructionTable.payloadWidth(insns, 0), 2 + 3 * 2);
    });

    test('sparse-switch-payload 的长度是 2 + size × 4', () {
      // 每个条目是 key(u32) + target(u32) = 4 个代码单元
      final insns = Uint16List.fromList([0x0200, 2, ...List.filled(8, 0)]);
      expect(DexInstructionTable.payloadWidth(insns, 0), 2 + 2 * 4);
    });

    test('fill-array-data-payload 的长度按 element_width 与 size 算', () {
      // 8 字节头 + size × element_width，向上取整到偶数
      final insns =
          Uint16List.fromList([0x0300, 4, 3, 0, ...List.filled(12, 0)]);
      // bytes = 8 + 3*4 = 20 → 10 个代码单元
      expect(DexInstructionTable.payloadWidth(insns, 0), 10);
    });

    test('长度读不出来时返回 null，不猜', () {
      // 只有标识，没有 size
      expect(DexInstructionTable.payloadWidth(Uint16List.fromList([0x0100]), 0),
          isNull);
      // fill-array-data 的 size 是 u32，只有两个单元时读不全
      expect(
        DexInstructionTable.payloadWidth(
            Uint16List.fromList([0x0300, 4, 0]), 0),
        isNull,
      );
    });
  });

  group('真实 DEX：偏移与 dexdump 逐个对照', () {
    test('real-opcodes.dex 的 101 条指令偏移完全一致', () {
      final bytes = _bytes('real-opcodes.dex');
      final walked = <DexInstruction>[];
      final result = DexMethodBodies.walk(
        bytes,
        _structure('real-opcodes.dex', bytes),
        onInstruction: walked.add,
      );

      expect(
        walked.map((i) => i.offset).toList(),
        _dexdumpOpcodeOffsets,
        reason: '任何一步对不上都说明宽度表错了 —— 偏移会从那里开始整体漂移',
      );
      expect(result.instructionCount, _dexdumpOpcodeOffsets.length);
      expect(
        result.desyncedBodies,
        isEmpty,
        reason: '每个方法体都要正好走到 insns_size 末尾：${result.desyncedBodies}',
      );
    });

    test('载荷被当作一条指令跳过（sparse-switch-data 计入）', () {
      final bytes = _bytes('real-opcodes.dex');
      final walked = <DexInstruction>[];
      DexMethodBodies.walk(
        bytes,
        _structure('real-opcodes.dex', bytes),
        onInstruction: walked.add,
      );

      // 载荷的 opcode 是标识的高字节（0x01/0x02/0x03），宽度大于 1。
      final payloads = walked
          .where((i) => i.width > 1 && i.opcode >= 0x01 && i.opcode <= 0x03);
      expect(
        payloads,
        isNotEmpty,
        reason: '这个夹具里有 sparse-switch-data，必须被识别为载荷而不是 nop',
      );
    });
  });

  group('真实 DEX：调用点与 dexdump 对照', () {
    test('real-netprobe.dex 的 7 个调用点位置与目标都对', () {
      final bytes = _bytes('real-netprobe.dex');
      final sites = <DexCallSite>[];
      final result = DexMethodBodies.walk(
        bytes,
        _structure('real-netprobe.dex', bytes),
        onCallSite: sites.add,
      );

      // dexdump -d 里这个包共 7 条 invoke：
      //   NetProbe.<init> → Object.<init>（1）
      //   NetProbe.open 里 4 条（URL.<init> / URL.openConnection /
      //     HttpURLConnection.setRequestMethod / HttpURLConnection.getInputStream）
      //   Caller.<init> → NetProbe.<init>（1）
      //   Caller.call → NetProbe.helper（1）
      expect(result.callSiteCount, 7);
      expect(result.invokeCustomCount, 0);
      expect(result.desyncedBodies, isEmpty);

      // 下面每条的「偏移 + 目标」都来自 `dexdump -d` 的 invoke 行：
      //   0002: invoke-direct {v0, v2}, Ljava/net/URL;.<init>:(Ljava/lang/String;)V
      //   0005: invoke-virtual {v0}, Ljava/net/URL;.openConnection:()…
      //   000d: invoke-virtual {v2, v0}, Ljava/net/HttpURLConnection;.setRequestMethod:(…)V
      //   0010: invoke-virtual {v2}, Ljava/net/HttpURLConnection;.getInputStream:()…
      final byTarget = {
        for (final site in sites) site.targetDisplayName: site,
      };
      expect(
        byTarget[
                'Ljava/net/HttpURLConnection;.getInputStream()Ljava/io/InputStream;']
            ?.instructionOffset,
        0x10,
      );
      expect(
        byTarget[
                'Ljava/net/HttpURLConnection;.setRequestMethod(Ljava/lang/String;)V']
            ?.instructionOffset,
        0x0d,
      );
      expect(
        byTarget['Ljava/net/URL;.openConnection()Ljava/net/URLConnection;']
            ?.instructionOffset,
        0x05,
      );
      expect(
        byTarget['Ljava/net/URL;.<init>(Ljava/lang/String;)V']
            ?.instructionOffset,
        0x02,
      );
      expect(
        byTarget['Lcom/example/fixture/NetProbe;.helper(I)I']
            ?.instructionOffset,
        0x02,
      );
    });

    test('调用点带上调用者，能回答「在哪个方法里」', () {
      final bytes = _bytes('real-netprobe.dex');
      final sites = <DexCallSite>[];
      DexMethodBodies.walk(
        bytes,
        _structure('real-netprobe.dex', bytes),
        onCallSite: sites.add,
      );

      final http = sites.firstWhere(
        (s) => s.target.classDescriptor == 'Ljava/net/HttpURLConnection;',
      );
      expect(
        http.callerMethodName,
        'open',
        reason: 'HttpURLConnection 的调用发生在 NetProbe.open 里',
      );
      expect(http.callerClassDescriptor, 'Lcom/example/fixture/NetProbe;');
      expect(http.callerDisplayName, contains('open'));
    });
  });

  group('错位必须被发现', () {
    test('宽度偏大导致越过末尾时会被发现', () {
      // const/4(0x12，宽度 1) × 3 —— 3 个单元正好走完
      final ok =
          DexMethodBodies.walkInsns(Uint16List.fromList([0x12, 0x12, 0x12]));
      expect(ok.reachedEnd, isTrue);
      expect(ok.instructionCount, 3);

      // 把**最后一个**单元改成 const/16(0x13，宽度 2)：从 2 跨到 4，
      // 越过末尾 → endIndex 大于长度。
      final overshoot =
          DexMethodBodies.walkInsns(Uint16List.fromList([0x12, 0x12, 0x13]));
      expect(
        overshoot.reachedEnd,
        isFalse,
        reason: '越过末尾说明宽度表错了，不能产出一个看起来正常的结果',
      );
      expect(overshoot.endIndex, greaterThan(overshoot.insnsLength));
    });

    test('宽度偏大但**恰好**重新对齐时，末尾检查抓不到 —— 这是已知的不足', () {
      // 这条测试记录一个**局限**，不是记录一个能力。
      //
      // [0x12, 0x13, 0x12]：走 0（宽 1）→ 1，走 1（宽 2）→ 3，正好等于长度。
      // 于是 `reachedEnd` 为 true —— 但**索引 2 那条指令被整条跳过了**。
      //
      // 也就是说末尾检查是「必要但非充分」：它能抓到越界，抓不到「恰好对齐的
      // 漏读」。真正的主力防线是 `real-opcodes.dex` 上「每条指令的偏移与
      // `dexdump -d` 逐个对照」那条测试 —— 漏读一条会在那里立刻暴露。
      final silentlySkipped =
          DexMethodBodies.walkInsns(Uint16List.fromList([0x12, 0x13, 0x12]));

      expect(silentlySkipped.reachedEnd, isTrue);
      expect(
        silentlySkipped.instructionCount,
        2,
        reason: '只走了 2 条，第 3 个单元被跳过 —— 末尾检查对此无能为力',
      );
    });

    test('载荷长度读不出来时立即停下', () {
      // sparse-switch-payload 标识 + 声明 size=0xFFFF 但没有数据
      final insns = Uint16List.fromList([0x0200, 0xFFFF, 0, 0]);
      final result = DexMethodBodies.walkInsns(insns);

      expect(
        result.reachedEnd,
        isFalse,
        reason: '宁可报不同步，也不猜长度 —— 猜错会产出假指令',
      );
    });

    test('invoke-custom 的操作数被标为 custom，不当成 method_ids 索引', () {
      // invoke-custom(0xfc, 35c) 的布局：op + call_site_idx + 寄存器
      final insns = Uint16List.fromList([0x00fc, 0x0007, 0x0000]);
      final result = DexMethodBodies.walkInsns(insns);

      expect(result.invokes, hasLength(1));
      expect(result.invokes.single.isCustom, isTrue);
      expect(result.invokes.single.operand, 7);
      expect(result.reachedEnd, isTrue);
    });

    test('普通 invoke 的操作数不被标为 custom', () {
      // invoke-virtual(0x6e, 35c)
      final insns = Uint16List.fromList([0x106e, 0x000a, 0x0002]);
      final result = DexMethodBodies.walkInsns(insns);

      expect(result.invokes.single.isCustom, isFalse);
      expect(result.invokes.single.operand, 0x0a);
    });
  });

  group('边界：畸形 DEX 不抛异常', () {
    test('结构不可遍历时返回空结果', () {
      final bytes = _bytes('bad-magic.dex');
      final result =
          DexMethodBodies.walk(bytes, _structure('bad-magic.dex', bytes));

      expect(result.methodBodyCount, 0);
      expect(result.callSiteCount, 0);
    });

    test('各种畸变样本都不炸', () {
      for (final name in const [
        'truncated.dex',
        'method-ids-off-out-of-range.dex',
        'method-ids-size-absurd.dex',
        'string-ids-off-in-header.dex',
        'header-file-size-mismatch.dex',
        'header-size-not-standard.dex',
        'checksum-zeroed.dex',
        'multiple-anomalies.dex',
      ]) {
        final bytes = _bytes(name);
        // 不期待结果，只要求不抛。
        DexMethodBodies.walk(bytes, _structure(name, bytes));
      }
    });

    test('短于头部的字节不炸', () {
      final result = DexMethodBodies.walk(
        Uint8List(10),
        _structure('tiny.dex', Uint8List(10)),
      );
      expect(result.methodBodyCount, 0);
    });
  });
}
