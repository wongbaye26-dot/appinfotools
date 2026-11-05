import 'dart:convert';
import 'dart:typed_data';

import 'package:analysis_model/analysis_model.dart';
import 'package:apk_parser/apk_parser.dart';
import 'package:archive/archive.dart';
import 'package:test/test.dart';

Archive _archive({required String manifest, List<int>? dex}) {
  final archive = Archive();
  final manifestBytes = utf8.encode(manifest);
  archive.addFile(
      ArchiveFile('META-INF/MANIFEST.MF', manifestBytes.length, manifestBytes));
  if (dex != null) {
    archive.addFile(ArchiveFile('classes.dex', dex.length, dex));
  }
  return archive;
}

String _manifest({required List<int> hash}) {
  return 'Manifest-Version: 1.0\r\n'
      '\r\n'
      'Name: classes.dex\r\n'
      'SHA-256-Digest: ${base64Encode(hash)}\r\n'
      '\r\n';
}

String? _fakeDigest(String algorithm, Uint8List bytes) {
  return algorithm == 'sha256' ? 'aa' * 32 : null;
}

Uint8List _u32(int value) => Uint8List.fromList([
      value & 0xff,
      (value >> 8) & 0xff,
      (value >> 16) & 0xff,
      (value >> 24) & 0xff,
    ]);

Uint8List _lp(List<int> content) =>
    Uint8List.fromList([..._u32(content.length), ...content]);

/// 构造一个最小 v2 signed data：signers → signer → signed-data → digests → digest。
Uint8List _v2Value(List<int> expectedDigest) {
  final record = Uint8List.fromList([
    0x03,
    0x01,
    0x00,
    0x00, // 0x0103 RSA PKCS1 SHA-256
    ..._lp(expectedDigest),
  ]);
  final digests = _lp(record);
  final signedData = _lp(digests);
  final signer = _lp(signedData);
  final signers = _lp(signer);
  return _lp(signers);
}

String? _constantDigest(String algorithm, Uint8List bytes) =>
    algorithm == 'sha256' ? 'aa' * 32 : null;

void main() {
  test('v1 MANIFEST 摘要一致 → verified', () {
    final seal = ApkSealCheck.check(
      archive: _archive(
        manifest: _manifest(hash: List<int>.filled(32, 0xaa)),
        dex: [1, 2, 3],
      ),
      digest: _fakeDigest,
    );
    expect(seal.scheme, 'apk.v1.manifest');
    expect(seal.state, SealState.verified);
    expect(seal.entriesChecked, 1);
    expect(seal.signatureVerified, isFalse);
    expect(seal.checks.single.path, 'classes.dex');
  });

  test('v1 MANIFEST 摘要不一致 → mismatch', () {
    final seal = ApkSealCheck.check(
      archive: _archive(
        manifest: _manifest(hash: List<int>.filled(32, 0xbb)),
        dex: [1, 2, 3],
      ),
      digest: _fakeDigest,
    );
    expect(seal.state, SealState.mismatch);
    expect(seal.checks.single.state, SealState.mismatch);
  });

  test('清单有、归档没有 → entryMissing', () {
    final seal = ApkSealCheck.check(
      archive: _archive(manifest: _manifest(hash: List<int>.filled(32, 0xaa))),
      digest: _fakeDigest,
    );
    expect(seal.state, SealState.entryMissing);
  });

  test('没有 MANIFEST.MF → unsealed', () {
    final archive = Archive()
      ..addFile(ArchiveFile('classes.dex', 3, [1, 2, 3]));
    final seal = ApkSealCheck.check(archive: archive, digest: _fakeDigest);
    expect(seal.state, SealState.unsealed);
    expect(seal.signatureVerified, isFalse);
  });

  test('摘要函数不可用 → notChecked', () {
    final seal = ApkSealCheck.check(
      archive: _archive(
        manifest: _manifest(hash: List<int>.filled(32, 0xaa)),
        dex: [1, 2, 3],
      ),
      digest: (_, __) => null,
    );
    expect(seal.state, SealState.notChecked);
    expect(seal.noteCodes, contains('seal.digest_unavailable'));
  });

  test('v2 内容摘要：摘要一致 → verified（结构/偏移接线）', () {
    final before = Uint8List.fromList('ABCDEFGH'.codeUnits);
    final block = Uint8List(32);
    final central = Uint8List.fromList('IJKLMNOP'.codeUnits);
    final eocd = Uint8List(22);
    final cdOffset = before.length + block.length;
    eocd.setRange(16, 20, _u32(cdOffset));
    final file = Uint8List.fromList([...before, ...block, ...central, ...eocd]);
    final schemes = ApkSigningSchemes(
      pairIds: const [0x7109871a],
      v2Value: _v2Value(List<int>.filled(32, 0xaa)),
      signingBlockOffset: before.length,
      centralDirOffset: cdOffset,
      eocdOffset: cdOffset + central.length,
    );
    final seal = ApkSealCheck.checkV2(
      schemes: schemes,
      fileLength: file.length,
      digest: _constantDigest,
      read: (offset, count) => Uint8List.sublistView(
        file,
        offset.clamp(0, file.length),
        (offset + count).clamp(0, file.length),
      ),
    );
    expect(seal.state, SealState.verified);
    expect(seal.scheme, 'apk.v2.content');
  });

  test('v3-only 内容摘要：摘要一致 → verified', () {
    final before = Uint8List.fromList('ABCDEFGH'.codeUnits);
    final central = Uint8List.fromList('IJKLMNOP'.codeUnits);
    final eocd = Uint8List(22);
    final cdOffset = before.length + 32;
    eocd.setRange(16, 20, _u32(cdOffset));
    final file =
        Uint8List.fromList([...before, ...Uint8List(32), ...central, ...eocd]);
    final schemes = ApkSigningSchemes(
      pairIds: const [0xf05368c0],
      v3Value: _v2Value(List<int>.filled(32, 0xaa)),
      signingBlockOffset: before.length,
      centralDirOffset: cdOffset,
      eocdOffset: cdOffset + central.length,
    );
    final seal = ApkSealCheck.checkV3(
      schemes: schemes,
      fileLength: file.length,
      digest: _constantDigest,
      read: (offset, count) => Uint8List.sublistView(
        file,
        offset.clamp(0, file.length),
        (offset + count).clamp(0, file.length),
      ),
    );
    expect(seal.scheme, 'apk.v3.content');
    expect(seal.state, SealState.verified);
  });

  test('v2 内容摘要：记录不一致 → mismatch', () {
    final before = Uint8List.fromList('ABCDEFGH'.codeUnits);
    final central = Uint8List.fromList('IJKLMNOP'.codeUnits);
    final eocd = Uint8List(22);
    final cdOffset = before.length + 32;
    eocd.setRange(16, 20, _u32(cdOffset));
    final file =
        Uint8List.fromList([...before, ...Uint8List(32), ...central, ...eocd]);
    final schemes = ApkSigningSchemes(
      pairIds: const [0x7109871a],
      v2Value: _v2Value(List<int>.filled(32, 0xbb)),
      signingBlockOffset: before.length,
      centralDirOffset: cdOffset,
      eocdOffset: cdOffset + central.length,
    );
    final seal = ApkSealCheck.checkV2(
      schemes: schemes,
      fileLength: file.length,
      digest: _constantDigest,
      read: (offset, count) => Uint8List.sublistView(
        file,
        offset.clamp(0, file.length),
        (offset + count).clamp(0, file.length),
      ),
    );
    expect(seal.state, SealState.mismatch);
  });
}
