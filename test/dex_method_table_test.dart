// DEX `method_ids` / `type_ids` 的解析。
//
// 正常样本是 `javac` + `d8` 真实产出的 DEX，期望值来自 `dexdump`：
// - 条数来自 `dexdump -f`（method_ids_size / type_ids_size）
// - 描述符来自 `dexdump -d` 的 `invoke-*` 行与 `dexdump -s` 的字符串表
// 全部**不是**从本项目解析器取的 —— 那样等于自证。
//
// 这一层要回答的问题只有一个：**「代码引用了」与「字符串里提到了」怎么分**。
// 样本里的 `okhttp3` 只出现在一个字符串字面量里（`string[000024]`），
// 而 `java.net.HttpURLConnection` 出现在方法引用里。两者在字符串扫描器眼里
// 一模一样，在这一层必须能分开。

import 'dart:io';
import 'dart:typed_data';

import 'package:apk_parser/apk_parser.dart';
import 'package:flutter_test/flutter_test.dart';

const String _fixtureDir = 'test/fixtures/dex';

Uint8List _bytes(String name) => File('$_fixtureDir/$name').readAsBytesSync();

/// 收集全部方法引用。
List<DexMethodReference> _references(String name) {
  final bytes = _bytes(name);
  final structure = DexStructure.read(name, bytes);
  final refs = <DexMethodReference>[];
  DexMethodTable.forEachReference(bytes, structure, onReference: refs.add);
  return refs;
}

List<String> _typeDescriptors(String name) {
  final bytes = _bytes(name);
  final structure = DexStructure.read(name, bytes);
  final types = <String>[];
  DexMethodTable.forEachType(bytes, structure, onDescriptor: types.add);
  return types;
}

void main() {
  group('真实 DEX 的方法引用（对照 dexdump）', () {
    test('条数与 method_ids_size 一致', () {
      final bytes = _bytes('real-netprobe.dex');
      final structure = DexStructure.read('classes.dex', bytes);
      final refs = <DexMethodReference>[];
      final result = DexMethodTable.forEachReference(bytes, structure,
          onReference: refs.add);

      expect(structure.section('method_ids')!.size, 11);
      expect(result.visitedCount, 11);
      expect(result.skippedCount, 0);
      expect(result.truncated, isFalse);
    });

    test('被调用方法的描述符与 dexdump -d 逐字一致', () {
      final names = [
        for (final r in _references('real-netprobe.dex')) r.displayName
      ];

      // 下面这些是 `dexdump -d` 里 `invoke-*` 行末尾的原样文本。
      for (final expected in const [
        'Ljava/net/HttpURLConnection;.getInputStream()Ljava/io/InputStream;',
        'Ljava/net/HttpURLConnection;.setRequestMethod(Ljava/lang/String;)V',
        'Ljava/net/URL;.openConnection()Ljava/net/URLConnection;',
        'Ljava/net/URL;.<init>(Ljava/lang/String;)V',
        'Ljava/lang/Object;.<init>()V',
        'Lcom/example/fixture/NetProbe;.<init>()V',
        'Lcom/example/fixture/NetProbe;.helper(I)I',
      ]) {
        expect(names, contains(expected), reason: '实际解析出：$names');
      }
    });

    test('type_ids 的条数与内容与 dexdump -s 一致', () {
      final types = _typeDescriptors('real-netprobe.dex');

      expect(types, hasLength(12), reason: 'type_ids_size 是 12');
      // 这些描述符在 `dexdump -s` 的字符串表里能逐个找到。
      for (final expected in const [
        'Lcom/example/fixture/NetProbe;',
        'Lcom/example/fixture/Caller;',
        'Ljava/net/HttpURLConnection;',
        'Ljava/net/URL;',
        'Ljava/io/InputStream;',
      ]) {
        expect(types, contains(expected), reason: '实际解析出：$types');
      }
    });

    test('javaClassName 把描述符转成点号形式', () {
      final refs = _references('real-netprobe.dex');
      final http = refs.firstWhere(
        (r) => r.classDescriptor == 'Ljava/net/HttpURLConnection;',
      );

      expect(http.javaClassName, 'java.net.HttpURLConnection');
      expect(http.name, 'getInputStream');
    });
  });

  // 这一组是**第二层取证存在的理由**：字符串扫描器分不开这两者。
  group('「代码引用了」与「字符串里提到了」必须分开', () {
    test('okhttp3 只在字符串表里，没有任何代码引用它', () {
      // `dexdump -s` 显示 string[000024] = 'okhttp3 is mentioned here but …'
      final bytes = _bytes('real-netprobe.dex');

      // 字符串扫描器会命中它。
      final scan = DexClueScanner.scan([DexBytes('classes.dex', bytes)]);
      expect(
        scan.clues.any((c) => c.markerId == 'okhttp'),
        isTrue,
        reason: '字符串扫描命中 okhttp3 是预期行为',
      );

      // 但方法引用与类型表里**一个都没有** —— 它只是个字面量。
      final refs = _references('real-netprobe.dex');
      final types = _typeDescriptors('real-netprobe.dex');
      expect(
        refs.any((r) => r.displayName.toLowerCase().contains('okhttp')),
        isFalse,
        reason: '实际方法引用：${refs.map((r) => r.displayName).toList()}',
      );
      expect(
        types.any((t) => t.toLowerCase().contains('okhttp')),
        isFalse,
      );
    });

    test('HttpURLConnection 在方法引用里（它是真的被代码用到了）', () {
      final refs = _references('real-netprobe.dex');

      expect(
        refs.any((r) => r.classDescriptor == 'Ljava/net/HttpURLConnection;'),
        isTrue,
      );
    });
  });

  group('边界与预算', () {
    test('结构不可遍历时返回空结果，不抛异常', () {
      // bad-magic 的 DEX：段表根本没读出来。
      final bytes = _bytes('bad-magic.dex');
      final structure = DexStructure.read('classes.dex', bytes);

      expect(structure.isTraversable, isFalse);

      final refs = <DexMethodReference>[];
      final result = DexMethodTable.forEachReference(bytes, structure,
          onReference: refs.add);

      expect(refs, isEmpty);
      expect(result.visitedCount, 0);
    });

    test('段边界越界时同样不抛异常', () {
      for (final name in const [
        'method-ids-off-out-of-range.dex',
        'method-ids-size-absurd.dex',
        'string-ids-off-in-header.dex',
        'truncated.dex',
      ]) {
        final bytes = _bytes(name);
        final structure = DexStructure.read(name, bytes);
        final refs = <DexMethodReference>[];
        // 不期待任何结果，只要求不炸。
        DexMethodTable.forEachReference(bytes, structure,
            onReference: refs.add);
        DexMethodTable.forEachType(bytes, structure, onDescriptor: (_) {});
      }
    });

    test('超过预算时如实标记 truncated，不假装读完了', () {
      final bytes = _bytes('real-netprobe.dex');
      final structure = DexStructure.read('classes.dex', bytes);
      final refs = <DexMethodReference>[];
      final result = DexMethodTable.forEachReference(
        bytes,
        structure,
        onReference: refs.add,
        maxEntries: 3,
      );

      expect(refs, hasLength(3));
      expect(result.truncated, isTrue);
      expect(result.visitedCount, 3);
    });

    test('空 DEX（method_ids_size = 0）不产生任何引用', () {
      // 只留头部 + 把 method_ids_size 清零 —— 手工构造，因为要精确控制。
      final bytes = Uint8List.fromList(_bytes('real-netprobe.dex'));
      final view = ByteData.sublistView(bytes);
      view.setUint32(0x58, 0, Endian.little); // method_ids_size
      view.setUint32(0x5C, 0, Endian.little); // method_ids_off

      final structure = DexStructure.read('empty.dex', bytes);
      final refs = <DexMethodReference>[];
      final result = DexMethodTable.forEachReference(bytes, structure,
          onReference: refs.add);

      expect(refs, isEmpty);
      expect(result.visitedCount, 0);
      expect(structure.isTraversable, isTrue, reason: 'size=0/off=0 是合法组合');
    });
  });
}
