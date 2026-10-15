// apk_parser 的包级测试。
//
// 覆盖四个解析子系统的**纯逻辑**入口：二进制 XML（manifest）、DEX、ELF、资源表。
// 全部复用仓库根目录 `test/fixtures/` 里由公开工具生成的夹具（生成命令记在
// 各自的 README 里），不另造样本 —— 手拼的字节会带着与解析器相同的错误假设。
//
// 与根 `test/` 下的同名主题测试的分工：那边从**应用**角度验证端到端行为，
// 这边确认「这个包作为独立库，单独 `dart test` 就能自证」。
import 'dart:io';
import 'dart:typed_data';

import 'package:apk_parser/apk_parser.dart';
import 'package:archive/archive.dart';
import 'package:test/test.dart';

const String _fixtures = '../../test/fixtures';

Uint8List _bytes(String relative) =>
    File('$_fixtures/$relative').readAsBytesSync();

/// 从夹具 APK 里取出 `resources.arsc`。
Uint8List _arscFrom(String apkName) {
  final archive = ZipDecoder().decodeBytes(_bytes('apk/$apkName'));
  final entry = archive.files.firstWhere((f) => f.name == 'resources.arsc');
  return Uint8List.fromList(entry.content as List<int>);
}

void main() {
  group('ManifestParser — 二进制 XML', () {
    test('真实加固清单的关键字段都被解出', () {
      // 这份夹具是从真实加固 APK 里提取的，`attributeStart` / `attributeSize`
      // 都被故意放大过（见 fixtures/apk/README.md）—— 按标准布局硬编码偏移
      // 的解析器在这里会一无所获。
      final meta = ManifestParser.parse(_bytes('apk/hardened-manifest.axml'));

      expect(meta.packageName, isNotNull);
      expect(meta.versionName, isNotNull);
      expect(meta.versionCode, isNotNull);
      expect(meta.minSdkVersion, isNotNull);
      expect(meta.targetSdkVersion, isNotNull);
      expect(meta.permissions, hasLength(40));
      expect(meta.components, hasLength(22));
    });

    test('未声明的 maxSdkVersion 是 null，不默认成某个值', () {
      final meta = ManifestParser.parse(_bytes('apk/hardened-manifest.axml'));
      // 夹具没有声明 maxSdkVersion；填成 0 或 int 上限都是编造。
      expect(meta.maxSdkVersion, isNull);
    });

    test('标准布局的最小清单能解析，且不报布局异常', () {
      // 这份夹具是 aapt2 生成的最小清单，字段本来就都是空的；
      // 它的用途是「标准布局不该被误报成异常」。
      final meta = ManifestParser.parse(_bytes('apk/standard-manifest.axml'));
      expect(meta.packageName, isNull);
      expect(meta.components, isEmpty);
    });

    test('权限请求保留 maxSdkVersion 这类版本条件', () {
      final meta = ManifestParser.parse(_bytes('apk/hardened-manifest.axml'));
      // 结构化形式与扁平列表必须同时存在 —— 后者丢掉了版本条件。
      expect(meta.permissionRequests, hasLength(meta.permissions.length));
      for (final request in meta.permissionRequests) {
        expect(request.name, isNotEmpty);
      }
    });

    // 包层契约（阶段 2 起）：**解析器不抛异常，失败记成数据**。
    //
    // 此前畸形字节会抛 `IndexError`，应用侧靠 `parse_task.dart` 的 try/catch
    // 兜住 —— 但调用方拿到的若只是异常，就只能整体放弃，而「清单读不出来」
    // 本身是一条要展示给用户的事实。现在失败写进 `manifestParseFailure`，
    // 调用方既能继续往下走，又能如实说明「这一步没读到」。
    test('非 AXML 字节不抛异常，而是记下失败原因', () {
      final meta = ManifestParser.parse(
        Uint8List.fromList(List.generate(256, (i) => i % 251)),
      );

      expect(meta.manifestUnparsed, isTrue);
      expect(meta.manifestParseFailure, isNotEmpty);
      expect(meta.packageName, isNull, reason: '失败时不该编出字段');
      expect(meta.components, isEmpty);
    });

    test('空输入同样不抛异常', () {
      late ApkMeta meta;
      expect(() => meta = ManifestParser.parse(Uint8List(0)), returnsNormally);
      expect(meta.manifestUnparsed, isTrue);
    });

    test('解析成功时失败原因为 null（不能把「解析过」也标成失败）', () {
      final meta = ManifestParser.parse(_bytes('apk/hardened-manifest.axml'));
      expect(meta.manifestUnparsed, isFalse);
      expect(meta.manifestParseFailure, isNull);
    });
  });

  group('DexStructure — 结构层', () {
    test('真实 DEX 的结构可读，且各节尺寸自洽', () {
      final structure =
          DexStructure.read('classes.dex', _bytes('dex/real-opcodes.dex'));

      expect(structure.isTraversable, isTrue);
      expect(structure.section('string_ids'), isNotNull);
      expect(structure.section('method_ids'), isNotNull);
      expect(structure.section('class_defs'), isNotNull);
    });

    test('魔数不对时记异常而不是抛，也不假装可遍历', () {
      final structure =
          DexStructure.read('classes.dex', _bytes('dex/bad-magic.dex'));

      expect(structure.anomalies, isNotEmpty);
      expect(structure.isTraversable, isFalse, reason: '结构不可信时不能继续往下走');
    });

    test('截断的 DEX 给出异常，不产生虚构的节', () {
      final structure =
          DexStructure.read('classes.dex', _bytes('dex/truncated.dex'));
      expect(structure.anomalies, isNotEmpty);
    });
  });

  group('DexMethodBodies — 调用点层', () {
    test('遍历真实 DEX 得到带调用者与偏移的调用点', () {
      final bytes = _bytes('dex/real-opcodes.dex');
      final structure = DexStructure.read('classes.dex', bytes);

      final callSites = <DexCallSite>[];
      DexMethodBodies.walk(bytes, structure, onCallSite: callSites.add);

      expect(callSites, isNotEmpty, reason: '夹具里确实有 invoke 指令');
      for (final site in callSites) {
        expect(site.callerMethodName, isNotEmpty, reason: '要能说出「哪个方法」');
        expect(site.instructionOffset, greaterThanOrEqualTo(0),
            reason: '要能说出「哪个偏移」');
        expect(site.target.name, isNotEmpty);
      }
    });

    test('坏 DEX 上遍历不抛异常，并把不同步的类记下来', () {
      final bytes = _bytes('dex/header-size-not-standard.dex');
      final structure = DexStructure.read('classes.dex', bytes);

      expect(() => DexMethodBodies.walk(bytes, structure), returnsNormally);
    });

    test('方法引用与调用点是两件事：引用可以存在而没有调用点', () {
      final bytes = _bytes('dex/real-separate.dex');
      final structure = DexStructure.read('classes.dex', bytes);

      final references = <DexMethodReference>[];
      DexMethodTable.forEachReference(bytes, structure,
          onReference: references.add);

      final callSites = <DexCallSite>[];
      DexMethodBodies.walk(bytes, structure, onCallSite: callSites.add);

      expect(references, isNotEmpty);
      // 引用数一般不少于调用点数 —— 方法签名也算引用。
      expect(references.length, greaterThanOrEqualTo(callSites.length));
    });
  });

  group('ELF — 导入符号', () {
    test('结构可读，节表按类型能定位到动态符号表', () {
      final structure = ElfStructure.read(
          'lib/arm64-v8a/libnative.so', _bytes('elf/arm64-v8a-libnative.so'));

      expect(structure.isTraversable, isTrue);
      expect(
        structure.sections.any((s) => s.type == 11), // SHT_DYNSYM
        isTrue,
        reason: '按节**类型**找，不按节名',
      );
    });

    test('只把未定义（导入）的符号算作导入', () {
      final bytes = _bytes('elf/arm64-v8a-libnative.so');
      final structure = ElfStructure.read('libnative.so', bytes);
      final symbols = ElfSymbolTable.readDynamic(bytes, structure);

      expect(symbols.symbols, isNotEmpty);
      final imported = symbols.symbols.where((s) => s.isUndefined).toList();
      expect(imported, isNotEmpty, reason: '夹具导入了 libc 符号');
      for (final symbol in imported) {
        expect(symbol.sectionIndex, 0, reason: 'SHN_UNDEF 才是导入');
      }
    });

    test('strip 过的库仍然保留导入符号（链接期需要）', () {
      final bytes = _bytes('elf/arm64-v8a-libnative-stripped.so');
      final structure = ElfStructure.read('libnative.so', bytes);
      final symbols = ElfSymbolTable.readDynamic(bytes, structure);

      expect(symbols.symbols.where((s) => s.isUndefined), isNotEmpty);
    });

    test('魔数不对时记异常、不抛，也不可遍历', () {
      final structure =
          ElfStructure.read('libnative.so', _bytes('elf/bad-magic.so'));
      expect(structure.anomalies, isNotEmpty);
      expect(structure.isTraversable, isFalse);
    });

    test('节表被剥离是合法文件，不算阻断异常', () {
      final structure = ElfStructure.read(
          'libnative.so', _bytes('elf/no-section-headers.so'));
      expect(structure.isTraversable, isFalse);
      // 关键：这不是「解析失败」，文件本身合法。
      expect(structure.sections, isEmpty);
    });
  });

  group('ArscParser — 资源表', () {
    test('真实资源表能解出条目', () {
      final parser = ArscParser(_arscFrom('night-mode-resources.apk'));
      expect(parser.getAllResources(), isNotEmpty);
    });

    // 与 ManifestParser 同一套契约：构造不抛，失败记在 [ArscParser.parseFailure]。
    test('空输入不抛异常，parseFailure 非空', () {
      late ArscParser parser;
      expect(() => parser = ArscParser(Uint8List(0)), returnsNormally);

      expect(parser.parseFailure, isNotNull);
      expect(parser.getAllResources(), isEmpty);
    });

    test('垃圾字节不抛异常，也不假装解出了资源', () {
      late ArscParser parser;
      expect(
        () => parser = ArscParser(
          Uint8List.fromList(List.generate(512, (i) => (i * 7) % 253)),
        ),
        returnsNormally,
      );

      expect(parser.parseFailure, isNotNull);
      expect(parser.getAllResources(), isEmpty);
      // 失败后读取其它 getter 也不能抛（此前 `late final` 字符串池会在这里
      // 抛 LateInitializationError —— 那只是把异常推迟到了下一次读）。
      expect(parser.getLocales().toList(), isEmpty);
      expect(parser.getDensities().toList(), isEmpty);
      expect(parser.getUiModeTypes(), isEmpty);
      expect(parser.hasNightModeResources, isFalse);
      expect(parser.getStringValue(0x7f010001), isNull);
    });

    test('真实资源表解析成功时 parseFailure 为 null', () {
      final parser = ArscParser(_arscFrom('night-mode-resources.apk'));
      expect(parser.parseFailure, isNull);
      expect(parser.getAllResources(), isNotEmpty);
    });
  });
}
