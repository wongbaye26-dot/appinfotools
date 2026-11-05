import 'dart:convert';
import 'dart:io';

import 'package:apk_info_tool/ipaparser/ipa_analysis.dart';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('主应用根目录的 .dylib 会作为安全扫描目标', () async {
    final plist = utf8.encode('''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.example.rootdylib</string>
<key>CFBundleExecutable</key><string>App</string>
<key>CFBundleName</key><string>App</string>
</dict></plist>''');
    final mainBytes =
        File('test/fixtures/macho/thin-arm64.dylib').readAsBytesSync();
    final injectedBytes =
        File('test/fixtures/macho/libnative-fixture-arm64.dylib')
            .readAsBytesSync();
    final archive = Archive()
      ..addFile(ArchiveFile('Payload/App.app/Info.plist', plist.length, plist))
      ..addFile(ArchiveFile('Payload/App.app/App', mainBytes.length, mainBytes))
      ..addFile(ArchiveFile('Payload/App.app/injected.dylib',
          injectedBytes.length, injectedBytes));

    final analysis = IpaAnalysisReader.analyze(archive, securityAudit: false);
    final rootDylibs =
        analysis.nestedBinaries.where((b) => b.kind.name == 'dylib').toList();
    expect(rootDylibs, hasLength(1));
    expect(rootDylibs.single.path, 'Payload/App.app/injected.dylib');
    expect(rootDylibs.single.isScannable, isTrue);
  });
}
