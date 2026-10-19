// `ANDROID-NATIVE-EXEC-STACK` —— 原生库把栈标记为可执行。
//
// ## 为什么这一维只有一条规则
//
// 实测 4 个真实包的 **386 个** arm64 `.so`：
//
// | 属性 | 不满足的库数 |
// |---|---|
// | 可执行栈 | **0** |
// | 缺 RELRO | **1**（Flutter 的 `libapp.so`，Dart AOT 快照，合法选择）|
// | 未 strip | **0** |
//
// NDK 默认就带 `-z relro -z now` 与 NX 栈，所以：
//
// - 逐库报「缺 RELRO」是**纯噪声** —— 它会稳定命中所有 Flutter 应用；
// - 只有「可执行栈」是**没有正当理由**的缺陷（没有哪种正常构建需要它）。
//
// 本文件钉住三件事：
// 1. 有可执行栈的库 → 一条 P2；
// 2. 只有缺 RELRO / 未 strip 的库 → **不产出发现项**（走覆盖率说明）；
// 3. 聚合而不是逐库 —— 100 个库也只产出一条。

import 'dart:io';
import 'dart:typed_data';

import 'package:analysis_model/analysis_model.dart';
import 'package:apk_parser/apk_parser.dart';
import 'package:flutter_test/flutter_test.dart';

const _elfDir = 'test/fixtures/elf';

Uint8List _elf(String name) =>
    Uint8List.fromList(File('$_elfDir/$name').readAsBytesSync());

ApkMeta _meta() => ApkMeta()
  ..packageName = 'com.example.nativetest'
  ..targetSdkVersion = 34;

SecurityAnalysisResult _audit(List<NativeLibraryBytes> libs) =>
    AndroidSecurityAudit.audit(
      meta: _meta(),
      dexEntries: const [],
      nativeEntries: libs,
    );

List<SecurityFinding> _byId(SecurityAnalysisResult r, String id) =>
    r.findings.where((f) => f.ruleId == id).toList();

NativeLibraryBytes _lib(String path, String fixture) =>
    NativeLibraryBytes(path, _elf(fixture));

void main() {
  group('可执行栈', () {
    test('一个库 → 一条 P2 / confirmed，并点名', () {
      final result = _audit([
        _lib('lib/arm64-v8a/libbad.so', 'hardening-execstack.so'),
      ]);
      final finding = _byId(result, 'ANDROID-NATIVE-EXEC-STACK');
      expect(finding, hasLength(1));
      expect(finding.single.severity, SecuritySeverity.p2);
      expect(finding.single.confidence, SecurityConfidence.confirmed,
          reason: 'PT_GNU_STACK 含 PF_X 是文件里的结构事实，没有推断成分');
      expect(finding.single.messageArgs['names'], ['lib/arm64-v8a/libbad.so']);
      expect(
          finding.single.evidence.single.location, 'lib/arm64-v8a/libbad.so');
      expect(finding.single.evidence.single.detail, contains('PF_X'));
    });

    test('NX 栈的库 → 不报', () {
      final result = _audit([
        _lib('lib/arm64-v8a/libok.so', 'hardening-default.so'),
      ]);
      expect(_byId(result, 'ANDROID-NATIVE-EXEC-STACK'), isEmpty);
    });

    test('多个库只产出一条（聚合，不逐库刷）', () {
      final result = _audit([
        _lib('lib/arm64-v8a/liba.so', 'hardening-execstack.so'),
        _lib('lib/arm64-v8a/libb.so', 'hardening-execstack.so'),
        _lib('lib/arm64-v8a/libc.so', 'hardening-execstack.so'),
      ]);
      final finding = _byId(result, 'ANDROID-NATIVE-EXEC-STACK');
      expect(finding, hasLength(1), reason: '3 个库也只该有一条发现项');
      expect(finding.single.messageArgs['count'], 3);
      expect((finding.single.messageArgs['names']! as List), hasLength(3));
      expect(finding.single.evidence, hasLength(3));
    });

    test('超过 5 个时正文说明「另有 N 个未列出」', () {
      final result = _audit([
        for (var i = 0; i < 8; i++)
          _lib('lib/arm64-v8a/lib$i.so', 'hardening-execstack.so'),
      ]);
      final finding = _byId(result, 'ANDROID-NATIVE-EXEC-STACK').single;
      expect(finding.messageCode, 'android.native_exec_stack_many');
      expect(finding.messageArgs['count'], 8);
      expect((finding.messageArgs['names']! as List), hasLength(5));
      expect(finding.messageArgs['more'], 3);
    });
  });

  group('不该报的：缺 RELRO / 未 strip', () {
    test('缺 RELRO 的库不产出发现项（否则所有 Flutter 应用都被报）', () {
      final result = _audit([
        _lib('lib/arm64-v8a/libapp.so', 'hardening-norelro.so'),
      ]);
      expect(_byId(result, 'ANDROID-NATIVE-EXEC-STACK'), isEmpty);
      // 但要在覆盖率里说清楚 —— 「没报」不等于「没看」。
      final entry = result.coverage.entry('android.nativeHardening');
      expect(entry, isNotNull);
      expect(entry!.noteCode, 'android.native_hardening.some_without_relro');
      expect(entry.noteArgs['count'], 1);
      expect(entry.noteArgs['total'], 1);
    });

    test('未 strip 的库不产出发现项（留符号不是缺陷）', () {
      final result = _audit([
        _lib('lib/arm64-v8a/libdebug.so', 'hardening-canary.so'),
      ]);
      expect(
          result.findings.where((f) => f.ruleId.contains('NATIVE')), isEmpty);
    });

    test('Partial RELRO 也不算缺陷', () {
      final result = _audit([
        _lib('lib/arm64-v8a/libp.so', 'hardening-partial-relro.so'),
      ]);
      expect(
        result.findings.where((f) => f.ruleId.startsWith('ANDROID-NATIVE')),
        isEmpty,
      );
    });
  });

  group('覆盖率：数字比逐库列举有用', () {
    test('全部 Full RELRO + NX → covered，无 note', () {
      final result = _audit([
        _lib('lib/arm64-v8a/liba.so', 'hardening-default.so'),
        _lib('lib/arm64-v8a/libb.so', 'hardening-default.so'),
      ]);
      final entry = result.coverage.entry('android.nativeHardening')!;
      expect(entry.status, CoverageStatus.covered);
      expect(entry.covered, 2, reason: '2/2 都是 Full RELRO 且 NX');
      expect(entry.limit, 2);
      expect(entry.noteCode, isNull);
    });

    test('有一个缺 RELRO → 覆盖数仍是 2/2（问的是「读到几个」），质量进 note', () {
      // `covered/limit` 与 `status` 必须回答同一个问题：「原生库的加固属性
      // 读到了多少」。加固质量（缺 RELRO）是**另一个问题**，写在 note 里。
      // 此前 `covered` 数的是「加固得好的库」，于是 266 个库只解析 10 个时
      // 面板会显示 8/10，读起来像覆盖了 80%（2026-10-19 审计 P2-1）。
      final result = _audit([
        _lib('lib/arm64-v8a/liba.so', 'hardening-default.so'),
        _lib('lib/arm64-v8a/libapp.so', 'hardening-norelro.so'),
      ]);
      final entry = result.coverage.entry('android.nativeHardening')!;
      expect(entry.covered, 2);
      expect(entry.limit, 2);
      expect(entry.noteCode, 'android.native_hardening.some_without_relro');
    });

    test('没有原生库 → notApplicable，且明说「没读」', () {
      final entry = _audit(const []).coverage.entry('android.nativeHardening')!;
      expect(entry.status, CoverageStatus.notApplicable);
      expect(entry.noteCode, 'android.native_hardening.not_provided');
    });

    test('读不出的库不参与分母 —— 不能把「没读到」算成「已加固」', () {
      final result = _audit([
        _lib('lib/arm64-v8a/liba.so', 'hardening-default.so'),
        // 一份不是 ELF 的「库」
        NativeLibraryBytes(
          'lib/arm64-v8a/libjunk.so',
          Uint8List.fromList(List.filled(64, 0x41)),
        ),
      ]);
      final entry = result.coverage.entry('android.nativeHardening')!;
      expect(entry.limit, 1, reason: '分母只算真正解析成功的库；读不出的不算「已加固」');
      expect(entry.covered, 1);
    });
  });
}
