import 'dart:io';
import 'dart:typed_data';

import 'package:apk_parser/apk_parser.dart';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('manifest 损坏时仍从 resources.arsc 回退包名并标记未解析', () async {
    final source = File('test/fixtures/apk/signed-v2-v3.apk').readAsBytesSync();
    final original = ZipDecoder().decodeBytes(source);
    final corruptManifest = Uint8List.fromList([
      0x03,
      0x00,
      0x08,
      0x00,
      0x10,
      0x00,
      0x00,
      0x00,
      0xF4,
      0x7F,
      0x08,
      0x00,
      ...List<int>.filled(16, 0),
    ]);
    final rebuilt = Archive();
    for (final file in original.files) {
      final content = file.name == 'AndroidManifest.xml'
          ? corruptManifest
          : (file.content as List<int>);
      rebuilt.addFile(ArchiveFile(file.name, content.length, content));
    }
    final temp = Directory.systemTemp.createTempSync('apk_manifest_fallback');
    final path = '${temp.path}/bad-manifest.apk';
    File(path).writeAsBytesSync(ZipEncoder().encode(rebuilt));
    final reader = ApkReader();
    try {
      expect((await reader.open(path)).isOk, isTrue);
      final meta = await reader.parse();
      expect(meta, isNotNull);
      expect(meta!.packageName, isNotEmpty);
      expect(meta.manifestUnparsed, isTrue);
      expect(meta.manifestParseFailure, contains('String table'));
      expect(reader.manifestFailure, contains('could not be parsed'));
    } finally {
      reader.close();
      temp.deleteSync(recursive: true);
    }
  });
}
