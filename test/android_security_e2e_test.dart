// **端到端**的 Android 安全审计：从磁盘上的 APK 走到发现项。
//
// ## 为什么需要这一条
//
// 引擎函数有测试（`android_security_audit_test.dart`），装配层也有测试，
// 但中间那一层 —— 「`ApkReader` 从 ZIP 里取出 DEX 与 `.so`，`selectLibraries`
// 挑出要读的库，再交给审计」—— 在真实归档上从未被测过。
//
// 仓库里 13 个 APK 夹具**全部 0 DEX、0 `.so`**（2026-10-19 审计实测），
// 所以 `android.dex.*`、`nativeSymbols`、`nativeHardening` 在所有夹具上都是
// `notCovered` / `notApplicable`。一旦 `parse_task.dart` 少传一个参数
// （本项目已经踩过五次），单测全绿、真实包的结论却是错的。
//
// ## 夹具怎么来的
//
// 与 `xapk_installer_test.dart` 同一套做法：**用 `ZipEncoder` 现造**，
// 而不是提交一个二进制样本，更不手拼字节。
// - 清单与资源表直接复用 `signed-v2-v3.apk` 里的真实条目（不自己写 AXML）；
// - DEX 用 `test/fixtures/dex` 的真实产物（一个含 OCR+上传同方法体，一个含网络）；
// - `.so` 用 `test/fixtures/elf` 的真实产物（一个导入 system/socket 等符号，
//   一个把栈标成可执行）。
//
// 重写 ZIP 会丢掉 APK Signing Block —— 这是**预期**的：本用例只验证审计接线，
// 签名相关断言在 `android_signature_and_cleartext_test.dart` 里单独覆盖。

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:analysis_model/analysis_model.dart';
import 'package:apk_parser/apk_parser.dart';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _read(String path) => File(path).readAsBytesSync();

/// 造一个含 2 个 DEX 与 2 个 `.so` 的最小 APK。
Uint8List _buildApk() {
  final base =
      ZipDecoder().decodeBytes(_read('test/fixtures/apk/signed-v2-v3.apk'));
  final out = Archive();
  for (final file in base.files) {
    if (!file.isFile) continue;
    out.addFile(ArchiveFile(file.name, file.size, file.content as List<int>));
  }

  void add(String name, Uint8List bytes) =>
      out.addFile(ArchiveFile(name, bytes.length, bytes));

  add('classes.dex', _read('test/fixtures/dex/real-cooccurrence.dex'));
  add('classes2.dex', _read('test/fixtures/dex/real-netprobe.dex'));
  // Maven 坐标：DEX 里没有版本号，SDK 版本只能从这里读。
  add(
    'META-INF/maven/com.example.sdk/demo/pom.properties',
    Uint8List.fromList(
      utf8.encode('groupId=com.example.sdk\n'
          'artifactId=demo\n'
          'version=1.2.3\n'),
    ),
  );
  add('lib/arm64-v8a/libnative.so',
      _read('test/fixtures/elf/arm64-v8a-libnative.so'));
  add('lib/arm64-v8a/libexecstack.so',
      _read('test/fixtures/elf/hardening-execstack.so'));
  return Uint8List.fromList(ZipEncoder().encode(out));
}

/// 复刻 `lib/apkparser/parse_task.dart` 的调用序列。
Future<({ApkMeta meta, SecurityAnalysisResult security})> _auditFromDisk(
  String path,
) async {
  final reader = ApkReader();
  final open = await reader.open(path);
  expect(open.isOk, isTrue, reason: '自造的 APK 打不开：${open.name}');
  final meta = await reader.parse();
  expect(meta, isNotNull, reason: '清单解析失败：${reader.manifestFailure}');

  final dexEntries = <DexBytes>[
    for (final name in reader.listFiles(extension: '.dex'))
      if (reader.readFile(name) case final bytes?) DexBytes(name, bytes),
  ];
  final candidates = reader.listFilesWithSize(extension: '.so');
  final selection = NativeSymbolScanner.selectLibraries(candidates);
  final natives = <NativeLibraryBytes>[
    for (final name in selection.selected)
      if (reader.readFile(name) case final bytes?)
        NativeLibraryBytes(name, bytes),
  ];

  final security = AndroidSecurityAudit.audit(
    meta: meta!,
    dexEntries: dexEntries,
    nativeEntries: natives,
    nativeLibraryTotal: NativeSymbolScanner.uniqueLibraryCount(candidates),
    nativeSkipped: selection.skipped,
    arscEntryCount: reader.arscParser?.getAllResources().length,
  );
  reader.close();
  return (meta: meta, security: security);
}

void main() {
  late Directory temp;
  late String apkPath;

  setUpAll(() {
    temp = Directory.systemTemp.createTempSync('apk-e2e-');
    apkPath = '${temp.path}/security-e2e.apk';
    File(apkPath).writeAsBytesSync(_buildApk());
  });

  tearDownAll(() => temp.deleteSync(recursive: true));

  test('DEX 与原生库真的从归档里被取出来并参与审计', () async {
    final result = await _auditFromDisk(apkPath);
    final coverage = result.security.coverage;

    // 三个此前在所有夹具上都是 notCovered / notApplicable 的维度。
    expect(coverage.entry('android.dex.structure')!.status,
        CoverageStatus.covered);
    expect(
        coverage.entry('android.dex.strings')!.status, CoverageStatus.covered);
    expect(coverage.entry('android.dex.strings')!.covered, greaterThan(0));
    expect(coverage.entry('android.dex.methodReferences')!.status,
        CoverageStatus.covered);
    expect(coverage.entry('android.nativeSymbols')!.status,
        CoverageStatus.covered);
    // 两个唯一库名（arm64-v8a 下两个不同文件名）都读到了。
    expect(coverage.entry('android.nativeSymbols')!.ratioText, '2/2');
    expect(coverage.entry('android.nativeHardening')!.status,
        CoverageStatus.covered);
    // 加固维度问的是「读到几个库」，不是「加固得好不好」。
    expect(coverage.entry('android.nativeHardening')!.ratioText, '2/2');
  });

  test('真实 DEX 的调用点证据进入报告', () async {
    final result = await _auditFromDisk(apkPath);
    final callSites = result.security.coverage.entry('android.dex.callSites')!;
    expect(callSites.status, CoverageStatus.covered);
    expect(callSites.covered, greaterThan(0));

    // 能力发现来自 `real-cooccurrence.dex`（OCR 与上传在同一方法体）。
    final ids = result.security.findings.map((f) => f.ruleId).toSet();
    expect(ids, contains('ANDROID-OCR-CAPABILITY'));
    expect(ids, contains('ANDROID-UPLOAD-API'));

    final upload = result.security.findings
        .firstWhere((f) => f.ruleId == 'ANDROID-UPLOAD-API');
    // 证据必须到**调用点**级别（`code.call_site`，带方法签名与指令偏移），
    // 而不是「字符串里出现过」或「method_ids 引用过」。
    final callSite =
        upload.evidence.where((e) => e.detailCode == 'code.call_site').toList();
    expect(callSite, isNotEmpty, reason: '缺少调用点证据');
    expect(
      callSite.first.detail,
      contains('@'),
      reason: '调用点证据应形如 L…;.uploadImage(…)V @ L…;.run(…)V +0x3',
    );
  });

  test('原生库的符号能力与可执行栈都从真实 .so 读出来', () async {
    final result = await _auditFromDisk(apkPath);
    final ids = result.security.findings.map((f) => f.ruleId).toSet();

    // `libnative.so` 导入了 system / popen / socket / connect 等。
    expect(ids, contains('ANDROID-NATIVE-SYMBOLS'));
    final symbols = result.security.findings
        .firstWhere((f) => f.ruleId == 'ANDROID-NATIVE-SYMBOLS');
    expect(symbols.confidence, SecurityConfidence.independentCapability);
    expect(symbols.messageArgs['symbols'], isA<List<Object?>>());

    // `libexecstack.so` 的 PT_GNU_STACK 含 PF_X。
    expect(ids, contains('ANDROID-NATIVE-EXEC-STACK'));
  });

  test('Maven 坐标从归档里读出来（SDK 版本的唯一静态来源）', () async {
    final result = await _auditFromDisk(apkPath);
    final artifacts = result.meta.mavenArtifacts;
    expect(artifacts, hasLength(1));
    expect(artifacts.single.groupId, 'com.example.sdk');
    expect(artifacts.single.artifactId, 'demo');
    expect(artifacts.single.version, '1.2.3');
    expect(artifacts.single.path, contains('META-INF/maven/'));
  });

  test('真实 DEX 上真的建立了调用图（不是只在单测里能建）', () {
    // 调用图是「1–2 跳」那一档证据的前提。它由 `DexMethodScanner` 在遍历
    // `invoke-*` 时顺手记下 —— 这条用例确认它在**真实字节码**上确实产出了边。
    final scan = DexMethodScanner.scan([
      DexBytes(
        'classes.dex',
        _read('test/fixtures/dex/real-cooccurrence.dex'),
      ),
    ]);
    expect(scan.callSiteCount, greaterThan(0));
    expect(scan.callersOfMarkerMethods, isNotEmpty);
    // 上传方法是被调用方，调用者是 Pipeline.run。
    final uploadCallers = scan.callersOfMarkerMethods.entries
        .where((e) => e.key.contains('uploadImage'))
        .expand((e) => e.value)
        .toList();
    expect(uploadCallers, isNotEmpty);
    expect(uploadCallers.any((c) => c.contains('Pipeline')), isTrue);
  });

  test('有上传能力时不再输出「未发现上传」的结论', () async {
    final result = await _auditFromDisk(apkPath);
    expect(
      result.security.findings.where((f) => f.ruleId == 'ANDROID-RULE-F'),
      isEmpty,
      reason: 'RULE-F 是「未发现上传特征」，本夹具明确有上传调用点',
    );
  });
}
