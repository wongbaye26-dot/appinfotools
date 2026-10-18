// APK Signing Block：回答「有没有 v2 / v3 签名块」。
//
// ## 为什么要自己做这件事
//
// 签名结论一直完全交给 `apksigner`，于是：
//
// 1. **没装工具就一律「未验证」** —— 而「有没有签名」是纯结构问题，能自己答；
// 2. 看不出「只有 v1 签名」。v1（JAR 签名）只保护 ZIP 条目的摘要，
//    不保护 ZIP 结构本身 —— 往里塞额外条目**不会**让 v1 失效，这正是
//    重打包最常见的形态；v2+ 把整份归档的摘要放进签名块，塞条目就会失效。
//
// ## 分工不变
//
// 我们只回答「块在不在、里面有哪些 id」，**不验证任何签名**。
// 「签名有效」仍然只有 `apksigner` 说了算。
//
// ## 期望值来源（外部工具，不是本项目解析器）
//
// 三个夹具都是用 `apksigner` 真实签的（`--v*-signing-enabled` 精确控制），
// 并用 `apksigner verify -v` 独立核对：
//
// 夹具的源文件（可复现，不要只留二进制）：
//   test/fixtures/apk/signed-fixture.AndroidManifest.xml
//
// ```
// $ apksigner verify -v signed-v1-only.apk
//   Verified using v1 scheme (JAR signing): true
//   Verified using v2 scheme (APK Signature Scheme v2): false
//   Verified using v3 scheme (APK Signature Scheme v3): false
// $ apksigner verify -v signed-v2-v3.apk
//   Verified using v2 scheme (APK Signature Scheme v2): true
//   Verified using v3 scheme (APK Signature Scheme v3): true
// ```

import 'dart:io';
import 'dart:typed_data';

import 'package:apk_parser/apk_parser.dart';
import 'package:flutter_test/flutter_test.dart';

const _v1Only = 'test/fixtures/apk/signed-v1-only.apk';
const _v2v3 = 'test/fixtures/apk/signed-v2-v3.apk';
const _unsigned = 'test/fixtures/apk/signed-unsigned.apk';

/// 读整个文件（夹具只有几 KB，不需要流式）。
ApkRangeReader _fileReader(String path) {
  final bytes = File(path).readAsBytesSync();
  return (offset, length) => Uint8List.sublistView(
        bytes,
        offset,
        (offset + length).clamp(0, bytes.length),
      );
}

ApkSigningSchemes _parse(String path) => parseApkSigningBlock(
      fileLength: File(path).lengthSync(),
      read: _fileReader(path),
    );

void main() {
  group('v2 + v3 签名', () {
    test('两个方案都认出来了', () {
      final schemes = _parse(_v2v3);
      expect(schemes.parsed, isTrue, reason: schemes.failure);
      expect(schemes.hasV2, isTrue, reason: 'apksigner 说 v2 = true');
      expect(schemes.hasV3, isTrue, reason: 'apksigner 说 v3 = true');
      expect(schemes.hasV31, isFalse);
      expect(schemes.v1Only, isFalse);
      expect(schemes.schemeNames, ['v2', 'v3']);
    });

    test('pair id 里能看出是哪个方案（不是只有「有块」）', () {
      final schemes = _parse(_v2v3);
      expect(schemes.pairIds, contains(ApkSignatureBlockId.v2));
      expect(schemes.pairIds, contains(ApkSignatureBlockId.v3));
    });
  });

  group('只有 v1 签名', () {
    test('识别为「没有 v2+ 方案」', () {
      final schemes = _parse(_v1Only);
      expect(schemes.parsed, isTrue, reason: schemes.failure);
      expect(schemes.v1Only, isTrue,
          reason: 'apksigner 说 v2/v3 全为 false，签名块根本不存在');
      expect(schemes.schemeNames, isEmpty);
    });

    test('这是**结构信号**，不是「签名无效」的结论', () {
      // v1-only 的包可以是**完全有效**的签名（apksigner 说 Verifies）。
      // 我们只说「没有 v2+ 方案」，不推断「被改过」。
      final schemes = _parse(_v1Only);
      expect(schemes.parsed, isTrue);
      expect(schemes.v1Only, isTrue);
    });
  });

  group('完全没签名', () {
    test('也没有签名块；与 v1-only 在结构上不可区分', () {
      final schemes = _parse(_unsigned);
      expect(schemes.parsed, isTrue, reason: schemes.failure);
      expect(schemes.v1Only, isTrue,
          reason: '结构上「没有签名块」对两者是一样的 —— 所以这条不能当'
              '「签名有效」用，必须配合 apksigner');
    });
  });

  group('读不出 ≠ 没有', () {
    test('文件太小 → unreadable，不是 v1Only', () {
      final schemes = parseApkSigningBlock(
        fileLength: 10,
        read: (o, l) => Uint8List(0),
      );
      expect(schemes.parsed, isFalse);
      expect(schemes.v1Only, isFalse, reason: '「读不出」绝不能折成「只有 v1 签名」');
      expect(schemes.failure, contains('too small'));
    });

    test('不是 ZIP → unreadable', () {
      final junk = Uint8List.fromList(List.filled(4096, 0x41));
      final schemes = parseApkSigningBlock(
        fileLength: junk.length,
        read: (o, l) => Uint8List.sublistView(
          junk,
          o,
          (o + l).clamp(0, junk.length),
        ),
      );
      expect(schemes.parsed, isFalse);
      expect(schemes.failure, contains('end-of-central-directory'));
    });

    test('中央目录偏移越界 → unreadable', () {
      final file = File(_v2v3).readAsBytesSync();
      // 声明一个远超文件长度的中央目录偏移。
      final patched = Uint8List.fromList(file);
      for (var i = patched.length - 22; i >= 0; i--) {
        if (patched[i] == 0x50 &&
            patched[i + 1] == 0x4b &&
            patched[i + 2] == 0x05 &&
            patched[i + 3] == 0x06) {
          patched[i + 16] = 0xff;
          patched[i + 17] = 0xff;
          patched[i + 18] = 0xff;
          patched[i + 19] = 0x7f;
          break;
        }
      }
      final schemes = parseApkSigningBlock(
        fileLength: patched.length,
        read: (o, l) => Uint8List.sublistView(
          patched,
          o,
          (o + l).clamp(0, patched.length),
        ),
      );
      expect(schemes.parsed, isFalse);
      expect(schemes.failure, contains('out of range'));
    });

    test('块长度被伪造成天文数字 → 在上限处拒绝，不去分配内存', () {
      final file = File(_v2v3).readAsBytesSync();
      final patched = Uint8List.fromList(file);
      // 找到 magic，把块头声明的 size 改成 0x7fffffff。
      for (var i = patched.length - 16; i >= 0; i--) {
        if (patched[i] == 0x41 &&
            patched[i + 1] == 0x50 &&
            patched[i + 2] == 0x4b &&
            patched[i + 3] == 0x20) {
          // 块头声明的 size 紧贴在 magic 之前 8 字节：
          // [size:8][pairs][size:8][magic:16]
          final sizeOffset = i - 8;
          if (sizeOffset < 0) break;
          patched[sizeOffset] = 0xff;
          patched[sizeOffset + 1] = 0xff;
          patched[sizeOffset + 2] = 0xff;
          patched[sizeOffset + 3] = 0x7f;
          patched[sizeOffset + 4] = 0x00;
          patched[sizeOffset + 5] = 0x00;
          patched[sizeOffset + 6] = 0x00;
          patched[sizeOffset + 7] = 0x00;
          break;
        }
      }
      final schemes = parseApkSigningBlock(
        fileLength: patched.length,
        read: (o, l) => Uint8List.sublistView(
          patched,
          o,
          (o + l).clamp(0, patched.length),
        ),
      );
      expect(schemes.parsed, isFalse);
      expect(schemes.failure, contains('cap'), reason: '不可信的长度不能决定我们的内存分配');
    });
  });

  group('接进 ApkReader', () {
    test('解析 APK 时带上签名方案', () async {
      final reader = ApkReader();
      addTearDown(reader.close);
      final opened = await reader.open(_v2v3);
      expect(opened.isOk, isTrue);
      final meta = await reader.parse();
      expect(meta?.signingSchemes, isNotNull);
      expect(meta!.signingSchemes!.hasV2, isTrue);
      expect(meta.signingSchemes!.hasV3, isTrue);
    });

    test('v1-only 的包解析照旧成功，签名方案为空', () async {
      final reader = ApkReader();
      addTearDown(reader.close);
      await reader.open(_v1Only);
      final meta = await reader.parse();
      expect(meta, isNotNull, reason: '签名方案读不出来不该阻断解析');
      expect(meta!.signingSchemes!.v1Only, isTrue);
      expect(meta.packageName, 'com.example.extrafixture');
    });

    test('从字节打开时没有可寻址文件 → null（不是「没有签名」）', () async {
      final bytes = File(_v2v3).readAsBytesSync();
      final reader = ApkReader();
      addTearDown(reader.close);
      reader.openBytes(Uint8List.fromList(bytes));
      final meta = await reader.parse();
      expect(meta!.signingSchemes, isNull,
          reason: 'openBytes 没有文件路径，读不了尾部；null 表示「没解析」');
    });
  });

  test('三个夹具都是真实签名产物且非空', () {
    for (final path in [_v1Only, _v2v3, _unsigned]) {
      final file = File(path);
      expect(file.existsSync(), isTrue, reason: path);
      expect(file.lengthSync(), greaterThan(1000), reason: path);
    }
  });
}
