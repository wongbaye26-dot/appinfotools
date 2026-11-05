// 载荷探测：只看有界头部，按魔数认出「像什么」，并按预算如实报截断。
//
// 断言的重点不只是「命中」，还有**不该命中**的地方：扩展名与魔数不符才算
// mismatch（认不出魔数不算）、`nestedArchive`/`executableInAssets` 只在
// `assets/` 下成立、正常文本不会被判成加密。

import 'dart:typed_data';

import 'package:analysis_model/analysis_model.dart';
import 'package:apk_parser/apk_parser.dart';
import 'package:test/test.dart';

/// 造一段以 [head] 开头、后面用可打印字符填充的头部（避免误判高熵）。
Uint8List _head(List<int> head, {int length = 512}) {
  final bytes = Uint8List(length);
  for (var i = 0; i < length; i++) {
    bytes[i] = i < head.length ? head[i] : 0x41 + (i % 26);
  }
  return bytes;
}

const List<int> _dexMagic = [0x64, 0x65, 0x78, 0x0A, 0x30, 0x33, 0x35, 0x00];
const List<int> _zipMagic = [0x50, 0x4B, 0x03, 0x04];
const List<int> _elfMagic = [0x7F, 0x45, 0x4C, 0x46];
const List<int> _machOMagic = [0xCF, 0xFA, 0xED, 0xFE]; // MH_CIGAM_64
const List<int> _shebang = [0x23, 0x21, 0x2F, 0x62, 0x69, 0x6E];

PayloadProbeInput _input(
  String path,
  List<int> head, {
  String? extension,
  int sizeBytes = 0,
}) {
  return PayloadProbeInput(
    path: path,
    headBytes: _head(head),
    declaredExtension: extension,
    sizeBytes: sizeBytes,
  );
}

PayloadProbeResult _scanOne(PayloadProbeInput input) =>
    PayloadProbe.scan([input]);

void main() {
  group('按魔数识别', () {
    test('DEX 魔数：dex\\n0xx，没有可疑信号', () {
      final result = _scanOne(
        _input('classes.dex', _dexMagic, extension: '.dex', sizeBytes: 512),
      );

      expect(result.entriesProbed, 1);
      expect(result.entriesTotal, 1);
      expect(result.complete, isTrue);
      expect(result.signals, isEmpty, reason: '正常 DEX 不该产出载荷信号');
    });

    test('ZIP 系按扩展名细分：zip / apk / jar', () {
      final zip =
          _scanOne(_input('assets/a.zip', _zipMagic, extension: '.zip'));
      expect(zip.signals.single.kind, PayloadKind.zip);

      final apk =
          _scanOne(_input('assets/a.apk', _zipMagic, extension: '.apk'));
      expect(apk.signals.single.kind, PayloadKind.apk);

      final jar =
          _scanOne(_input('assets/a.jar', _zipMagic, extension: '.jar'));
      expect(jar.signals.single.kind, PayloadKind.jar);
    });

    test('ELF / Mach-O / 脚本', () {
      final elf =
          _scanOne(_input('assets/libx.so', _elfMagic, extension: '.so'));
      expect(elf.signals.single.kind, PayloadKind.elf);
      expect(elf.signals.single.code, 'payload.executableInAssets');

      final machO = _scanOne(
        _input('assets/libx.dylib', _machOMagic, extension: '.dylib'),
      );
      expect(machO.signals.single.kind, PayloadKind.machO);
      expect(machO.signals.single.code, 'payload.executableInAssets');

      final script = _scanOne(
        _input('assets/run.sh', _shebang, extension: '.sh'),
      );
      expect(script.signals.single.kind, PayloadKind.script);
      expect(script.signals.single.code, 'payload.executableInAssets');
    });

    test('Mach-O fat 与 Java class 共用 CAFEBABE，靠架构条数区分', () {
      const javaClass = [0xCA, 0xFE, 0xBA, 0xBE, 0, 0, 0, 0];
      const fatBinary = [0xCA, 0xFE, 0xBA, 0xBE, 0, 0, 0, 2];

      final java = _scanOne(_input('assets/x.class', javaClass));
      expect(java.signals, isEmpty, reason: 'minor_version=0 不像 fat 架构数');

      final fat =
          _scanOne(_input('assets/x.bin', fatBinary, extension: '.bin'));
      // `.bin` 没有登记「应该是什么」，所以不产生 mismatch；用资产内可执行
      // 代码信号来观察识别结果。
      expect(fat.signals.single.code, 'payload.executableInAssets');
      expect(fat.signals.single.kind, PayloadKind.machO);
    });
  });

  group('扩展名与魔数不符', () {
    test('.so 里装的是 DEX：报 magicMismatch，参数可读', () {
      final result = _scanOne(
        _input('assets/libfake.so', _dexMagic, extension: '.so'),
      );

      final mismatch =
          result.signals.firstWhere((s) => s.code == 'payload.magicMismatch');
      expect(mismatch.args['declared'], PayloadKind.elf.name);
      expect(mismatch.args['detected'], PayloadKind.dex.name);
      // 伪装成库的 DEX 同时也是「assets 下的可执行内容」。
      expect(
        result.signals.map((s) => s.code),
        contains('payload.executableInAssets'),
      );
    });

    test('.dex 里装的是 ZIP：报 magicMismatch', () {
      final result = _scanOne(
        _input('assets/fake.dex', _zipMagic, extension: '.dex'),
      );

      final mismatch =
          result.signals.firstWhere((s) => s.code == 'payload.magicMismatch');
      expect(mismatch.args['declared'], PayloadKind.dex.name);
      expect(mismatch.args['detected'], PayloadKind.zip.name);
    });

    test('魔数认不出时不报 mismatch（那是「不知道」，不是「不符」）', () {
      // 高熵随机内容没有已知魔数：交给 payload.encrypted 表达，而不是
      // 断言「扩展名与魔数不符」——后者的前提是魔数被认出来了。
      final random = Uint8List(512);
      for (var i = 0; i < random.length; i++) {
        random[i] = i % 256;
      }
      final result = PayloadProbe.scan([
        PayloadProbeInput(
          path: 'assets/blob.so',
          headBytes: random,
          declaredExtension: '.so',
        ),
      ]);

      expect(
        result.signals.map((s) => s.code),
        isNot(contains('payload.magicMismatch')),
      );
      expect(result.signals.map((s) => s.code), contains('payload.encrypted'));
    });
  });

  group('嵌套与 assets 下的可执行内容', () {
    test('assets 下的 ZIP 是嵌套包', () {
      final result =
          _scanOne(_input('assets/payload.zip', _zipMagic, extension: '.zip'));

      expect(
        result.signals.map((s) => s.code),
        contains('payload.nestedArchive'),
      );
    });

    test('包根的 ZIP 不算嵌套包（那是正常结构）', () {
      final result =
          _scanOne(_input('payload.zip', _zipMagic, extension: '.zip'));

      expect(result.signals, isEmpty);
    });

    test('包根的 DEX 不是 assets 里的可执行内容', () {
      final result = _scanOne(
        _input('classes.dex', _dexMagic, extension: '.dex'),
      );

      expect(result.signals, isEmpty);
    });
  });

  group('高熵 / 加密', () {
    test('均匀随机头部：熵 8.0、可打印少 ⇒ payload.encrypted', () {
      final random = Uint8List(512);
      for (var i = 0; i < random.length; i++) {
        random[i] = i % 256;
      }
      final result = PayloadProbe.scan([
        PayloadProbeInput(path: 'assets/secret.bin', headBytes: random),
      ]);

      final encrypted =
          result.signals.firstWhere((s) => s.code == 'payload.encrypted');
      expect(encrypted.entropy, closeTo(8.0, 0.001));
      expect(encrypted.entropy,
          greaterThanOrEqualTo(PayloadProbe.encryptedEntropyThreshold));
      expect(encrypted.args['headBytes'], 512);
    });

    test('纯文本不判加密（熵低）', () {
      final text = Uint8List.fromList(List.filled(512, 0x41));
      final result = PayloadProbe.scan([
        PayloadProbeInput(path: 'assets/readme.txt', headBytes: text),
      ]);

      expect(result.signals, isEmpty);
      expect(result.entriesProbed, 1);
    });

    test('样本太短不算熵（上限由样本量决定）', () {
      final tiny = Uint8List.fromList([0, 1, 2, 3, 4, 5, 6, 7]);
      final result = PayloadProbe.scan([
        PayloadProbeInput(path: 'assets/tiny.bin', headBytes: tiny),
      ]);

      expect(
        result.signals.map((s) => s.code),
        isNot(contains('payload.encrypted')),
        reason: '8 字节样本最多 3 bit/byte，按 7.5 判会永远不命中',
      );
    });
  });

  group('预算', () {
    test('条目数超限：complete=false + entries_truncated', () {
      final result = PayloadProbe.scan(
        [
          _input('assets/a.bin', _zipMagic),
          _input('assets/b.bin', _zipMagic),
        ],
        maxEntries: 1,
      );

      expect(result.entriesProbed, 1);
      expect(result.entriesTotal, 2);
      expect(result.complete, isFalse);
      expect(result.noteCodes, contains(PayloadProbe.entriesTruncatedCode));
    });

    test('字节预算超限：不读半个头部，complete=false + bytes_truncated', () {
      final result = PayloadProbe.scan(
        [
          for (var i = 0; i < 4; i++)
            PayloadProbeInput(
              path: 'assets/$i.bin',
              headBytes: Uint8List.fromList(List.filled(8, 0x41)),
              sizeBytes: 8,
            ),
        ],
        maxTotalBytes: 10,
      );

      expect(result.entriesProbed, 1);
      expect(result.complete, isFalse);
      expect(result.noteCodes, contains(PayloadProbe.bytesTruncatedCode));
    });

    test('单条头部超过 maxHeadBytes 时按上限截断', () {
      final uniform = Uint8List(512);
      for (var i = 0; i < uniform.length; i++) {
        uniform[i] = i % 256;
      }
      final result = PayloadProbe.scan(
        [PayloadProbeInput(path: 'assets/x.bin', headBytes: uniform)],
        maxHeadBytes: 8,
      );

      // 只看 8 字节：最多 3 bit/byte，不可能达到加密阈值。
      expect(result.entriesProbed, 1);
      expect(result.signals, isEmpty);
    });

    test('空输入是完整结果，不编造信号', () {
      final result = PayloadProbe.scan(const []);

      expect(result.entriesTotal, 0);
      expect(result.entriesProbed, 0);
      expect(result.complete, isTrue);
      expect(result.noteCodes, isEmpty);
      expect(result.isEmpty, isTrue);
    });

    test('头部读不出来时记 note，且不计入已探测', () {
      final result = PayloadProbe.scan([
        PayloadProbeInput(
          path: 'assets/unreadable.bin',
          headBytes: Uint8List(0),
          sizeBytes: 4096,
        ),
      ]);

      expect(result.entriesProbed, 0);
      expect(result.entriesTotal, 1);
      expect(result.noteCodes, contains(PayloadProbe.headUnavailableCode));
      expect(result.signals, isEmpty);
      // 「没看到内容」不是阴性结论，所以不把 complete 写成 false 也不写成
      // 「探测过」——note 是唯一诚实的表达。
      expect(result.complete, isTrue);
    });
  });
}
