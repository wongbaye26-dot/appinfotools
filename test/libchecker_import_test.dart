// 规则包导入：把上游 portable-v5.zip 折成与内置资产同构的 bundle。
//
// 这条路径的意义是「不重新发版也能更新规则」。因此测试的重点不是「能解析」，
// 而是：结构对齐（读取端只认一种形状）、规则类型过滤、详情去重与语言键、
// 坏包必须给出可分辨的错误码而不是静默空规则。

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:apk_info_tool/utils/libchecker_data.dart';
import 'package:apk_info_tool/utils/libchecker_rules_import.dart';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _detail(String label) => {
      'data': [
        {
          'locale': 'zh-Hans',
          'data': {
            'label': '$label 中文',
            'dev_team': 'Vendor',
            'description': '中文说明',
            'source_link': 'https://example.com/$label',
            'rule_contributors': ['alice'],
          },
        },
        {
          'locale': 'en',
          'data': {
            'label': label,
            'dev_team': 'Vendor',
            'description': 'English description',
            'source_link': 'https://example.com/$label',
            'rule_contributors': <String>[],
          },
        },
      ],
    };

Uint8List _zip({
  int schemaVersion = 5,
  int dataVersion = 51,
  bool withRule = true,
}) {
  final core = {
    'schemaVersion': schemaVersion,
    'rules': withRule
        ? [
            {
              'id': 1,
              'name': 'libdemo.so',
              'label': 'Demo',
              'type': 0,
              'iconId': 'ic_lib_demo',
              'isSimpleColorIcon': true,
              'isRegexRule': false,
              'priority': 1,
              'detailPath': 'details/uuid-1/1.json',
            },
            {
              'id': 2,
              'name': r'com\.demo\.(.*)',
              'label': 'Demo SDK',
              'type': 5,
              'iconId': '',
              'isSimpleColorIcon': false,
              'isRegexRule': true,
              'priority': 2,
              // 两条规则指向同一份详情时应合并成一个 detailIndex。
              'detailPath': 'details/uuid-2/2.json',
            },
            {
              'id': 3,
              'name': 'android.permission.CAMERA',
              'label': 'Camera',
              'type': 7,
              'iconId': '',
              'isSimpleColorIcon': false,
              'isRegexRule': false,
              'priority': 3,
            },
          ]
        : <Map<String, dynamic>>[],
  };

  final archive = Archive()
    ..addFile(ArchiveFile.string(
      'metadata.json',
      jsonEncode({
        'dataVersion': dataVersion,
        'sourceRevision': 'rev-51',
        'ruleCount': 3,
      }),
    ))
    ..addFile(ArchiveFile.string('core.json', jsonEncode(core)))
    ..addFile(ArchiveFile.string(
      'details/uuid-1/1.json',
      jsonEncode(_detail('Demo')),
    ))
    ..addFile(ArchiveFile.string(
      'details/uuid-2/2.json',
      jsonEncode(_detail('Demo')),
    ))
    ..addFile(ArchiveFile.string('icons/ic_lib_demo.svg', '<svg/>'));

  return Uint8List.fromList(ZipEncoder().encode(archive));
}

void main() {
  // 回退内置资产要走 rootBundle，因此需要测试绑定。
  TestWidgetsFlutterBinding.ensureInitialized();

  test('portable-v5.zip → 与内置资产同构的 bundle', () async {
    final result = await LibCheckerRulesImporter.fromPortableZip(_zip());

    expect(result.dataVersion, 51);
    expect(result.sourceRevision, 'rev-51');
    // type 7（permission）不参与匹配，因此可用规则是 2 条。
    expect(result.ruleCount, 2);

    final bundle = result.bundle;
    final rules = (bundle['rules'] as List).cast<List<dynamic>>();
    expect(rules, hasLength(3));
    // 8 元组：id / name / label / type / iconId / simpleColor / detailIndex / priority
    expect(rules.first.take(5).toList(),
        [1, 'libdemo.so', 'Demo', 0, 'ic_lib_demo']);
    expect(bundle['regexIds'], [2]);

    final details = (bundle['details'] as List).cast<Map<String, dynamic>>();
    // 两条规则共用同一份详情：去重后只剩 1 份。
    expect(details, hasLength(1));
    expect(details.single.keys, containsAll(['zh-Hans', 'en']));
    expect(details.single['en'], [
      'Demo',
      'Vendor',
      'English description',
      'https://example.com/Demo',
      <String>[],
    ]);

    expect(result.icons.keys, ['ic_lib_demo']);
    expect(result.sha256, hasLength(64));
  });

  test('schemaVersion 不匹配时给出 schema 错误码，而不是把规则读成空', () async {
    await expectLater(
      LibCheckerRulesImporter.fromPortableZip(_zip(schemaVersion: 4)),
      throwsA(isA<LibCheckerImportException>()
          .having((e) => e.code, 'code', 'schema')),
    );
  });

  test('不是 zip / 没有规则时错误码可分辨', () async {
    await expectLater(
      LibCheckerRulesImporter.fromPortableZip(Uint8List.fromList([1, 2, 3])),
      throwsA(isA<LibCheckerImportException>()
          .having((e) => e.code, 'code', 'not_zip')),
    );
    await expectLater(
      LibCheckerRulesImporter.fromPortableZip(_zip(withRule: false)),
      throwsA(isA<LibCheckerImportException>()
          .having((e) => e.code, 'code', 'empty')),
    );
  });

  test('落盘后可被重新读出；clear 恢复内置语义', () async {
    final dir = await Directory.systemTemp.createTemp('libchecker_store');
    addTearDown(() async {
      LibCheckerRuleStore.debugDir = null;
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    LibCheckerRuleStore.debugDir = dir;

    final result = await LibCheckerRulesImporter.fromPortableZip(_zip());
    expect(LibCheckerRuleStore.hasOverride, isFalse);

    await LibCheckerRuleStore.save(result, fileName: 'portable-v5.zip');
    expect(LibCheckerRuleStore.hasOverride, isTrue);

    final rules = await LibCheckerRuleStore.loadRules();
    expect(rules, isNotNull);
    expect(rules!.dataVersion, 51);
    expect(rules.find(0, 'libdemo.so'), isNotNull);

    final icons = await LibCheckerRuleStore.loadIcons();
    expect(icons?['ic_lib_demo'], '<svg/>');

    final meta = await LibCheckerRuleStore.loadMeta();
    expect(meta?['dataVersion'], 51);
    expect(meta?['fileName'], 'portable-v5.zip');

    await LibCheckerRuleStore.clear();
    expect(LibCheckerRuleStore.hasOverride, isFalse);
    expect(await LibCheckerRuleStore.loadRules(), isNull);
  });

  // 用真实上游包做一次端到端校验（本机存在才跑，CI 上没有这个文件）。
  test('真实 portable-v5.zip 与内置资产口径一致', () async {
    final file = File('/tmp/libchecker/portable-v5.zip');
    if (!file.existsSync()) {
      markTestSkipped('缺少 /tmp/libchecker/portable-v5.zip');
      return;
    }
    final result =
        await LibCheckerRulesImporter.fromPortableZip(await file.readAsBytes());
    expect(result.dataVersion, 50);
    expect(result.bundle['rules'], hasLength(3053));
    expect(result.bundle['details'], hasLength(891));
    expect(result.icons, hasLength(197));
  });

  test('导入后 LibCheckerData 优先用导入包，恢复后回到内置', () async {
    final dir = await Directory.systemTemp.createTemp('libchecker_data');
    addTearDown(() async {
      LibCheckerRuleStore.debugDir = null;
      LibCheckerData.resetForTest();
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    LibCheckerRuleStore.debugDir = dir;
    LibCheckerData.resetForTest();

    final result = await LibCheckerRulesImporter.fromPortableZip(_zip());
    await LibCheckerRuleStore.save(result, fileName: 'portable-v5.zip');
    LibCheckerData.reload();

    final imported = await LibCheckerData.ensureLoaded();
    expect(imported.dataVersion, 51);
    expect(LibCheckerData.usingImportedRules, isTrue);
    expect(imported.find(0, 'libdemo.so'), isNotNull);

    await LibCheckerRuleStore.clear();
    LibCheckerData.reload();
    final builtin = await LibCheckerData.ensureLoaded();
    expect(builtin.dataVersion, 50);
    expect(LibCheckerData.usingImportedRules, isFalse);
  });
}
