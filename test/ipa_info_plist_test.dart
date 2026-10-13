// Info.plist 字段提取测试（规范 5.2）。
//
// 样本同样是 macOS `plutil -convert binary1` 的真实产物（内嵌 base64），
// 并与等价的 XML 交叉比对 —— 手工拼的样本只会重复解析器的错误假设。

import 'dart:convert';

import 'package:analysis_model/analysis_model.dart';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ipa_parser/ipa_parser.dart';

/// 与下面 XML 等价的二进制 Info.plist，由 `plutil -convert binary1` 生成。
const String _binaryInfoPlistBase64 =
    'YnBsaXN0MDDcAQIDBAUGBwgJCgsMDQ4PEiANISUmJyotXENGQnVuZGxlTmFtZV8QEkNGQnVuZGxlSWRlbnRpZmllcl8QHFVJ'
    'UmVxdWlyZWREZXZpY2VDYXBhYmlsaXRpZXNdQ0ZCdW5kbGVJY29uc18QD0NGQnVuZGxlVmVyc2lvbl8QEkNGQnVuZGxlRXhl'
    'Y3V0YWJsZV8QEkNGQnVuZGxlSWNvbnN+aXBhZF8QE0NGQnVuZGxlRGlzcGxheU5hbWVfEBBNaW5pbXVtT1NWZXJzaW9uXlVJ'
    'RGV2aWNlRmFtaWx5XxAbTFNBcHBsaWNhdGlvblF1ZXJpZXNTY2hlbWVzXxAaQ0ZCdW5kbGVTaG9ydFZlcnNpb25TdHJpbmdX'
    'RXhhbXBsZV8QD2NvbS5leGFtcGxlLmFwcKIQEVVhcm02NFVtZXRhbNITFBUbXxATQ0ZCdW5kbGVQcmltYXJ5SWNvbl8QFkNG'
    'QnVuZGxlQWx0ZXJuYXRlSWNvbnPSFhcYGl8QEUNGQnVuZGxlSWNvbkZpbGVzXxAQQ0ZCdW5kbGVJY29uTmFtZaEZXEFwcElj'
    'b242MHg2MFdBcHBJY29u0RwdVERhcmvRFh6hH1tBcHBJY29uRGFyaxDx0RMi0RYjoSRcQXBwSWNvbjc2eDc2ZHk6T4telHUo'
    'VDE2LjCiKCkQARACoissVndlaXhpblZhbGlwYXlVMi40LjEACAAhAC4AQwBiAHAAggCXAKwAwgDVAOQBAgEfAScBOQE8AUIB'
    'SAFNAWMBfAGBAZUBqAGqAbcBvwHCAccBygHMAdgB2gHdAeAB4gHvAfgB/QIAAgICBAIHAg4CFQAAAAAAAAIBAAAAAAAAAC4A'
    'AAAAAAAAAAAAAAAAAAIb';

/// 覆盖全部待提取字段的 XML 样本。
const String _xmlInfoPlist = '''
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDisplayName</key>
	<string>示例应用</string>
	<key>CFBundleName</key>
	<string>Example</string>
	<key>CFBundleIdentifier</key>
	<string>com.example.app</string>
	<key>CFBundleShortVersionString</key>
	<string>2.4.1</string>
	<key>CFBundleVersion</key>
	<integer>241</integer>
	<key>CFBundleExecutable</key>
	<string>Example</string>
	<key>MinimumOSVersion</key>
	<string>16.0</string>
	<key>UIDeviceFamily</key>
	<array>
		<integer>1</integer>
		<integer>2</integer>
	</array>
	<key>LSApplicationQueriesSchemes</key>
	<array>
		<string>weixin</string>
		<string>alipay</string>
	</array>
	<key>UIRequiredDeviceCapabilities</key>
	<array>
		<string>arm64</string>
		<string>metal</string>
	</array>
	<key>CFBundleIcons</key>
	<dict>
		<key>CFBundlePrimaryIcon</key>
		<dict>
			<key>CFBundleIconFiles</key>
			<array>
				<string>AppIcon60x60</string>
			</array>
			<key>CFBundleIconName</key>
			<string>AppIcon</string>
		</dict>
		<key>CFBundleAlternateIcons</key>
		<dict>
			<key>Dark</key>
			<dict>
				<key>CFBundleIconFiles</key>
				<array>
					<string>AppIconDark</string>
				</array>
			</dict>
		</dict>
	</dict>
	<key>CFBundleIcons~ipad</key>
	<dict>
		<key>CFBundlePrimaryIcon</key>
		<dict>
			<key>CFBundleIconFiles</key>
			<array>
				<string>AppIcon76x76</string>
			</array>
		</dict>
	</dict>
</dict>
</plist>
''';

ArchiveFile _file(String name, List<int> bytes) =>
    ArchiveFile(name, bytes.length, bytes);

/// 构造一个只含 Info.plist 的最小 IPA 归档。
Archive _ipaWith(List<int> infoPlistBytes) => Archive()
  ..addFile(_file('Payload/MyApp.app/Info.plist', infoPlistBytes))
  ..addFile(_file('Payload/MyApp.app/MyApp', List.filled(16, 0)));

IpaInfoPlist _read(List<int> infoPlistBytes) {
  final archive = _ipaWith(infoPlistBytes);
  final container = IpaContainerReader.read(archive);
  return IpaInfoPlistReader.read(archive, container.mainApp!);
}

/// 断言两种编码提取出**同样**的字段值。
void _expectExtractedFields(IpaInfoPlist info, String label) {
  expect(info.bundleIdentifier.value, 'com.example.app', reason: label);
  expect(info.bundleIdentifier.status, FieldStatus.extracted);
  expect(info.bundleIdentifier.source, FieldSource.infoPlist);

  expect(info.displayName.value, '示例应用', reason: label);
  expect(info.bundleName.value, 'Example');
  expect(info.shortVersionString.value, '2.4.1');
  // 样本里 CFBundleVersion 是 <integer>，按设计接受并转成字符串
  expect(info.bundleVersion.value, '241');
  expect(info.bundleVersion.status, FieldStatus.extracted);
  expect(info.executable.value, 'Example');
  expect(info.minimumOSVersion.value, '16.0');

  expect(info.deviceFamily.value, [1, 2]);
  expect(info.queriesSchemes.value, ['weixin', 'alipay']);
  expect(info.requiredDeviceCapabilities.value, ['arm64', 'metal']);

  expect(info.hasAnyValue, isTrue);
}

void main() {
  group('IpaInfoPlistReader — XML 样本', () {
    test('全部字段都被提取，且来源标注为 infoPlist', () {
      _expectExtractedFields(
        _read(utf8.encode(_xmlInfoPlist)),
        'xml',
      );
    });

    test('图标配置：主图标 / 备用图标 / iPad / 名称', () {
      final icons = _read(utf8.encode(_xmlInfoPlist)).icons;

      expect(icons.status, FieldStatus.extracted);
      final config = icons.value!;
      expect(config.primary!.iconFiles, ['AppIcon60x60']);
      expect(config.primary!.iconName, 'AppIcon');
      expect(config.alternate.keys, ['Dark']);
      expect(config.alternate['Dark']!.iconFiles, ['AppIconDark']);
      expect(config.primaryIpad!.iconFiles, ['AppIcon76x76']);
      expect(config.isEmpty, isFalse);
    });

    test('解析成功会留下一条诊断，说明读到了多少键', () {
      final info = _read(utf8.encode(_xmlInfoPlist));

      expect(info.diagnostics, hasLength(1));
      expect(info.diagnostics.single.code, 'ios.info_plist.parsed');
      expect(info.diagnostics.single.severity, DiagnosticSeverity.info);
    });
  });

  group('IpaInfoPlistReader — 二进制样本（plutil 生成）', () {
    test('与等价 XML 提取出同样的字段', () {
      final bytes = base64.decode(_binaryInfoPlistBase64);
      expect(bytes.sublist(0, 8), 'bplist00'.codeUnits);

      _expectExtractedFields(_read(bytes), 'binary');
    });

    test('图标配置同样完整', () {
      final config = _read(base64.decode(_binaryInfoPlistBase64)).icons.value!;

      expect(config.primary!.iconName, 'AppIcon');
      expect(config.alternate, hasLength(1));
      expect(config.primaryIpad!.iconFiles, ['AppIcon76x76']);
    });
  });

  group('IpaInfoPlistReader — 缺失与不可解析', () {
    test('没有 Info.plist 时全部字段记为 absent，并附警告', () {
      final archive = Archive()..addFile(_file('Payload/A.app/A', [1]));
      final bundle = IpaContainerReader.read(archive).mainApp!;

      final info = IpaInfoPlistReader.read(archive, bundle);

      expect(info.bundleIdentifier.status, FieldStatus.absent);
      expect(info.bundleIdentifier.hasValue, isFalse);
      expect(info.hasAnyValue, isFalse);
      expect(info.diagnostics.single.severity, DiagnosticSeverity.warning);
      expect(info.diagnostics.single.code, 'ios.info_plist.missing');
    });

    test('文件存在但解析不了时记为 failed，而不是 absent', () {
      final info = _read(utf8.encode('this is not a plist'));

      expect(info.bundleIdentifier.status, FieldStatus.failed,
          reason: '「读不出来」与「文件里没有」必须分开');
      expect(info.bundleIdentifier.status, isNot(FieldStatus.absent));
      expect(info.bundleIdentifier.diagnostic, isNotNull);
      expect(info.diagnostics.single.code, 'ios.info_plist.unparsable');
      expect(info.hasAnyValue, isFalse);
    });

    test('根不是字典时同样记为 failed', () {
      final info =
          _read(utf8.encode('<?xml version="1.0"?><plist version="1.0">'
              '<array><string>x</string></array></plist>'));

      expect(info.bundleIdentifier.status, FieldStatus.failed);
      expect(info.diagnostics.single.code, 'ios.info_plist.not_a_dict');
    });

    test('容器层列出了 Info.plist 但归档里读不到 → error 级诊断', () {
      final bundle = IosBundle(
        kind: IosBundleKind.mainApp,
        path: 'Payload/A.app',
        name: 'A.app',
        infoPlistPath: 'Payload/A.app/Info.plist',
      );

      final info = IpaInfoPlistReader.read(Archive(), bundle);

      expect(info.bundleIdentifier.status, FieldStatus.absent);
      expect(info.diagnostics.single.severity, DiagnosticSeverity.error);
      expect(info.diagnostics.single.code, 'ios.info_plist.vanished');
    });

    test('Info.plist 超过大小上限时拒绝读取', () {
      final archive = Archive()
        ..addFile(ArchiveFile(
          'Payload/A.app/Info.plist',
          IpaInfoPlistReader.maxInfoPlistBytes + 1,
          utf8.encode(_xmlInfoPlist),
        ));
      final bundle = IpaContainerReader.read(archive).mainApp!;

      final info = IpaInfoPlistReader.read(archive, bundle);

      expect(info.hasAnyValue, isFalse);
      expect(info.diagnostics.single.code, 'ios.info_plist.too_large');
      expect(info.diagnostics.single.severity, DiagnosticSeverity.warning);
    });
  });

  group('IpaInfoPlistReader — 类型错误', () {
    IpaInfoPlist readWith(String body) => _read(utf8.encode(
        '<?xml version="1.0"?><plist version="1.0"><dict>$body</dict></plist>'));

    test('字符串字段被写成数组 → wrongType，且带出实际类型', () {
      final info = readWith(
          '<key>CFBundleIdentifier</key><array><string>x</string></array>');

      expect(info.bundleIdentifier.status, FieldStatus.wrongType);
      expect(info.bundleIdentifier.status, isNot(FieldStatus.absent));
      expect(info.bundleIdentifier.status, isNot(FieldStatus.failed));
      expect(info.bundleIdentifier.diagnostic, contains('CFBundleIdentifier'));
      expect(info.bundleIdentifier.diagnostic, contains('array'));
    });

    test('UIDeviceFamily 写成字符串 → wrongType', () {
      final info = readWith('<key>UIDeviceFamily</key><string>1</string>');

      expect(info.deviceFamily.status, FieldStatus.wrongType);
      expect(info.deviceFamily.diagnostic, contains('UIDeviceFamily'));
    });

    test('数组里混入非整数 → wrongType（不静默丢弃元素）', () {
      final info = readWith('<key>UIDeviceFamily</key>'
          '<array><integer>1</integer><string>two</string></array>');

      expect(info.deviceFamily.status, FieldStatus.wrongType);
      expect(info.deviceFamily.diagnostic, contains('string'));
    });

    test('LSApplicationQueriesSchemes 写成裸字符串 → wrongType，不自动补成数组', () {
      final info = readWith(
          '<key>LSApplicationQueriesSchemes</key><string>weixin</string>');

      expect(info.queriesSchemes.status, FieldStatus.wrongType,
          reason: '把裸标量当成单元素数组是在替文件补结构');
    });

    test('CFBundleVersion 是整数时按设计接受（真实包常见）', () {
      final info = readWith('<key>CFBundleVersion</key><integer>7</integer>');

      expect(info.bundleVersion.status, FieldStatus.extracted);
      expect(info.bundleVersion.value, '7');
    });

    test('CFBundleVersion 是数组时才是 wrongType', () {
      final info = readWith(
          '<key>CFBundleVersion</key><array><integer>7</integer></array>');

      expect(info.bundleVersion.status, FieldStatus.wrongType);
    });

    test('缺失字段与类型错误在同一份文件里各自独立记录', () {
      final info = readWith('<key>CFBundleIdentifier</key>'
          '<array><string>x</string></array>');

      expect(info.bundleIdentifier.status, FieldStatus.wrongType);
      expect(info.bundleName.status, FieldStatus.absent);
      expect(info.minimumOSVersion.status, FieldStatus.absent);
    });
  });

  group('IpaInfoPlist — 派生字段', () {
    IpaInfoPlist readWith(String body) => _read(utf8.encode(
        '<?xml version="1.0"?><plist version="1.0"><dict>$body</dict></plist>'));

    test('preferredName 优先显示名，其次 CFBundleName', () {
      expect(
        readWith('<key>CFBundleDisplayName</key><string>Display</string>'
                '<key>CFBundleName</key><string>Name</string>')
            .preferredName
            .value,
        'Display',
      );
      expect(
        readWith('<key>CFBundleName</key><string>Name</string>')
            .preferredName
            .value,
        'Name',
      );
    });

    test('两者都缺时保留更有信息量的失败原因', () {
      final info = readWith('<key>CFBundleDisplayName</key>'
          '<array><string>x</string></array>');

      // displayName 是类型错误（更有信息量），bundleName 只是缺失
      expect(info.preferredName.status, FieldStatus.wrongType);
    });

    test('完全没有名称字段时 preferredName 无值，不伪造空串', () {
      final info =
          readWith('<key>CFBundleIdentifier</key><string>a.b</string>');

      expect(info.preferredName.hasValue, isFalse);
      expect(info.preferredName.status, FieldStatus.absent);
    });

    test('原始 plist 可查未建模的键', () {
      final info = readWith('<key>SomethingCustom</key><string>hello</string>');

      final raw = info.raw as PlistDict;
      expect(raw.value['SomethingCustom']!.asString, 'hello');
    });
  });

  group('IpaInfoPlistReader — 图标配置边界', () {
    IpaInfoPlist readWith(String body) => _read(utf8.encode(
        '<?xml version="1.0"?><plist version="1.0"><dict>$body</dict></plist>'));

    test('完全没有图标配置 → absent', () {
      final info =
          readWith('<key>CFBundleIdentifier</key><string>a.b</string>');

      expect(info.icons.status, FieldStatus.absent);
    });

    test('旧式顶层 CFBundleIconFiles 也能识别', () {
      final info = readWith('<key>CFBundleIconFiles</key>'
          '<array><string>Icon</string></array>');

      expect(info.icons.status, FieldStatus.extracted);
      expect(info.icons.value!.legacyIconFiles, ['Icon']);
      expect(info.icons.value!.primary, isNull);
    });

    test('更旧的 CFBundleIconFile（单个文件名）也能识别', () {
      final info = readWith('<key>CFBundleIconFile</key><string>Icon</string>');

      expect(info.icons.value!.legacyIconFile, 'Icon');
    });

    test('CFBundleIcons 结构畸形时不崩，只是取不到', () {
      final info = readWith('<key>CFBundleIcons</key><string>broken</string>');

      expect(info.icons.status, FieldStatus.absent);
      expect(info.bundleIdentifier.status, FieldStatus.absent);
    });

    test('空的 CFBundlePrimaryIcon 不产生条目', () {
      final info = readWith('<key>CFBundleIcons</key><dict>'
          '<key>CFBundlePrimaryIcon</key><dict></dict></dict>');

      expect(info.icons.status, FieldStatus.absent);
    });
  });
}
