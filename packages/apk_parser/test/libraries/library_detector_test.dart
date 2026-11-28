import 'package:apk_parser/apk_parser.dart';
import 'package:test/test.dart';

void main() {
  LibCheckerRules rules() => LibCheckerRules.fromBundle({
        'meta': {'dataVersion': 99, 'sourceRevision': 'test'},
        'rules': [
          [1, 'libflutter.so', 'Flutter', 0, 'ic_flutter', 0, -1, 1],
          [2, 'libapp.so', 'Flutter', 0, 'ic_flutter', 0, -1, 2],
          [3, 'libjiagu.so', 'Jiagu', 0, 'ic_jiagu', 0, -1, 3],
          [4, 'libunity.so', 'Unity', 0, 'ic_unity', 0, -1, 4],
          [5, 'libmain.so', 'Unity', 0, 'ic_unity', 0, -1, 5],
          [10, 'com.foo.SdkActivity', 'Foo SDK', 2, 'ic_foo', 0, -1, 10],
          [11, 'com.foo.SdkService', 'Foo SDK', 1, 'ic_foo', 0, -1, 11],
          [12, 'com.foo.ACTION_SHOW', 'Foo Action', 9, 'ic_action', 0, -1, 12],
          [20, 'com.squareup.okhttp3', 'OkHttp', 5, 'ic_okhttp', 0, -1, 20],
          [21, r'com\.regex\..*', 'Regex Lib', 5, 'ic_regex', 0, -1, 21],
          [30, 'org.example.share', 'Flutter', 5, 'ic_flutter', 0, -1, 30],
        ],
        'regexIds': [21],
        'details': const [],
      });

  NativeLibraryEntry lib(String abi, String name, {int size = 100}) =>
      NativeLibraryEntry(
        abi: abi,
        name: name,
        path: 'lib/$abi/$name',
        size: size,
      );

  AndroidComponent component(
    ComponentType type,
    String? name, {
    List<String> actions = const [],
  }) =>
      AndroidComponent(
        type: type,
        name: name,
        hasIntentFilter: actions.isNotEmpty,
        intentFilters: [
          if (actions.isNotEmpty) IntentFilterInfo(actions: actions)
        ],
      );

  LibraryReport run({
    List<NativeLibraryEntry> libs = const [],
    List<AndroidComponent> components = const [],
    DexLibrarySignals dex = DexLibrarySignals.empty,
    Set<String> entries = const {},
  }) =>
      LibraryDetector.detect(
        rules: rules(),
        packageName: 'com.foo',
        nativeLibraries: libs,
        components: components,
        dex: dex,
        archiveEntries: entries,
      );

  DexLibrarySignals signals({
    Set<String> packages = const {},
    int classCount = 1,
    bool kotlinMetadata = false,
    bool flutterInjector = false,
    bool qihoo = false,
    bool secneo = false,
    bool compose = false,
  }) =>
      DexLibrarySignals(
        packages: packages,
        classCount: classCount,
        truncated: false,
        kotlinMetadata: kotlinMetadata,
        kotlinClasses: false,
        composeClasses: compose,
        flutterInjector: flutterInjector,
        qihooShell: qihoo,
        secneoShell: secneo,
      );

  group('原生库', () {
    test('同一 .so 的多 ABI 合并为一条命中，体积相加', () {
      final report = run(libs: [
        lib('arm64-v8a', 'libflutter.so', size: 1000),
        lib('armeabi-v7a', 'libflutter.so', size: 600),
      ]);
      expect(report.nativeGroups, hasLength(1));
      final hit = report.nativeGroups.single.hits.single;
      expect(hit.name, 'libflutter.so');
      expect(hit.abis, ['arm64-v8a', 'armeabi-v7a']);
      expect(hit.size, 1600);
      expect(report.nativeGroups.single.count, 1);
      expect(report.unmatchedNative, isEmpty);
    });

    test('libapp.so 缺 libflutter.so 与 FlutterInjector 时不认 Flutter', () {
      final report = run(libs: [lib('arm64-v8a', 'libapp.so')]);
      expect(report.nativeGroups, isEmpty);
      expect(report.unmatchedNative.map((l) => l.name), ['libapp.so']);
    });

    test('libapp.so 有 libflutter.so 旁证时命中', () {
      final report = run(libs: [
        lib('arm64-v8a', 'libapp.so'),
        lib('arm64-v8a', 'libflutter.so'),
      ]);
      expect(report.nativeGroups.single.label, 'Flutter');
      expect(report.nativeGroups.single.hits.map((h) => h.name).toSet(),
          {'libapp.so', 'libflutter.so'});
    });

    test('libjiagu.so 需要 DEX 壳类旁证', () {
      expect(run(libs: [lib('x86', 'libjiagu.so')]).nativeGroups, isEmpty);
      final report = run(
        libs: [lib('x86', 'libjiagu.so')],
        dex: signals(qihoo: true),
      );
      expect(report.nativeGroups.single.label, 'Jiagu');
    });

    test('未识别原生库按体积降序', () {
      final report = run(libs: [
        lib('arm64-v8a', 'libsmall.so', size: 10),
        lib('arm64-v8a', 'libbig.so', size: 900),
      ]);
      expect(report.unmatchedNative.map((l) => l.name),
          ['libbig.so', 'libsmall.so']);
    });
  });

  group('组件', () {
    test('组件名按包名补全后精确匹配', () {
      final report = run(components: [
        component(ComponentType.activity, '.SdkActivity'),
        component(ComponentType.service, 'SdkService'),
      ]);
      expect(report.componentGroups, hasLength(1));
      final group = report.componentGroups.single;
      expect(group.label, 'Foo SDK');
      expect(group.hits.map((h) => h.name),
          ['com.foo.SdkActivity', 'com.foo.SdkService']);
      expect(group.hits.every((h) => h.source == LibraryMatchSource.exact),
          isTrue);
    });

    test('组件名匹配不上时走 intent-filter action（只精确）', () {
      final report = run(components: [
        component(ComponentType.activity, 'com.unknown.Thing',
            actions: ['com.foo.ACTION_SHOW']),
      ]);
      final group = report.componentGroups.single;
      expect(group.label, 'Foo Action');
      expect(group.hits.single.source, LibraryMatchSource.action);
    });

    test('缺失组件名不参与匹配', () {
      final report = run(components: [component(ComponentType.activity, null)]);
      expect(report.componentGroups, isEmpty);
    });
  });

  group('DEX', () {
    test('包名前缀取最长上级，正则只兜底', () {
      final report = run(
        dex: signals(packages: {
          'com.squareup.okhttp3.internal',
          'com.regex.app',
          'com.other',
        }),
      );
      final labels = report.dexGroups.map((g) => g.label).toList();
      expect(labels, ['OkHttp', 'Regex Lib']);
      expect(report.dexGroups.first.hits.single.name,
          'com.squareup.okhttp3.internal');
      expect(
          report.dexGroups.last.hits.single.source, LibraryMatchSource.regex);
    });

    test('DEX 包名升序输出', () {
      final report = run(
        dex: signals(packages: {'z.pkg', 'a.pkg', 'm.pkg'}),
      );
      expect(report.dexPackages, ['a.pkg', 'm.pkg', 'z.pkg']);
    });
  });

  group('分组与标记', () {
    test('SDK 数按 label + iconId 去重', () {
      final report = run(
        libs: [lib('arm64-v8a', 'libflutter.so')],
        components: [component(ComponentType.activity, '.SdkActivity')],
        dex: signals(packages: {'org.example.share'}),
      );
      // Flutter（原生 + DEX 同一图标）算一个，Foo SDK 一个。
      expect(report.sdkCount, 2);
    });

    test('组按命中数降序、label 升序', () {
      final report = run(
        dex: signals(
            packages: {'com.squareup.okhttp3', 'com.regex.a', 'com.regex.b'}),
      );
      expect(report.dexGroups.first.label, 'Regex Lib');
      expect(report.dexGroups.first.count, 2);
      expect(report.dexGroups.last.label, 'OkHttp');
    });

    test('Kotlin / Compose 标记来自 DEX 或打包元数据', () {
      expect(run(dex: signals(kotlinMetadata: true)).kotlin, isTrue);
      expect(run(entries: {'META-INF/main.kotlin_module'}).kotlin, isTrue);
      expect(run(entries: {'kotlin-tooling-metadata.json'}).kotlin, isTrue);
      expect(run(dex: signals(compose: true)).compose, isTrue);
      expect(run(entries: {'META-INF/androidx.compose.ui_ui.version'}).compose,
          isTrue);
      expect(run().kotlin, isFalse);
    });

    test('没扫到 DEX 时 dexScanned 为 false', () {
      expect(run().dexScanned, isFalse);
      expect(run(dex: signals(packages: {'a.b'})).dexScanned, isTrue);
    });
  });
}
