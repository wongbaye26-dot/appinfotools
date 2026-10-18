import 'dart:typed_data';

import 'package:apk_parser/apk_parser.dart';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

/// 标准 DEX 魔数：`dex\n035\0`。
final Uint8List _dexMagic =
    Uint8List.fromList([0x64, 0x65, 0x78, 0x0A, 0x30, 0x33, 0x35, 0x00]);

/// 构造归档条目。
///
/// [declaredSize] 可以大于实际字节数 —— 用于模拟「体积可观」的条目，
/// 不必真的分配那么多内存。
ArchiveFile _file(String name, List<int> bytes, {int? declaredSize}) =>
    ArchiveFile(name, declaredSize ?? bytes.length, bytes);

bool _has(List<HardeningObservation> obs, HardeningSignal signal) =>
    obs.any((o) => o.signal == signal);

HardeningObservation _find(List<HardeningObservation> obs, HardeningSignal s) =>
    obs.firstWhere((o) => o.signal == s);

void main() {
  group('HardeningScanner — 内容是 DEX 的「原生库」', () {
    // 这是一种具体的隐藏手法：只扫 `classes*.dex` 的工具完全看不到这段代码，
    // 运行时用 `DexClassLoader` 从 `lib/` 目录直接加载它。
    //
    // **实测来源**：`抖音-v40.7.0` 的 `lib/arm64-v8a/libsm_impl.so`
    // （162,912 字节，头部 `dex\n035`）。文件名完全合规，只看名字永远发现不了。

    test('lib/<abi>/ 下的 .so 内容是 DEX → 命中', () {
      final archive = Archive()
        ..addFile(_file('classes.dex', _dexMagic))
        ..addFile(_file('lib/arm64-v8a/libsm_impl.so', _dexMagic));

      final obs = HardeningScanner.scan(archive);

      expect(_has(obs, HardeningSignal.dexDisguisedAsNativeLibrary), isTrue);
      expect(
        _find(obs, HardeningSignal.dexDisguisedAsNativeLibrary).evidence,
        contains('lib/arm64-v8a/libsm_impl.so'),
      );
    });

    test('正常的 ELF 库不命中', () {
      // ELF 魔数 \x7fELF
      final elfMagic = [0x7F, 0x45, 0x4C, 0x46, 2, 1, 1, 0];
      final archive = Archive()
        ..addFile(_file('classes.dex', _dexMagic))
        ..addFile(_file('lib/arm64-v8a/libnative.so', elfMagic));

      final obs = HardeningScanner.scan(archive);

      expect(_has(obs, HardeningSignal.dexDisguisedAsNativeLibrary), isFalse);
    });

    test('与「DEX 头不标准」是两件事，不能互相顶替', () {
      // 文件名像 DEX、内容不是 DEX → dexHeaderNotStandard
      final archive = Archive()
        ..addFile(_file('classes.dex', _dexMagic))
        ..addFile(_file('classes2.dex', List.filled(16, 0x9d)));

      final obs = HardeningScanner.scan(archive);

      expect(_has(obs, HardeningSignal.dexHeaderNotStandard), isTrue);
      expect(_has(obs, HardeningSignal.dexDisguisedAsNativeLibrary), isFalse,
          reason: '这条是「文件名像 DEX 但内容不是」，不该命中反向的那条');
    });
  });

  group('HardeningScanner — DEX 结构', () {
    test('标准单 DEX 结构不报 DEX 相关线索', () {
      final archive = Archive()
        ..addFile(_file('classes.dex', _dexMagic, declaredSize: 200 * 1024))
        ..addFile(_file('resources.arsc', List.filled(4096, 0)));

      final obs = HardeningScanner.scan(archive);

      expect(_has(obs, HardeningSignal.missingPrimaryDex), isFalse);
      expect(_has(obs, HardeningSignal.multipleDexFiles), isFalse);
      expect(_has(obs, HardeningSignal.dexHeaderNotStandard), isFalse);
    });

    test('没有 classes.dex -> missingPrimaryDex', () {
      final archive = Archive()..addFile(_file('resources.arsc', [1, 2, 3]));

      final obs = HardeningScanner.scan(archive);

      expect(_has(obs, HardeningSignal.missingPrimaryDex), isTrue);
    });

    test('多个 classesN.dex -> multipleDexFiles，证据里列出条目名', () {
      final archive = Archive()
        ..addFile(_file('classes.dex', _dexMagic))
        ..addFile(_file('classes2.dex', _dexMagic))
        ..addFile(_file('classes3.dex', _dexMagic));

      final obs = HardeningScanner.scan(archive);
      final hint = _find(obs, HardeningSignal.multipleDexFiles);

      expect(hint.evidence, contains('classes.dex'));
      expect(hint.evidence, contains('classes3.dex'));
      expect(hint.evidence, contains('3'));
    });

    test('DEX 头部非标准 -> dexHeaderNotStandard，证据含实际字节', () {
      final encrypted =
          Uint8List.fromList([0x9D, 0x01, 0x42, 0xFF, 0x00, 0x00, 0x00, 0x00]);
      final archive = Archive()..addFile(_file('classes.dex', encrypted));

      final obs = HardeningScanner.scan(archive);
      final hint = _find(obs, HardeningSignal.dexHeaderNotStandard);

      expect(hint.evidence, contains('classes.dex'));
      expect(hint.evidence, contains('0x9d'));
      expect(hint.evidence, contains('dex'));
    });

    test('条目太短无法读取头部时，也算 dexHeaderNotStandard', () {
      final archive = Archive()..addFile(_file('classes.dex', [0x64, 0x65]));

      final obs = HardeningScanner.scan(archive);

      expect(_has(obs, HardeningSignal.dexHeaderNotStandard), isTrue);
    });
  });

  group('HardeningScanner — 目录结构', () {
    test('lib/<abi>/ 下不符合 lib*.so 约定 -> unusualNativeLibraryName', () {
      final archive = Archive()
        ..addFile(_file('classes.dex', _dexMagic))
        ..addFile(_file('lib/arm64-v8a/shell.so', [0, 1]))
        ..addFile(_file('lib/arm64-v8a/libnormal.so', [0, 1]));

      final obs = HardeningScanner.scan(archive);

      expect(_has(obs, HardeningSignal.unusualNativeLibraryName), isTrue);
      final evidence =
          _find(obs, HardeningSignal.unusualNativeLibraryName).evidence;
      expect(evidence, contains('shell.so'));
      expect(evidence, isNot(contains('libnormal.so')));
    });

    test('lib 下的正常命名不会被误报', () {
      final archive = Archive()
        ..addFile(_file('classes.dex', _dexMagic))
        ..addFile(_file('lib/arm64-v8a/libfoo.so', [0, 1]));

      final obs = HardeningScanner.scan(archive);

      expect(_has(obs, HardeningSignal.unusualNativeLibraryName), isFalse);
    });

    test('assets/ 下出现代码类文件 -> executableInAssets', () {
      final archive = Archive()
        ..addFile(_file('classes.dex', _dexMagic))
        ..addFile(_file('assets/payload.jar', [0, 1]));

      final obs = HardeningScanner.scan(archive);

      expect(_has(obs, HardeningSignal.executableInAssets), isTrue);
      expect(_find(obs, HardeningSignal.executableInAssets).evidence,
          contains('assets/payload.jar'));
    });

    test('assets/ 下的普通图片不算', () {
      final archive = Archive()
        ..addFile(_file('classes.dex', _dexMagic))
        ..addFile(_file('assets/logo.png', [0, 1]));

      final obs = HardeningScanner.scan(archive);

      expect(_has(obs, HardeningSignal.executableInAssets), isFalse);
    });
  });

  group('HardeningScanner — 资源表', () {
    test('DEX 有体量但 resources.arsc 缺失 -> resourceTableAnomaly', () {
      final archive = Archive()
        ..addFile(_file('classes.dex', _dexMagic, declaredSize: 200 * 1024));

      final obs = HardeningScanner.scan(archive);

      expect(_has(obs, HardeningSignal.resourceTableAnomaly), isTrue);
    });

    test('resources.arsc 过小 -> resourceTableAnomaly', () {
      final archive = Archive()
        ..addFile(_file('classes.dex', _dexMagic, declaredSize: 200 * 1024))
        ..addFile(_file('resources.arsc', List.filled(16, 0)));

      final obs = HardeningScanner.scan(archive);

      expect(_has(obs, HardeningSignal.resourceTableAnomaly), isTrue);
      expect(_find(obs, HardeningSignal.resourceTableAnomaly).evidence,
          contains('16'));
    });

    test('DEX 很小且没有资源表时不报 —— 避免玩具应用误报', () {
      final archive = Archive()
        ..addFile(_file('classes.dex', _dexMagic, declaredSize: 1024));

      final obs = HardeningScanner.scan(archive);

      expect(_has(obs, HardeningSignal.resourceTableAnomaly), isFalse);
    });
  });

  group('HardeningScanner — 契约', () {
    test('空归档不抛异常，只报 missingPrimaryDex', () {
      final obs = HardeningScanner.scan(Archive());

      expect(obs.map((o) => o.signal).toList(),
          [HardeningSignal.missingPrimaryDex]);
    });

    test('每条线索都带非空证据（「可解释」的契约）', () {
      final archive = Archive()
        ..addFile(_file('lib/armeabi/odd.so', [0]))
        ..addFile(_file('assets/x.dex', [0]))
        ..addFile(_file('classes.dex', [0x9D, 0x01]));

      final obs = HardeningScanner.scan(archive);

      expect(obs, isNotEmpty);
      for (final o in obs) {
        expect(o.evidence.trim(), isNotEmpty, reason: '${o.signal} 缺证据');
      }
    });

    test('不含任何厂商判定：线索种类是固定的结构事实集合', () {
      // 这条断言的意义在于防止后来者往枚举里加「com.xxx.packer」这类值 ——
      // 规范 4.2 明确禁止据单一特征判定厂商。
      // 数量变化时**必须**回来确认新增的仍是一个结构事实，而不是厂商名。
      //
      // 已确认：`manifestLayoutAnomaly` 描述的是「AXML 的二进制布局不符合
      // 标准」（attributeStart/attributeSize 被放大、chunk 类型越界），
      // 是一个可复现的结构事实，与具体是哪家加固器无关。
      //
      // 已确认：`dexDisguisedAsNativeLibrary` 描述的是「lib/<abi>/xxx.so 的
      // 内容是 DEX 字节码」—— 一个可复现的内容事实（读前 8 字节比对
      // `dex\n0xx` 魔数），同样与厂商无关。实测来源：抖音的
      // `lib/arm64-v8a/libsm_impl.so`。
      expect(HardeningSignal.values, hasLength(9));
      final names = HardeningSignal.values.map((s) => s.name).join(' ');
      for (final vendor in [
        'jiagu',
        '360',
        'tencent',
        'ali',
        'bangcle',
        'legu',
        'naga'
      ]) {
        expect(names.toLowerCase(), isNot(contains(vendor)));
      }
    });
  });

  group('HardeningScanner — 路径形状的诱饵条目', () {
    test('正常 APK 不触发该线索', () {
      final archive = Archive()
        ..addFile(_file('classes.dex', _dexMagic))
        ..addFile(_file('AndroidManifest.xml', List.filled(64, 0)))
        ..addFile(_file('resources.arsc', List.filled(4096, 0)));

      expect(
          _has(HardeningScanner.scan(archive),
              HardeningSignal.decoyArchiveEntries),
          isFalse);
    });

    test('文件被当作目录前缀时触发，并给出条数与示例', () {
      // 真实样本里的形态：`AndroidManifest.xml` 是文件，却又被用作目录。
      final archive = Archive()
        ..addFile(_file('classes.dex', _dexMagic))
        ..addFile(_file('AndroidManifest.xml', List.filled(64, 0)))
        ..addFile(_file('AndroidManifest.xml/..xml', List.filled(8, 0)))
        ..addFile(_file('AndroidManifest.xml/ .xml', List.filled(8, 0)))
        ..addFile(_file('classes.dex/xxx.xml', List.filled(8, 0)));

      final decoy = _find(
          HardeningScanner.scan(archive), HardeningSignal.decoyArchiveEntries);

      // 证据里必须能看出「有多少条」以及「长什么样」——
      // 只说「可能被加固」没有排查价值。
      expect(decoy.evidence, contains('3 entries'));
      expect(decoy.evidence, contains('AndroidManifest.xml/..xml'));
      expect(decoy.evidence, contains('directory prefix'));
    });

    test('名字里没有点点、但同样是诱饵的条目也被识别', () {
      // 按「名字含不含 `..`」判会漏掉这一类。
      final archive = Archive()
        ..addFile(_file('classes.dex', _dexMagic))
        ..addFile(_file('resources.arsc', List.filled(4096, 0)))
        ..addFile(_file('resources.arsc/ .xml', List.filled(8, 0)));

      expect(
          _has(HardeningScanner.scan(archive),
              HardeningSignal.decoyArchiveEntries),
          isTrue);
    });

    test('反斜杠分隔的路径同样被识别', () {
      final archive = Archive()
        ..addFile(_file('classes.dex', _dexMagic))
        // 反斜杠在 ZIP 里是合法的名字字符，但现实中有包把它当分隔符用。
        ..addFile(_file('AndroidManifest.xml', List.filled(64, 0)))
        ..addFile(_file(r'AndroidManifest.xml\..xml', List.filled(8, 0)));

      expect(
          _has(HardeningScanner.scan(archive),
              HardeningSignal.decoyArchiveEntries),
          isTrue);
    });

    test('名字里只是含两个点（不是目录前缀）不算', () {
      final archive = Archive()
        ..addFile(_file('classes.dex', _dexMagic))
        ..addFile(_file('res/values/..hidden.xml', List.filled(8, 0)))
        ..addFile(_file('assets/a..b.png', List.filled(8, 0)));

      expect(
          _has(HardeningScanner.scan(archive),
              HardeningSignal.decoyArchiveEntries),
          isFalse);
    });

    test('目录条目与文件条目同名不算诱饵', () {
      // 正常的 ZIP 会显式带目录条目：`res/` 是目录，`res/a.png` 是文件。
      final archive = Archive()
        ..addFile(_file('classes.dex', _dexMagic))
        ..addFile(ArchiveFile('res/', 0, <int>[])..isFile = false)
        ..addFile(_file('res/a.png', List.filled(8, 0)));

      expect(
          _has(HardeningScanner.scan(archive),
              HardeningSignal.decoyArchiveEntries),
          isFalse);
    });
  });
}
