import 'package:analysis_model/analysis_model.dart';
import 'package:test/test.dart';

void main() {
  group('ComponentPurl', () {
    test('maven 生成带命名空间与版本的 PURL', () {
      final purl = ComponentPurl.build(
        name: 'okhttp',
        namespace: 'com.squareup.okhttp3',
        version: '4.12.0',
        ecosystem: ComponentEcosystem.maven,
        platform: ComponentPlatform.android,
      );
      expect(purl,
          'pkg:maven/com.squareup.okhttp3/okhttp@4.12.0?platform=android');
    });

    test('没有版本时不输出 @，并保留 qualifier', () {
      final purl = ComponentPurl.build(
        name: 'AFNetworking',
        ecosystem: ComponentEcosystem.cocoapods,
        platform: ComponentPlatform.ios,
      );
      expect(purl, 'pkg:cocoapods/AFNetworking?platform=ios');
    });

    test('名称与版本里的特殊字符按 PURL 规则编码', () {
      final purl = ComponentPurl.build(
        name: 'Foo Bar@Baz',
        version: '1.0+meta',
        ecosystem: ComponentEcosystem.generic,
      );
      expect(purl, 'pkg:generic/Foo%20Bar%40Baz@1.0%2Bmeta');
    });

    test('名称为空或只有空白时返回 null', () {
      expect(
        ComponentPurl.build(name: '  ', ecosystem: ComponentEcosystem.generic),
        isNull,
      );
      expect(
        ComponentPurl.build(name: null, ecosystem: ComponentEcosystem.generic),
        isNull,
      );
    });

    test('qualifier 按键名排序，保证同一身份同一字符串', () {
      final a = ComponentPurl.build(
        name: 'x',
        ecosystem: ComponentEcosystem.generic,
        qualifiers: const {'z': '1', 'a': '2'},
      );
      final b = ComponentPurl.build(
        name: 'x',
        ecosystem: ComponentEcosystem.generic,
        qualifiers: const {'a': '2', 'z': '1'},
      );
      expect(a, b);
      expect(a, 'pkg:generic/x?a=2&z=1');
    });
  });

  group('Component', () {
    test('id 只由生态/平台/名称/版本决定，跨调用稳定', () {
      final a = Component.create(
        name: 'okhttp',
        ecosystem: ComponentEcosystem.maven,
        platform: ComponentPlatform.android,
        version: '4.12.0',
      );
      final b = Component.create(
        name: ' okhttp ',
        ecosystem: ComponentEcosystem.maven,
        platform: ComponentPlatform.android,
        version: '4.12.0',
      );
      expect(a.id, b.id);
      expect(a.id, startsWith('cmp_'));
      expect(a.id, hasLength(20));
    });

    test('版本不同则 id 不同，平台不同也不同', () {
      final base = Component.create(
        name: 'okhttp',
        ecosystem: ComponentEcosystem.maven,
        platform: ComponentPlatform.android,
        version: '4.12.0',
      );
      final otherVersion = Component.create(
        name: 'okhttp',
        ecosystem: ComponentEcosystem.maven,
        platform: ComponentPlatform.android,
        version: '4.11.0',
      );
      final otherPlatform = Component.create(
        name: 'okhttp',
        ecosystem: ComponentEcosystem.maven,
        platform: ComponentPlatform.ios,
        version: '4.12.0',
      );
      expect(base.id, isNot(otherVersion.id));
      expect(base.id, isNot(otherPlatform.id));
    });

    test('版本为空白时归一为 null，label 不出现 @', () {
      final component = Component.create(
        name: 'libfoo.so',
        ecosystem: ComponentEcosystem.generic,
        version: '   ',
      );
      expect(component.version, isNull);
      expect(component.label, 'libfoo.so');
      expect(component.purl, 'pkg:generic/libfoo.so');
    });

    test('sourceArtifacts 去重并排序，重复项不重复计入', () {
      final component = Component.create(
        name: 'libfoo.so',
        sourceArtifacts: const [
          'lib/arm64-v8a/libfoo.so',
          'lib/x86/libfoo.so',
          'lib/x86/libfoo.so',
          '  '
        ],
      );
      expect(component.sourceArtifacts,
          ['lib/arm64-v8a/libfoo.so', 'lib/x86/libfoo.so']);
    });

    test('toJson / fromJson 往返保留全部字段', () {
      final component = Component.create(
        name: 'okhttp',
        ecosystem: ComponentEcosystem.maven,
        platform: ComponentPlatform.android,
        version: '4.12.0',
        supplier: 'Square',
        licenses: const ['Apache-2.0'],
        hashes: const {'sha256': 'abcd'},
        sourceArtifacts: const ['classes.dex'],
        identification: ComponentIdentificationMethod.mavenPom,
        confidence: ComponentConfidence.high,
        sourceDatabaseVersion: 'libchecker-50',
        relations: const {
          ComponentRelationType.dependsOn: ['cmp_1234567890abcdef'],
        },
      );
      final restored = Component.fromJson(component.toJson());
      expect(restored.toJson(), component.toJson());
      expect(restored.identification, ComponentIdentificationMethod.mavenPom);
      expect(restored.confidence, ComponentConfidence.high);
      expect(restored.relations[ComponentRelationType.dependsOn],
          ['cmp_1234567890abcdef']);
    });

    test('fromJson 缺 id 时重算，未知关系类型被忽略', () {
      final restored = Component.fromJson(const {
        'name': 'libfoo.so',
        'ecosystem': 'generic',
        'platform': 'android',
        'relations': {
          'madeUpRelation': ['cmp_x']
        },
      });
      expect(restored.id, startsWith('cmp_'));
      expect(restored.relations, isEmpty);
    });

    test('fromJson 缺少 name 时抛可读异常', () {
      expect(
        () => Component.fromJson(const {'name': '  '}),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
