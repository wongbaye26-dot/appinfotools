import 'dart:convert';
import 'dart:typed_data';

import 'package:analysis_model/analysis_model.dart';
import 'package:archive/archive.dart';
import 'package:ipa_parser/ipa_parser.dart';
import 'package:test/test.dart';

const _bundlePath = 'Payload/App.app';

IosBundle _bundle() => IosBundle(
      kind: IosBundleKind.mainApp,
      path: _bundlePath,
      name: 'App.app',
      infoPlistPath: '$_bundlePath/Info.plist',
      hasCodeSignatureDirectory: true,
    );

Archive _archive({
  required Map<String, List<int>> files,
  required String codeResources,
}) {
  final archive = Archive();
  void add(String path, List<int> bytes) {
    archive.addFile(ArchiveFile(path, bytes.length, bytes));
  }

  add('$_bundlePath/_CodeSignature/CodeResources', utf8.encode(codeResources));
  files.forEach(add);
  return archive;
}

String _plist({required String path, required List<int> hash}) {
  final b64 = base64Encode(hash);
  return '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>files2</key><dict>
<key>$path</key><dict><key>hash2</key><data>$b64</data></dict>
</dict></dict></plist>''';
}

String? _fakeDigest(String algorithm, Uint8List bytes) {
  if (algorithm == 'sha256') {
    // 32 字节 0xaa 的 hex，测试不依赖真实哈希。
    return 'aa' * 32;
  }
  return null;
}

void main() {
  test('摘要一致 → verified；条目路径与算法保留', () {
    final payload = Uint8List.fromList([1, 2, 3]);
    final archive = _archive(
      files: {'$_bundlePath/Info.plist': payload},
      codeResources: _plist(
        path: 'Info.plist',
        hash: List<int>.filled(32, 0xaa),
      ),
    );
    final check = IosCodeResourcesCheck.check(
      archive: archive,
      bundle: _bundle(),
      digest: _fakeDigest,
    );
    expect(check.scheme, 'ipa.codeResources.v2');
    expect(check.state, SealState.verified);
    expect(check.entriesChecked, 1);
    expect(check.signatureVerified, isFalse);
    expect(check.checks.single.path, '$_bundlePath/Info.plist');
    expect(check.checks.single.algorithm, 'sha256');
  });

  test('摘要不一致 → mismatch', () {
    final archive = _archive(
      files: {
        '$_bundlePath/Info.plist': [1, 2, 3]
      },
      codeResources: _plist(
        path: 'Info.plist',
        hash: List<int>.filled(32, 0xbb),
      ),
    );
    final check = IosCodeResourcesCheck.check(
      archive: archive,
      bundle: _bundle(),
      digest: _fakeDigest,
    );
    expect(check.state, SealState.mismatch);
    expect(check.checks.single.state, SealState.mismatch);
  });

  test('密封清单有、归档没有 → entryMissing', () {
    final archive = _archive(
      files: const {},
      codeResources: _plist(
        path: 'Info.plist',
        hash: List<int>.filled(32, 0xaa),
      ),
    );
    final check = IosCodeResourcesCheck.check(
      archive: archive,
      bundle: _bundle(),
      digest: _fakeDigest,
    );
    expect(check.state, SealState.entryMissing);
    expect(check.checks.single.state, SealState.entryMissing);
  });

  test('没有 CodeResources → unsealed，不冒充 verified', () {
    final archive = Archive()
      ..addFile(ArchiveFile('$_bundlePath/Info.plist', 3, [1, 2, 3]));
    final check = IosCodeResourcesCheck.check(
      archive: archive,
      bundle: _bundle(),
      digest: _fakeDigest,
    );
    expect(check.state, SealState.unsealed);
    expect(check.signatureVerified, isFalse);
  });

  test('摘要函数不可用 → notChecked，不冒充 verified', () {
    final archive = _archive(
      files: {
        '$_bundlePath/Info.plist': [1, 2, 3]
      },
      codeResources: _plist(
        path: 'Info.plist',
        hash: List<int>.filled(32, 0xaa),
      ),
    );
    final check = IosCodeResourcesCheck.check(
      archive: archive,
      bundle: _bundle(),
      digest: (_, __) => null,
    );
    expect(check.state, SealState.notChecked);
    expect(check.noteCodes, contains('seal.digest_unavailable'));
  });
}
