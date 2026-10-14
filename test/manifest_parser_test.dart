// AndroidManifest 组件与 SDK 字段提取的单元测试。
//
// 绝大多数用例直接构造 `XmlDocument` 文档树，而不是手工拼二进制 AXML —— 后者
// 极易写错，写错的样本测的是「损坏输入」而不是目标逻辑。为此
// `ManifestParser` 被拆成 `parse(bytes)`（反编译 + 提取）与
// `fromDocument(doc)`（纯提取），那些用例测的是后者。
//
// 例外是最后一组「真实加固 APK 的清单」：那里必须走完整的 `parse(bytes)`，
// 因为被测的正是**二进制层**的偏移处理。样本是从真实加固 APK 里提取的
// 36240 字节 AXML（见 test/fixtures/apk/README.md）。

import 'dart:io';

import 'package:apk_parser/apk_parser.dart';
import 'package:flutter_test/flutter_test.dart';

XmlElement _el(String name, [Map<String, String> attrs = const {}]) =>
    XmlElement()
      ..name = name
      ..attributes = Map.of(attrs);

XmlElement _app(List<XmlElement> children,
    [Map<String, String> attrs = const {}]) {
  final app = _el('application', attrs);
  app.children.addAll(children);
  return app;
}

XmlDocument _doc(List<XmlElement> manifestChildren) {
  final manifest = _el('manifest', {
    'package': 'com.example.app',
    'versionCode': '7',
    'versionName': '1.2.3',
  });
  manifest.children.addAll(manifestChildren);
  return XmlDocument()..children.add(manifest);
}

/// 带 MAIN + LAUNCHER intent-filter 的 activity。
XmlElement _launcherActivity(String name) {
  final intentFilter = _el('intent-filter')
    ..children.addAll([
      _el('action', {'name': 'android.intent.action.MAIN'}),
      _el('category', {'name': 'android.intent.category.LAUNCHER'}),
    ]);
  final activity = _el('activity', {'name': name});
  activity.children.add(intentFilter);
  return activity;
}

void main() {
  group('ManifestParser.fromDocument — SDK 版本', () {
    test('min / target / maxSdkVersion 都被解析', () {
      final meta = ManifestParser.fromDocument(_doc([
        _el('uses-sdk', {
          'minSdkVersion': '21',
          'targetSdkVersion': '34',
          'maxSdkVersion': '35',
        }),
      ]));

      expect(meta.minSdkVersion, 21);
      expect(meta.targetSdkVersion, 34);
      expect(meta.maxSdkVersion, 35);
    });

    test('未声明 maxSdkVersion 时为 null，不默认成某个值', () {
      final meta = ManifestParser.fromDocument(_doc([
        _el('uses-sdk', {'minSdkVersion': '21', 'targetSdkVersion': '34'}),
      ]));

      expect(meta.maxSdkVersion, isNull);
    });
  });

  group('ManifestParser.fromDocument — application 属性', () {
    test('debuggable 显式 true / false 都能解析', () {
      expect(
        ManifestParser.fromDocument(_doc([
          _app([], {'debuggable': 'true'})
        ])).applicationDebuggable,
        isTrue,
      );
      expect(
        ManifestParser.fromDocument(_doc([
          _app([], {'debuggable': 'false'})
        ])).applicationDebuggable,
        isFalse,
      );
    });

    test('debuggable 未声明时为 null，不默认成 false', () {
      final meta = ManifestParser.fromDocument(_doc([_app([])]));
      expect(meta.applicationDebuggable, isNull);
    });

    test('debuggable 的十六进制形式同样识别', () {
      expect(
        ManifestParser.fromDocument(_doc([
          _app([], {'debuggable': '0xffffffff'})
        ])).applicationDebuggable,
        isTrue,
      );
    });
  });

  group('ManifestParser.fromDocument — 组件提取', () {
    test('四类组件都被收集，类型正确', () {
      final meta = ManifestParser.fromDocument(_doc([
        _app([
          _el('activity', {'name': 'com.example.app.MainActivity'}),
          _el('activity-alias', {'name': 'com.example.app.Alias'}),
          _el('service', {'name': 'com.example.app.SyncService'}),
          _el('receiver', {'name': 'com.example.app.BootReceiver'}),
          _el('provider', {'name': 'com.example.app.DataProvider'}),
        ]),
      ]));

      expect(meta.components, hasLength(5));
      expect(
        meta.components.map((c) => c.type).toList(),
        [
          ComponentType.activity,
          ComponentType.activityAlias,
          ComponentType.service,
          ComponentType.receiver,
          ComponentType.provider,
        ],
      );
      expect(
        meta.components.map((c) => c.name).toList(),
        [
          'com.example.app.MainActivity',
          'com.example.app.Alias',
          'com.example.app.SyncService',
          'com.example.app.BootReceiver',
          'com.example.app.DataProvider',
        ],
      );
    });

    test('非组件子元素不会被当成组件', () {
      final meta = ManifestParser.fromDocument(_doc([
        _app([
          _el('meta-data', {'name': 'x', 'value': 'y'}),
          _el('uses-library', {'name': 'org.apache.http.legacy'}),
          _el('activity', {'name': 'com.example.app.MainActivity'}),
        ]),
      ]));

      expect(meta.components, hasLength(1));
      expect(meta.components.single.type, ComponentType.activity);
    });

    test('exported 是三态：true / false / 未声明(null)', () {
      final meta = ManifestParser.fromDocument(_doc([
        _app([
          _el('activity', {'name': 'a.Exported', 'exported': 'true'}),
          _el('activity', {'name': 'a.NotExported', 'exported': 'false'}),
          _el('activity', {'name': 'a.Unspecified'}),
        ]),
      ]));

      expect(meta.components[0].exported, isTrue);
      expect(meta.components[1].exported, isFalse);
      expect(meta.components[2].exported, isNull);
    });

    test('effectivelyExported 按平台默认规则推导，且显式声明优先', () {
      final meta = ManifestParser.fromDocument(_doc([
        _app([
          // 未声明 exported + 有 intent-filter -> 默认导出
          _el('activity', {'name': 'a.Implied'})
            ..children.add(_el('intent-filter', {'action': 'x'})),
          // 未声明 exported + 无 intent-filter -> 默认不导出
          _el('service', {'name': 'a.Implicit'}),
          // 显式 false 覆盖 intent-filter 的默认值
          _el('activity', {'name': 'a.ExplicitFalse', 'exported': 'false'})
            ..children.add(_el('intent-filter', {'action': 'x'})),
        ]),
      ]));

      expect(meta.components[0].exported, isNull);
      expect(meta.components[0].effectivelyExported, isTrue);
      expect(meta.components[1].exported, isNull);
      expect(meta.components[1].effectivelyExported, isFalse);
      expect(meta.components[2].exported, isFalse);
      expect(meta.components[2].effectivelyExported, isFalse);
    });

    test('permission 与 provider 的 authorities 被保留', () {
      final meta = ManifestParser.fromDocument(_doc([
        _app([
          _el('service', {
            'name': 'com.example.app.GuardedService',
            'permission': 'com.example.app.permission.INTERNAL',
          }),
          _el('provider', {
            'name': 'com.example.app.DataProvider',
            'authorities': 'com.example.app.provider',
          }),
        ]),
      ]));

      expect(
          meta.components[0].permission, 'com.example.app.permission.INTERNAL');
      expect(meta.components[1].authorities, 'com.example.app.provider');
    });

    test('hasIntentFilter 正确反映子元素', () {
      final meta = ManifestParser.fromDocument(_doc([
        _app([
          _el('activity', {'name': 'a.WithFilter'})
            ..children.add(_el('intent-filter', {'action': 'x'})),
          _el('activity', {'name': 'a.WithoutFilter'}),
        ]),
      ]));

      expect(meta.components[0].hasIntentFilter, isTrue);
      expect(meta.components[1].hasIntentFilter, isFalse);
    });
  });

  group('ManifestParser.fromDocument — 回归：启动 Activity', () {
    test('含 MAIN + LAUNCHER 的 activity 仍被识别为可启动', () {
      final meta = ManifestParser.fromDocument(_doc([
        _app([_launcherActivity('com.example.app.MainActivity')]),
      ]));

      expect(meta.launchableActivities, hasLength(1));
      expect(meta.launchableActivities.single.name,
          'com.example.app.MainActivity');
      // 同时也要出现在组件列表里
      expect(meta.components.single.type, ComponentType.activity);
    });

    test('只有 MAIN 没有 LAUNCHER 的不算可启动', () {
      final intentFilter = _el('intent-filter')
        ..children.add(_el('action', {'name': 'android.intent.action.MAIN'}));
      final activity = _el('activity', {'name': 'a.NotLaunchable'})
        ..children.add(intentFilter);

      final meta = ManifestParser.fromDocument(_doc([
        _app([activity])
      ]));

      expect(meta.launchableActivities, isEmpty);
      expect(meta.components, hasLength(1));
    });
  });

  group('ManifestParser.fromDocument — 混淆 manifest 的取舍', () {
    test('activity 缺 name 时走启发式', () {
      // 属性值里出现类名形态的字符串，启发式应取到它。
      final activity =
          _el('activity', {'label': 'com.example.app.HiddenActivity'});

      final meta = ManifestParser.fromDocument(_doc([
        _app([activity])
      ]));

      expect(meta.components.single.name, 'com.example.app.HiddenActivity');
    });

    test('service 缺 name 时保持 null，不从 permission 里猜', () {
      // 这是刻意的取舍：对非 activity 组件做启发式，很容易把
      // android:permission 的值当成组件名，那等于编造数据。
      final service = _el('service', {
        'permission': 'com.example.app.permission.BIND',
      });

      final meta = ManifestParser.fromDocument(_doc([
        _app([service])
      ]));

      expect(meta.components.single.type, ComponentType.service);
      expect(meta.components.single.name, isNull);
      expect(
          meta.components.single.permission, 'com.example.app.permission.BIND');
    });
  });

  group('ManifestParser.fromDocument — 边界', () {
    test('没有 <manifest> 时返回空结果而不是抛异常', () {
      final meta = ManifestParser.fromDocument(XmlDocument());
      expect(meta.packageName, isNull);
      expect(meta.components, isEmpty);
    });

    test('没有 <application> 时组件列表为空', () {
      final meta = ManifestParser.fromDocument(_doc([]));
      expect(meta.packageName, 'com.example.app');
      expect(meta.components, isEmpty);
      expect(meta.launchableActivities, isEmpty);
    });
  });

  group('ManifestParser — 真实加固 APK 的清单', () {
    // 样本是**真实**加固 APK 里的 AndroidManifest.xml，见
    // test/fixtures/apk/README.md。期望值来自一份独立写的 Python 解码器
    // （直接按 ResourceTypes.h 的布局读），不是从本项目的解析器拿的。
    //
    // 这份清单的关键特征是：`attributeStart` 被放大（`<manifest>` 是 181，
    // 标准是 20），头与真正的属性之间塞了 161 字节诱饵。忽略 attributeStart
    // 的解析器会读到诱饵 —— 表现恰好是「组件名读得对、基本信息全空」。
    late final ApkMeta meta;

    setUpAll(() {
      final file = File('test/fixtures/apk/hardened-manifest.axml');
      expect(file.existsSync(), isTrue,
          reason: '缺少样本 —— 见 test/fixtures/apk/README.md');
      meta = ManifestParser.parse(file.readAsBytesSync());
    });

    test('放大 attributeStart 之后仍能读出 <manifest> 的属性', () {
      expect(meta.packageName, 'com.QOCrchtmmAzhekiE.HVkokqyMaKAafvaY');
      expect(meta.versionCode, 1);
      expect(meta.versionName, '8.5.5');
      expect(meta.compileSdkVersion, 36);
    });

    test('放大 attributeStart 之后仍能读出 <uses-sdk>', () {
      expect(meta.minSdkVersion, 24);
      expect(meta.targetSdkVersion, 34);
      // 该包没有声明 maxSdkVersion —— 这是「文件里没有」，不是「没读到」。
      expect(meta.maxSdkVersion, isNull);
    });

    test('仍能读出 <application> 的属性', () {
      expect(meta.label, '杏⟠⎗吧');
      expect(meta.applicationIcon, '@res/0x7f0f0007');
      expect(meta.applicationName,
          'com.QOCrchtmmAzhekiE.HVkokqyMaKAafvaY.qupsCHDDcKMNzULd');
    });

    test('仍能读出全部 uses-permission', () {
      expect(meta.permissions, hasLength(40));
      expect(meta.permissions, contains('android.permission.INTERNET'));
      expect(meta.permissions, contains('android.permission.CAMERA'));
      expect(meta.permissions,
          contains('android.permission.MANAGE_EXTERNAL_STORAGE'));
    });

    test('组件与权限是两件独立的事，不互相污染', () {
      expect(meta.components, hasLength(22));
      final names = meta.components.map((c) => c.name).whereType<String>();
      expect(names,
          contains('com.QOCrchtmmAzhekiE.HVkokqyMaKAafvaY.MainActivity'));
      // 组件名不该混进权限列表，反之亦然。
      expect(
          meta.permissions,
          isNot(
              contains('com.QOCrchtmmAzhekiE.HVkokqyMaKAafvaY.MainActivity')));
    });
  });

  group('ManifestParser — 非标准 AXML 布局的识别', () {
    // 「读不出来」与「有人不想让我们读出来」是两件事。前者是我们的缺陷，
    // 后者是关于这个包的事实 —— 必须能分开。
    late final ApkMeta hardened;
    late final ApkMeta standard;

    setUpAll(() {
      hardened = ManifestParser.parse(
          File('test/fixtures/apk/hardened-manifest.axml').readAsBytesSync());
      standard = ManifestParser.parse(
          File('test/fixtures/apk/standard-manifest.axml').readAsBytesSync());
    });

    test('真实加固清单报出 4 类布局事实', () {
      expect(hardened.manifestLayoutAnomalies, hasLength(4));
    });

    test('放大 attributeStart 被识别，并指出最大的那个元素', () {
      final line = hardened.manifestLayoutAnomalies
          .firstWhere((l) => l.contains('attributeStart'));

      expect(line, contains('49 elements'));
      // 最大的那个在 <application> 上，值是 281 —— 指出具体位置才有排查价值。
      expect(line, contains('281'));
      expect(line, contains('<application>'));
      expect(line, contains('standard value is 20'));
    });

    test('放大 attributeSize 被识别', () {
      final line = hardened.manifestLayoutAnomalies
          .firstWhere((l) => l.contains('attributeSize'));

      expect(line, contains('127 elements'));
      expect(line, contains('26'));
    });

    test('非标准尺寸的命名空间 chunk 被识别', () {
      final line = hardened.manifestLayoutAnomalies
          .firstWhere((l) => l.contains('namespace chunk'));

      expect(line, contains('1220'));
      expect(line, contains('standard size is 24'));
    });

    test('标准范围之外的 chunk 类型被识别', () {
      final line = hardened.manifestLayoutAnomalies
          .firstWhere((l) => l.contains('chunk type'));

      expect(line, contains('0x0200'));
    });

    test('标准布局的清单一条都不报（防误报）', () {
      // 反向验证：如果检测把正常文件也报成加固样本，这条会失败。
      expect(standard.manifestLayoutAnomalies, isEmpty);
    });

    test('布局异常不影响字段提取结果', () {
      // 两份文件的布局一个标准一个不标准，但该读到的字段都要读到。
      expect(hardened.packageName, 'com.QOCrchtmmAzhekiE.HVkokqyMaKAafvaY');
      expect(hardened.versionName, '8.5.5');
      expect(hardened.minSdkVersion, 24);
    });
  });

  group('组件的 enabled 与 intent-filter 明细（阶段 2）', () {
    test('enabled 三态：显式 true / 显式 false / 未声明', () {
      final doc = _doc([
        _app([
          _el('activity', {'name': 'A', 'enabled': 'true'}),
          _el('activity', {'name': 'B', 'enabled': 'false'}),
          _el('activity', {'name': 'C'}),
        ]),
      ]);

      final meta = ManifestParser.fromDocument(doc);
      final byName = {for (final c in meta.components) c.name: c};

      expect(byName['A']!.enabled, isTrue);
      expect(byName['B']!.enabled, isFalse);
      expect(
        byName['C']!.enabled,
        isNull,
        reason: '「未声明」必须保留 null —— 它与「显式写了 true」是两件事',
      );
      expect(byName['C']!.effectivelyEnabled, isTrue, reason: '平台默认为启用');
    });

    test('解析 intent-filter 的 action / category / scheme', () {
      final filter = _el('intent-filter');
      filter.children.addAll([
        _el('action', {'name': 'android.intent.action.VIEW'}),
        _el('category', {'name': 'android.intent.category.DEFAULT'}),
        _el('category', {'name': 'android.intent.category.BROWSABLE'}),
        // host 刻意留着 —— 实现应当忽略它，只取 scheme。
        _el('data', {'scheme': 'https', 'host': 'example.com'}),
        _el('data', {'scheme': 'myapp'}),
      ]);
      final activity = _el('activity', {'name': 'A'});
      activity.children.add(filter);

      final doc = _doc([
        _app([activity]),
      ]);
      final meta = ManifestParser.fromDocument(doc);
      final component = meta.components.single;

      expect(component.intentFilters, hasLength(1));
      final info = component.intentFilters.single;
      expect(info.actions, ['android.intent.action.VIEW']);
      expect(info.categories, contains('android.intent.category.BROWSABLE'));
      expect(info.schemes, ['https', 'myapp']);
      expect(component.declaredSchemes, ['https', 'myapp']);
      expect(component.hasIntentFilter, isTrue);
    });

    test('多个 intent-filter 分别保留', () {
      final f1 = _el('intent-filter')
        ..children.add(_el('action', {'name': 'A1'}));
      final f2 = _el('intent-filter')
        ..children.add(_el('action', {'name': 'A2'}));
      final activity = _el('activity', {'name': 'A'})
        ..children.addAll([f1, f2]);

      final doc = _doc([
        _app([activity]),
      ]);
      final meta = ManifestParser.fromDocument(doc);

      expect(meta.components.single.intentFilters, hasLength(2));
      expect(
        meta.components.single.intentFilters.map((f) => f.actions.single),
        ['A1', 'A2'],
      );
    });

    test('没有 filter 时明细为空，且不误报 hasIntentFilter', () {
      final doc = _doc([
        _app([
          _el('service', {'name': 'S'})
        ]),
      ]);
      final meta = ManifestParser.fromDocument(doc);
      final component = meta.components.single;

      expect(component.intentFilters, isEmpty);
      expect(component.declaredSchemes, isEmpty);
      expect(component.hasIntentFilter, isFalse);
    });
  });
}
