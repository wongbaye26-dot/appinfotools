// IPA 载荷探测（`IosPayloadProbe`）。
//
// 头部字节全部在这里**手工构造**（不是从真实样本裁的），因为要钉的是判据
// 本身：魔数识别、魔数与扩展名冲突、assets 下的嵌套归档/可执行内容、
// 高熵、预算截断。真实样本只用于加载链的 Mach-O 解析测试。
//
// 判据与 `apk_parser` 的 `PayloadProbe` 同一套（稳定 code、阈值、参数名），
// 这样规则层不用为两端各写一遍；差异只在 `assets/` 的定位方式（IPA 里它在
// bundle 内，是路径段而不是归档前缀）。
import 'dart:typed_data';

import 'package:analysis_model/analysis_model.dart';
import 'package:ipa_parser/ipa_parser.dart';
import 'package:test/test.dart';

/// 以 [prefix] 开头、总长 [size] 的头部（其余填 0）。
Uint8List _head(List<int> prefix, {int size = 256}) {
  final bytes = Uint8List(size);
  final length = prefix.length < size ? prefix.length : size;
  bytes.setRange(0, length, prefix);
  return bytes;
}

/// 构造一个 ZIP 本地文件头，首个条目名为 [firstEntry]。
Uint8List _zipHead(String firstEntry, {int size = 256}) {
  final name = firstEntry.codeUnits;
  final bytes = Uint8List(size);
  bytes.setRange(0, 4, const [0x50, 0x4B, 0x03, 0x04]);
  // 版本/标志/方法/时间/CRC/压缩大小/未压缩大小全部留 0：判据只看名字。
  bytes[26] = name.length & 0xFF;
  bytes[27] = (name.length >> 8) & 0xFF;
  bytes.setRange(30, 30 + name.length, name);
  return bytes;
}

/// 确定性伪随机字节（固定 LCG 种子），用来测高熵。
Uint8List _pseudoRandom(int size) {
  final bytes = Uint8List(size);
  var state = 0x12345678;
  for (var i = 0; i < size; i++) {
    state = (state * 1664525 + 1013904223) & 0xFFFFFFFF;
    bytes[i] = (state >> 16) & 0xFF;
  }
  return bytes;
}

PayloadProbeInput _input(
  String path,
  Uint8List head, {
  String? extension,
  int? sizeBytes,
}) =>
    PayloadProbeInput(
      path: path,
      headBytes: head,
      sizeBytes: sizeBytes ?? head.length,
      declaredExtension: extension,
    );

List<String> _codes(PayloadProbeResult result) =>
    [for (final signal in result.signals) signal.code];

const List<int> _dexMagic = [0x64, 0x65, 0x78, 0x0A, 0x30, 0x33, 0x35, 0x00];
const List<int> _elfMagic = [0x7F, 0x45, 0x4C, 0x46];
const List<int> _machoMagic64 = [0xFE, 0xED, 0xFA, 0xCF];
const List<int> _scriptHead = [
  0x23, 0x21, 0x2F, 0x75, 0x73, 0x72, 0x2F, 0x62, // #!/usr/b
  0x69, 0x6E, 0x2F, 0x65, 0x6E, 0x76, 0x20, 0x6E, // in/env n
  0x6F, 0x64, 0x65, 0x0A, 0x63, 0x6F, 0x6E, 0x73, // ode\ncons
];

void main() {
  group('按魔数定类型', () {
    test('assets 里的 DEX：dex + executableInAssets（iOS 不会执行它）', () {
      final result = IosPayloadProbe.scan([
        _input('Payload/Demo.app/assets/payload.dex', _head(_dexMagic)),
      ]);
      expect(result.signals.single.kind, PayloadKind.dex);
      expect(result.signals.single.code, 'payload.executableInAssets');
      // 熵随每个信号一起给出（弱信号，不单独判级）。
      expect(result.signals.single.entropy, isNotNull);
      expect(result.entriesProbed, 1);
      expect(result.entriesTotal, 1);
      expect(result.complete, isTrue);
    });

    test('assets 里的 ZIP：nestedArchive；声明 .zip 不算 magicMismatch', () {
      final result = IosPayloadProbe.scan([
        _input(
          'Payload/Demo.app/assets/bundle.zip',
          _zipHead('res/data.bin'),
          extension: 'zip',
        ),
      ]);
      expect(result.signals.single.kind, PayloadKind.zip);
      expect(result.signals.single.code, 'payload.nestedArchive');
      expect(_codes(result), isNot(contains('payload.magicMismatch')));
    });

    test('APK：首条目 AndroidManifest.xml → apk + 嵌套归档', () {
      final result = IosPayloadProbe.scan([
        _input(
          'Payload/Demo.app/assets/dropper.apk',
          _zipHead('AndroidManifest.xml'),
          extension: 'apk',
        ),
      ]);
      final codes = _codes(result);
      expect(result.signals.first.kind, PayloadKind.apk);
      expect(codes, contains('payload.nestedArchive'));
      expect(codes, isNot(contains('payload.magicMismatch')));
      // 与 Android 同口径：APK 不算 executableInAssets（它由 nestedArchive
      // 表达），规则层不会在两端得到不同判定。
      expect(codes, isNot(contains('payload.executableInAssets')));
    });

    test('JAR：首条目 META-INF/ → jar', () {
      final result = IosPayloadProbe.scan([
        _input(
          'Payload/Demo.app/assets/lib.jar',
          _zipHead('META-INF/MANIFEST.MF'),
          extension: 'jar',
        ),
      ]);
      expect(result.signals.first.kind, PayloadKind.jar);
      expect(_codes(result), contains('payload.nestedArchive'));
    });

    test('ELF：assets 下的 .so → elf + executableInAssets', () {
      final result = IosPayloadProbe.scan([
        _input(
          'Payload/Demo.app/assets/libpayload.so',
          _head(_elfMagic),
          extension: 'so',
        ),
      ]);
      final codes = _codes(result);
      expect(result.signals.first.kind, PayloadKind.elf);
      expect(codes, contains('payload.executableInAssets'));
      expect(codes, isNot(contains('payload.magicMismatch')));
    });

    test('Mach-O：无扩展名也按魔数认出来', () {
      final result = IosPayloadProbe.scan([
        _input('Payload/Demo.app/assets/dylib_blob', _head(_machoMagic64)),
      ]);
      expect(result.signals.first.kind, PayloadKind.machO);
      expect(_codes(result), contains('payload.executableInAssets'));
    });

    test('脚本：shebang 认脚本，assets 下记可执行内容', () {
      final result = IosPayloadProbe.scan([
        _input(
          'Payload/Demo.app/assets/main.js',
          _head(_scriptHead),
          extension: 'js',
        ),
      ]);
      final codes = _codes(result);
      expect(result.signals.first.kind, PayloadKind.script);
      expect(codes, contains('payload.executableInAssets'));
      expect(codes, isNot(contains('payload.magicMismatch')));
    });

    test('没有 shebang 的 .js：文本粗判为脚本；二进制内容不算', () {
      final text = Uint8List.fromList('function load(){return 1}\n'.codeUnits);
      final binary = _head(const [0x00, 0x01, 0x02, 0x03]);
      final result = IosPayloadProbe.scan([
        _input('Payload/Demo.app/assets/a.js', text, extension: 'js'),
        _input('Payload/Demo.app/assets/b.js', binary, extension: 'js'),
      ]);
      expect(result.signals, hasLength(1));
      expect(result.signals.single.path, 'Payload/Demo.app/assets/a.js');
      expect(result.signals.single.kind, PayloadKind.script);
      expect(result.entriesProbed, 2);
    });

    test('不在 assets 下的 ZIP 不标 nestedArchive（与 Android 同口径）', () {
      final result = IosPayloadProbe.scan([
        _input(
          'Payload/Demo.app/Resources/res.zip',
          _zipHead('res/data.bin'),
          extension: 'zip',
        ),
      ]);
      expect(_codes(result), isNot(contains('payload.nestedArchive')));
    });
  });

  group('魔数与声明扩展名冲突', () {
    test('.so 实为 DEX → magicMismatch（declared/detected），不标 assets 代码', () {
      final result = IosPayloadProbe.scan([
        _input(
          'Payload/Demo.app/Frameworks/libfoo.so',
          _head(_dexMagic),
          extension: 'so',
        ),
      ]);
      final signal = result.signals.single;
      expect(signal.code, 'payload.magicMismatch');
      expect(signal.kind, PayloadKind.dex);
      expect(signal.args['declared'], 'elf');
      expect(signal.args['detected'], 'dex');
      expect(_codes(result), isNot(contains('payload.executableInAssets')));
    });

    test('assets 里的 .dylib 实为 ZIP → mismatch + 嵌套归档', () {
      final result = IosPayloadProbe.scan([
        _input(
          'Payload/Demo.app/assets/libbar.dylib',
          _zipHead('payload/dex'),
          extension: 'dylib',
        ),
      ]);
      final codes = _codes(result);
      expect(codes, contains('payload.magicMismatch'));
      expect(codes, contains('payload.nestedArchive'));
      expect(result.signals.first.kind, PayloadKind.zip);
      expect(result.signals.first.args['declared'], 'machO');
    });

    test('.bin 没有可靠预期 → 不判 mismatch（只报类型）', () {
      final result = IosPayloadProbe.scan([
        _input(
          'Payload/Demo.app/assets/blob.bin',
          _head(_elfMagic),
          extension: 'bin',
        ),
      ]);
      expect(_codes(result), isNot(contains('payload.magicMismatch')));
      expect(result.signals.first.kind, PayloadKind.elf);
    });

    test('.js 实为 DEX → mismatch', () {
      final result = IosPayloadProbe.scan([
        _input(
          'Payload/Demo.app/assets/no.js',
          _head(_dexMagic),
          extension: 'js',
        ),
      ]);
      final codes = _codes(result);
      expect(codes, contains('payload.magicMismatch'));
      expect(result.signals.first.args['declared'], 'script');
    });
  });

  group('熵 / 看不清', () {
    test('高熵且可打印字符少 → payload.encrypted（附熵值与可打印占比）', () {
      final result = IosPayloadProbe.scan([
        _input(
          'Payload/Demo.app/assets/blob',
          _pseudoRandom(4096),
          sizeBytes: 4096,
        ),
      ]);
      final signal = result.signals.single;
      expect(signal.kind, PayloadKind.unknown);
      expect(signal.code, 'payload.encrypted');
      expect(signal.entropy, isNotNull);
      expect(
        signal.entropy! >= IosPayloadProbe.encryptedEntropyThreshold,
        isTrue,
      );
      expect(signal.args['headBytes'], 4096);
      expect(
        (signal.args['printableRatio']! as double) <=
            IosPayloadProbe.encryptedPrintableRatio,
        isTrue,
      );
    });

    test('低熵不报 encrypted', () {
      final result = IosPayloadProbe.scan([
        _input('Payload/Demo.app/assets/zeros', _head(const [])),
      ]);
      expect(_codes(result), isNot(contains('payload.encrypted')));
    });

    test('样本短于 minBytesForEntropy 时不判熵（熵上限由样本量决定）', () {
      final result = IosPayloadProbe.scan([
        _input(
          'Payload/Demo.app/assets/small',
          _pseudoRandom(128),
          sizeBytes: 128,
        ),
      ]);
      expect(_codes(result), isNot(contains('payload.encrypted')));
    });
  });

  group('预算截断', () {
    test('条目超 maxEntries → complete=false + payload.entries_truncated', () {
      final result = IosPayloadProbe.scan(
        [
          _input('a.so', _head(_elfMagic), extension: 'so'),
          _input('b.so', _head(_elfMagic), extension: 'so'),
          _input('c.so', _head(_elfMagic), extension: 'so'),
        ],
        maxEntries: 1,
      );
      expect(result.entriesProbed, 1);
      expect(result.entriesTotal, 3);
      expect(result.complete, isFalse);
      expect(result.noteCodes, contains(IosPayloadProbe.entriesTruncatedCode));
    });

    test('maxEntries=0 → 一条都不探测', () {
      final result = IosPayloadProbe.scan(
        [_input('a.so', _head(_elfMagic), extension: 'so')],
        maxEntries: 0,
      );
      expect(result.entriesProbed, 0);
      expect(result.signals, isEmpty);
      expect(result.complete, isFalse);
      expect(result.noteCodes, contains(IosPayloadProbe.entriesTruncatedCode));
    });

    test('合计字节超 maxTotalBytes → 后续条目不读', () {
      final result = IosPayloadProbe.scan(
        [
          _input('a.bin', _head(const [], size: 4096)),
          _input('b.bin', _head(const [], size: 4096)),
        ],
        maxTotalBytes: 4096,
      );
      expect(result.entriesProbed, 1);
      expect(result.entriesTotal, 2);
      expect(result.complete, isFalse);
      expect(result.noteCodes, contains(IosPayloadProbe.bytesTruncatedCode));
    });

    test('maxHeadBytes=0 → 预算不允许看字节，记 bytes_truncated', () {
      final result = IosPayloadProbe.scan(
        [_input('Payload/Demo.app/assets/payload.dex', _head(_dexMagic))],
        maxHeadBytes: 0,
      );
      expect(result.entriesProbed, 0);
      expect(result.complete, isFalse);
      expect(result.noteCodes, contains(IosPayloadProbe.bytesTruncatedCode));
    });

    test('单条头部超过 maxHeadBytes → 只看前一段（预算即分析窗口）', () {
      final result = IosPayloadProbe.scan(
        [
          _input(
            'Payload/Demo.app/assets/payload.dex',
            _head(_dexMagic, size: 1024),
          ),
        ],
        maxHeadBytes: 512,
      );
      expect(result.entriesProbed, 1);
      expect(result.signals.single.kind, PayloadKind.dex);
      // 与 Android 同口径：调用方应只给 maxHeadBytes 以内的头部，
      // 多给的部分被截掉不记成「预算截断」。
      expect(result.noteCodes, isEmpty);
      expect(result.complete, isTrue);
    });

    test('头部读不到 → payload.head_unavailable，且不算探测过', () {
      final result = IosPayloadProbe.scan([
        _input('Payload/Demo.app/assets/secret', Uint8List(0), sizeBytes: 900),
      ]);
      expect(result.entriesProbed, 0);
      expect(result.entriesTotal, 1);
      expect(result.signals, isEmpty);
      expect(result.noteCodes, [IosPayloadProbe.headUnavailableCode]);
      // 读不到头部不是预算截断：complete 只表达「预算没顶到上限」。
      expect(result.complete, isTrue);
    });
  });

  test('空输入：空结果 + complete=true', () {
    final result = IosPayloadProbe.scan(const []);
    expect(result.signals, isEmpty);
    expect(result.entriesTotal, 0);
    expect(result.entriesProbed, 0);
    expect(result.complete, isTrue);
    expect(result.noteCodes, isEmpty);
  });
}
