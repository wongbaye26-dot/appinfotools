// IPA 静态解析管线测试（规范第五步 / 第六步）。
//
// 样本是**拼出来的完整 IPA**：Mach-O 用 clang 编出来的真实 dylib、
// PNG 用仓库内真实图标、描述文件用真实 CMS 产物、Info.plist 是真实字段布局。
// 只有容器结构是手工拼的 —— 因为仓库里没有真实 IPA，而结构恰恰是我们要
// 断言的那一层。

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:analysis_model/analysis_model.dart';
import 'package:apk_info_tool/ipaparser/ipa_analysis.dart';
import 'package:apk_info_tool/ipaparser/ipa_parse_task.dart';
import 'package:archive/archive.dart';
import 'package:archive_safety/archive_safety.dart' show ArchiveOpenResult;
import 'package:flutter_test/flutter_test.dart';
import 'package:ipa_parser/ipa_parser.dart';

Uint8List _fixture(String path) {
  final file = File(path);
  expect(file.existsSync(), isTrue, reason: '缺少测试样本 $path');
  return file.readAsBytesSync();
}

/// 真实的 arm64 Mach-O（clang 编译，见 test/fixtures/macho/README.md）。
Uint8List get _macho => _fixture('test/fixtures/macho/thin-arm64.dylib');

/// 真实的 fat Mach-O（x86_64 + arm64）。
Uint8List get _fatMacho =>
    _fixture('test/fixtures/macho/fat-x86_64-arm64.dylib');

/// 真实的 PNG。
Uint8List get _png => _fixture('assets/image/icon.png');

/// 真实的 CMS/PKCS#7 描述文件。
Uint8List get _provision =>
    _fixture('test/fixtures/ipa/embedded.mobileprovision');

const String _infoPlist = '''
<?xml version="1.0" encoding="UTF-8"?>
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
	<string>241</string>
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
	</array>
	<key>UIRequiredDeviceCapabilities</key>
	<array>
		<string>arm64</string>
	</array>
	<key>CFBundleIcons</key>
	<dict>
		<key>CFBundlePrimaryIcon</key>
		<dict>
			<key>CFBundleIconFiles</key>
			<array>
				<string>Icon</string>
			</array>
		</dict>
	</dict>
</dict>
</plist>
''';

/// 嵌套 bundle 的 Info.plist。
String _nestedInfoPlist(String executable) => '''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>com.example.app.$executable</string>
	<key>CFBundleExecutable</key>
	<string>$executable</string>
</dict>
</plist>
''';

ArchiveFile _file(String name, List<int> content) =>
    ArchiveFile(name, content.length, Uint8List.fromList(content));

ArchiveFile _dir(String name) => ArchiveFile(name, 0, <int>[])..isFile = false;

/// 一个结构完整的 IPA。
Archive _ipa({
  bool withProvision = true,
  bool withCodeSignature = true,
  bool withIcon = true,
  bool withExecutable = true,
  bool withNested = true,
  List<int>? executableBytes,
  String? infoPlist,
}) {
  final archive = Archive()
    ..addFile(_dir('Payload/'))
    ..addFile(_dir('Payload/Example.app/'))
    ..addFile(_file('Payload/Example.app/Info.plist',
        utf8.encode(infoPlist ?? _infoPlist)));

  if (withExecutable) {
    archive.addFile(
        _file('Payload/Example.app/Example', executableBytes ?? _macho));
  }
  if (withIcon) {
    archive.addFile(_file('Payload/Example.app/Icon@2x.png', _png));
  }
  if (withCodeSignature) {
    archive.addFile(_file('Payload/Example.app/_CodeSignature/CodeResources',
        List.filled(64, 7)));
  }
  if (withProvision) {
    archive.addFile(
        _file('Payload/Example.app/embedded.mobileprovision', _provision));
  }
  if (withNested) {
    archive
      ..addFile(_dir('Payload/Example.app/PlugIns/'))
      ..addFile(_dir('Payload/Example.app/PlugIns/Share.appex/'))
      ..addFile(_file('Payload/Example.app/PlugIns/Share.appex/Info.plist',
          utf8.encode(_nestedInfoPlist('Share'))))
      ..addFile(
          _file('Payload/Example.app/PlugIns/Share.appex/Share', _fatMacho))
      ..addFile(_dir('Payload/Example.app/Frameworks/'))
      ..addFile(_dir('Payload/Example.app/Frameworks/Lib.framework/'))
      ..addFile(_file('Payload/Example.app/Frameworks/Lib.framework/Info.plist',
          utf8.encode(_nestedInfoPlist('Lib'))))
      ..addFile(
          _file('Payload/Example.app/Frameworks/Lib.framework/Lib', _macho));
  }
  return archive;
}

void main() {
  group('IpaAnalysisReader — 完整 IPA', () {
    late IpaAnalysis analysis;

    setUpAll(() {
      analysis = IpaAnalysisReader.analyze(_ipa());
    });

    test('主应用被正确定位', () {
      expect(analysis.hasMainApp, isTrue);
      expect(analysis.mainApp!.path, 'Payload/Example.app');
      expect(analysis.mainApp!.kind, IosBundleKind.mainApp);
    });

    test('Info.plist 字段被提取', () {
      final info = analysis.infoPlist!;
      expect(info.bundleIdentifier.value, 'com.example.app');
      expect(info.displayName.value, '示例应用');
      expect(info.shortVersionString.value, '2.4.1');
      expect(info.bundleVersion.value, '241');
      expect(info.executable.value, 'Example');
      expect(info.minimumOSVersion.value, '16.0');
      expect(info.deviceFamily.value, [1, 2]);
      expect(info.preferredName.value, '示例应用');
    });

    test('图标按 Info.plist 点名的文件定位', () {
      final icon = analysis.icon!;
      expect(icon.candidates, isNotEmpty);
      expect(icon.candidates.first.relativePath, 'Icon@2x.png');
      expect(
          icon.candidates.first.archivePath, 'Payload/Example.app/Icon@2x.png');
      expect(icon.candidates.first.bytes, isNotNull);
      expect(icon.candidates.first.format, IosImageFormat.png);
      expect(icon.candidates.first.pixelWidth, isNotNull);
    });

    test('主可执行文件被解析为 Mach-O', () {
      expect(analysis.executablePath, 'Payload/Example.app/Example');
      final macho = analysis.executable!;
      expect(macho.isMachO, isTrue);
      expect(macho.primary!.cpuTypeName, 'arm64');
      expect(macho.primary!.is64Bit, isTrue);
    });

    test('嵌套 bundle 的二进制被列出（扩展 + 框架）', () {
      final paths = analysis.nestedBinaries.map((b) => b.bundlePath).toList();
      expect(paths, contains('Payload/Example.app/PlugIns/Share.appex'));
      expect(paths, contains('Payload/Example.app/Frameworks/Lib.framework'));

      final share = analysis.nestedBinaries
          .firstWhere((b) => b.bundlePath.endsWith('Share.appex'));
      expect(share.kind, IosBundleKind.appExtension);
      expect(share.architectures, ['x86_64 (64-bit)', 'arm64 (64-bit)']);

      final lib = analysis.nestedBinaries
          .firstWhere((b) => b.bundlePath.endsWith('Lib.framework'));
      expect(lib.kind, IosBundleKind.framework);
      expect(lib.architectures, ['arm64 (64-bit)']);
    });

    test('签名材料被记录，且结论是「无法确认」而不是「有效」', () {
      final signature = analysis.signature!;
      expect(signature.hasCodeSignatureDirectory, isTrue);
      expect(signature.codeSignatureEntries, ['CodeResources']);
      expect(signature.hasEmbeddedProvision, isTrue);
      expect(signature.verificationStatus, SignatureStatus.toolUnavailable);
      expect(signature.verificationStatus.hasConclusiveResult, isFalse);
    });

    test('描述文件被静态提取（含授权项）', () {
      final profile = analysis.signature!.profile.value!;
      expect(profile.name.value, 'Probe Distribution');
      expect(profile.teamIdentifiers.value, ['ABCDE12345']);
      expect(profile.entitlements, isNotEmpty);
    });

    test('应用声明与描述文件授权被比对', () {
      final authorization = analysis.authorization!;
      // 描述文件授权的是 ABCDE12345.com.example.app，应用声明 com.example.app
      // —— 按后缀比较应当一致。
      expect(authorization.verdict, IosAuthorizationVerdict.matches);
      expect(authorization.isConsistent, isTrue);
    });

    test('阶段按解析推进顺序上报', () {
      final stages = <IpaParseStage>[];
      IpaAnalysisReader.analyze(_ipa(), onStage: stages.add);

      expect(stages, [
        IpaParseStage.container,
        IpaParseStage.infoPlist,
        IpaParseStage.icon,
        IpaParseStage.macho,
        IpaParseStage.signature,
        IpaParseStage.done,
      ]);
    });
  });

  group('IpaAnalysisReader — 缺失与异常', () {
    test('没有 Payload/ 时如实记录，不崩溃', () {
      final archive = Archive()
        ..addFile(_file('Example.app/Info.plist', utf8.encode(_infoPlist)));

      final analysis = IpaAnalysisReader.analyze(archive);

      expect(analysis.hasMainApp, isFalse);
      expect(
        analysis.allDiagnostics.map((d) => d.code),
        contains('ios.container.no_payload'),
      );
      expect(
        analysis.allDiagnostics.map((d) => d.code),
        contains('ios.container.no_main_app'),
      );
    });

    test('多个 Payload/*.app 时全部保留并给出警告', () {
      final archive = _ipa()
        ..addFile(_dir('Payload/Other.app/'))
        ..addFile(
            _file('Payload/Other.app/Info.plist', utf8.encode(_infoPlist)));

      final analysis = IpaAnalysisReader.analyze(archive);

      expect(analysis.container.hasMultipleMainApps, isTrue);
      expect(
        analysis.allDiagnostics.map((d) => d.code),
        contains('ios.container.multiple_main_apps'),
      );
    });

    test('CFBundleExecutable 缺失时不猜文件名', () {
      const noExecutable = '''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
	<key>CFBundleIdentifier</key><string>com.example.app</string>
</dict></plist>
''';
      final analysis = IpaAnalysisReader.analyze(_ipa(infoPlist: noExecutable));

      expect(analysis.executablePath, isNull);
      expect(analysis.executable, isNull);
      expect(
        analysis.allDiagnostics.map((d) => d.code),
        contains('ios.macho.no_executable_declared'),
      );
    });

    test('CFBundleExecutable 里带路径分隔符时拒绝拼路径', () {
      const badExecutable = '''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
	<key>CFBundleIdentifier</key><string>com.example.app</string>
	<key>CFBundleExecutable</key><string>../../evil</string>
</dict></plist>
''';
      final analysis = IpaAnalysisReader.analyze(
          _ipa(infoPlist: badExecutable, withExecutable: false));

      expect(analysis.executablePath, isNull);
    });

    test('可执行文件不是 Mach-O 时记诊断，不影响其它字段', () {
      final analysis = IpaAnalysisReader.analyze(
        _ipa(executableBytes: List.filled(512, 0x41)),
      );

      expect(analysis.executable, isNotNull);
      expect(analysis.executable!.isMachO, isFalse);
      expect(
        analysis.allDiagnostics.map((d) => d.code),
        contains('ios.macho.unparsable'),
      );
      // 其它部分照常。
      expect(analysis.infoPlist!.bundleIdentifier.value, 'com.example.app');
    });

    test('可执行文件缺失时记诊断', () {
      final analysis = IpaAnalysisReader.analyze(_ipa(withExecutable: false));

      expect(analysis.executable, isNull);
      expect(
        analysis.allDiagnostics.map((d) => d.code),
        contains('ios.macho.missing'),
      );
    });

    test('没有描述文件时不给比对结论', () {
      final analysis = IpaAnalysisReader.analyze(_ipa(withProvision: false));

      expect(analysis.signature!.profile.status, FieldStatus.absent);
      expect(analysis.authorization, isNull);
    });

    test('没有图标配置时不把别的图片当图标', () {
      const noIcons = '''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
	<key>CFBundleIdentifier</key><string>com.example.app</string>
	<key>CFBundleExecutable</key><string>Example</string>
</dict></plist>
''';
      final analysis = IpaAnalysisReader.analyze(
        _ipa(infoPlist: noIcons),
      );

      // 归档里确实有 Icon@2x.png，但 Info.plist 没有点名它。
      expect(analysis.icon!.candidates, isEmpty);
    });

    test('嵌套 bundle 的清单有上限，不会无限膨胀', () {
      final archive = _ipa(withNested: false);
      for (var i = 0; i < IpaAnalysisReader.maxNestedBinaries + 8; i++) {
        archive
          ..addFile(_dir('Payload/Example.app/Frameworks/F$i.framework/'))
          ..addFile(_file(
              'Payload/Example.app/Frameworks/F$i.framework/Info.plist',
              utf8.encode(_nestedInfoPlist('F$i'))))
          ..addFile(_file(
              'Payload/Example.app/Frameworks/F$i.framework/F$i', _macho));
      }

      final analysis = IpaAnalysisReader.analyze(archive);

      expect(
          analysis.nestedBinaries.length, IpaAnalysisReader.maxNestedBinaries);
    });
  });

  group('IpaParseTask — worker isolate', () {
    late Directory temp;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('appinfo_ipa_task_test_');
    });

    tearDown(() async {
      if (temp.existsSync()) await temp.delete(recursive: true);
    });

    /// 把内存里的归档写成真实的 .ipa 文件。
    Future<String> writeIpa(Archive archive, [String name = 'app.ipa']) async {
      final bytes = ZipEncoder().encode(archive);
      final path = '${temp.path}/$name';
      await File(path).writeAsBytes(bytes, flush: true);
      return path;
    }

    test('解析成功并上报全部阶段', () async {
      final path = await writeIpa(_ipa());
      final task = await IpaParseTask.start(path);

      final events = await task.events.toList();
      final stages = events.whereType<IpaStageReached>().map((e) => e.stage);

      expect(stages, contains(IpaParseStage.openContainer));
      expect(stages, contains(IpaParseStage.container));
      expect(stages, contains(IpaParseStage.infoPlist));
      expect(stages, contains(IpaParseStage.macho));
      expect(stages, contains(IpaParseStage.signature));

      final succeeded = events.whereType<IpaParseSucceeded>().toList();
      expect(succeeded, hasLength(1));
      expect(succeeded.first.analysis.mainApp!.path, 'Payload/Example.app');
    });

    test('成功事件是最后一个事件', () async {
      final path = await writeIpa(_ipa());
      final task = await IpaParseTask.start(path);

      final events = await task.events.toList();
      expect(events.last, isA<IpaParseSucceeded>());
    });

    test('不是 ZIP 的文件被归类为 notArchive，而不是「解析失败」', () async {
      final path = '${temp.path}/not-a-zip.ipa';
      await File(path).writeAsString('this is definitely not a zip file');

      final task = await IpaParseTask.start(path);
      final events = await task.events.toList();

      final openFailed = events.whereType<IpaOpenFailed>().toList();
      expect(openFailed, hasLength(1));
      expect(openFailed.first.result, ArchiveOpenResult.notArchive);
      expect(events.whereType<IpaParseSucceeded>(), isEmpty);
    });

    test('文件不存在时给出 ioError', () async {
      final task = await IpaParseTask.start('${temp.path}/missing.ipa');
      final events = await task.events.toList();

      final openFailed = events.whereType<IpaOpenFailed>().toList();
      expect(openFailed, hasLength(1));
      expect(openFailed.first.result, ArchiveOpenResult.ioError);
    });

    test('取消后只收到取消事件，且不再有后续事件', () async {
      final path = await writeIpa(_ipa());
      final task = await IpaParseTask.start(path);

      final events = <IpaParseEvent>[];
      final done = Completer<void>();
      task.events.listen(events.add, onDone: done.complete);

      task.cancel();
      await done.future;

      expect(events.last, isA<IpaParseCancelled>());
      expect(events.whereType<IpaParseSucceeded>(), isEmpty);
      expect(events.whereType<IpaParseFailed>(), isEmpty);
    });

    test('取消两次不会出错', () async {
      final path = await writeIpa(_ipa());
      final task = await IpaParseTask.start(path);

      final done = Completer<void>();
      final events = <IpaParseEvent>[];
      task.events.listen(events.add, onDone: done.complete);

      task.cancel();
      task.cancel();
      await done.future;

      expect(events.whereType<IpaParseCancelled>(), hasLength(1));
    });

    test('连续解析两个不同文件不会串结果', () async {
      final first = await writeIpa(_ipa(), 'first.ipa');
      final second = await writeIpa(
        _ipa(
          infoPlist:
              _infoPlist.replaceAll('com.example.app', 'com.example.second'),
        ),
        'second.ipa',
      );

      final firstResult =
          (await IpaParseTask.start(first).then((t) => t.events.toList()))
              .whereType<IpaParseSucceeded>()
              .first;
      final secondResult =
          (await IpaParseTask.start(second).then((t) => t.events.toList()))
              .whereType<IpaParseSucceeded>()
              .first;

      expect(firstResult.analysis.infoPlist!.bundleIdentifier.value,
          'com.example.app');
      expect(secondResult.analysis.infoPlist!.bundleIdentifier.value,
          'com.example.second');
    });
  });
}
