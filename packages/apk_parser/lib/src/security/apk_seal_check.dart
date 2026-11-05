import 'dart:convert';
import 'dart:typed_data';

import 'package:analysis_model/analysis_model.dart';
import 'package:archive/archive.dart';

import '../apk_signing_block.dart';

/// Android v1（JAR）签名清单的逐条目摘要校验。
///
/// **只验证 MANIFEST.MF 记录与条目内容是否一致，不验证签名**：
/// `signatureVerified` 恒为 `false`。v1 只保护条目内容，不保护 ZIP 结构；
/// 攻击者可以塞入额外条目而不破坏 v1 —— 那类事实由清单外的条目/官方基线
/// 回答，不在本检查里编造。
class ApkSealCheck {
  ApkSealCheck._();

  static const String manifestPath = 'META-INF/MANIFEST.MF';
  static const int maxEntries = 64;
  static const int maxManifestBytes = 8 * 1024 * 1024;
  static const int maxEntryBytes = 8 * 1024 * 1024;

  static SealCheck check({
    required Archive archive,
    required ContentDigestFn digest,
  }) {
    final manifest = archive.findFile(manifestPath);
    if (manifest == null) {
      return const SealCheck(
        scheme: 'apk.v1.manifest',
        state: SealState.unsealed,
        noteCodes: ['seal.not_parsed'],
      );
    }

    Uint8List bytes;
    try {
      final content = manifest.content;
      if (content.length > maxManifestBytes) {
        return const SealCheck(
          scheme: 'apk.v1.manifest',
          state: SealState.unknown,
          noteCodes: ['seal.not_parsed'],
        );
      }
      bytes = content;
    } catch (_) {
      return const SealCheck(
        scheme: 'apk.v1.manifest',
        state: SealState.unknown,
        noteCodes: ['seal.not_parsed'],
      );
    }

    final records = _parseManifest(bytes);
    if (records.isEmpty) {
      return const SealCheck(
        scheme: 'apk.v1.manifest',
        state: SealState.unknown,
        noteCodes: ['seal.not_parsed'],
      );
    }

    final checks = <SealEntryCheck>[];
    var checked = 0;
    var mismatch = false;
    var missing = false;
    var notChecked = false;
    final notes = <String>[];
    for (final record in records.entries) {
      if (checks.length >= maxEntries) {
        notChecked = true;
        notes.add('seal.entry_limit');
        break;
      }
      final entry = archive.findFile(record.key);
      if (entry == null || entry.isDirectory) {
        missing = true;
        checks.add(SealEntryCheck(
          path: record.key,
          state: SealState.entryMissing,
          algorithm: record.value.algorithm,
          expectedDigestPrefix: _prefix(record.value.expected),
        ));
        continue;
      }
      if (entry.size > maxEntryBytes) {
        notChecked = true;
        notes.add('seal.digest_unavailable');
        checks.add(SealEntryCheck(
          path: record.key,
          state: SealState.notChecked,
          algorithm: record.value.algorithm,
          expectedDigestPrefix: _prefix(record.value.expected),
        ));
        continue;
      }
      Uint8List entryBytes;
      try {
        final content = entry.content;
        entryBytes = content;
      } catch (_) {
        notChecked = true;
        notes.add('seal.digest_unavailable');
        checks.add(SealEntryCheck(
          path: record.key,
          state: SealState.notChecked,
          algorithm: record.value.algorithm,
          expectedDigestPrefix: _prefix(record.value.expected),
        ));
        continue;
      }
      final actual = digest(record.value.algorithm, entryBytes);
      if (actual == null) {
        notChecked = true;
        notes.add('seal.digest_unavailable');
        checks.add(SealEntryCheck(
          path: record.key,
          state: SealState.notChecked,
          algorithm: record.value.algorithm,
          expectedDigestPrefix: _prefix(record.value.expected),
        ));
        continue;
      }
      checked++;
      final expected = _hex(record.value.expected);
      final normalized = actual.toLowerCase();
      final verified = normalized == expected;
      if (!verified) mismatch = true;
      checks.add(SealEntryCheck(
        path: record.key,
        state: verified ? SealState.verified : SealState.mismatch,
        algorithm: record.value.algorithm,
        expectedDigestPrefix: expected.substring(0, _min(16, expected.length)),
        actualDigestPrefix:
            normalized.substring(0, _min(16, normalized.length)),
      ));
    }

    // 与 iOS CodeResources 同一语义：`notChecked` 只表示一条都没验成。
    // MANIFEST 超过 64 条时已经验过的条目仍然有效；部分覆盖由
    // entriesChecked/entriesTotal + seal.entry_limit 表达。
    final state = mismatch
        ? SealState.mismatch
        : missing
            ? SealState.entryMissing
            : checked > 0
                ? SealState.verified
                : notChecked
                    ? SealState.notChecked
                    : SealState.unknown;

    return SealCheck(
      scheme: 'apk.v1.manifest',
      state: state,
      entriesChecked: checked,
      entriesTotal: records.length,
      checks: checks,
      signatureVerified: false,
      noteCodes: notChecked ? notes.toSet().toList() : const [],
    );
  }

  /// 校验 APK v2 内容摘要（不验签）。
  ///
  /// 算法（AOSP `ApkSigningBlockUtils.computeContentDigest`）：
  /// - 把 APK 去掉签名块后按 1 MiB 分块；
  /// - 每块做 `sha256`；
  /// - 对 `0x5a + uint32(块数) + 各块摘要` 再做一次 `sha256`；
  /// - 与 v2 signed data 里记录的摘要比对。
  ///
  /// **不验证签名**：只证明“内容与签名块记录的摘要一致/不一致”。
  static SealCheck checkV2({
    required ApkSigningSchemes schemes,
    required int fileLength,
    required ApkRangeReader read,
    required ContentDigestFn digest,
  }) =>
      _checkContent(
        schemes: schemes,
        value: schemes.v2Value,
        scheme: 'apk.v2.content',
        fileLength: fileLength,
        read: read,
        digest: digest,
      );

  /// 校验 APK v3 内容摘要（v3-only 包；不验签）。
  ///
  /// v3 signed data 的第一个字段仍是 digests，minSdk/maxSdk 在 signed data
  /// 之后，因此摘要提取与 v2 共用同一段解析。
  static SealCheck checkV3({
    required ApkSigningSchemes schemes,
    required int fileLength,
    required ApkRangeReader read,
    required ContentDigestFn digest,
  }) =>
      _checkContent(
        schemes: schemes,
        value: schemes.v3Value,
        scheme: 'apk.v3.content',
        fileLength: fileLength,
        read: read,
        digest: digest,
      );

  static SealCheck _checkContent({
    required ApkSigningSchemes schemes,
    required Uint8List? value,
    required String scheme,
    required int fileLength,
    required ApkRangeReader read,
    required ContentDigestFn digest,
  }) {
    final blockOffset = schemes.signingBlockOffset;
    final cdOffset = schemes.centralDirOffset;
    final eocdOffset = schemes.eocdOffset;
    if (value == null ||
        blockOffset == null ||
        cdOffset == null ||
        eocdOffset == null) {
      return SealCheck(
        scheme: scheme,
        state: SealState.notChecked,
        noteCodes: ['seal.digest_unavailable'],
      );
    }

    final expected = _v2ExpectedDigest(value);
    if (expected == null) {
      return SealCheck(
        scheme: scheme,
        state: SealState.notChecked,
        noteCodes: ['seal.digest_unavailable'],
      );
    }

    if (blockOffset < 0 || cdOffset > eocdOffset || eocdOffset > fileLength) {
      return SealCheck(
        scheme: scheme,
        state: SealState.unknown,
        noteCodes: ['seal.not_parsed'],
      );
    }

    // AOSP 的 v2 内容摘要有三段：
    // 1) 签名块之前的文件内容；2) 中央目录；3) **改写过的 EOCD**。
    // EOCD 的中央目录偏移必须改成「签名块起点」：验证时签名块被视为不存在，
    // 中央目录紧跟在块起点之后。不改这一处会稳定 mismatch。
    final beforeLength = blockOffset;
    final centralDirLength = eocdOffset - cdOffset;
    final eocdLength = fileLength - eocdOffset;
    final rawEocd = read(eocdOffset, eocdLength);
    if (rawEocd.length != eocdLength || rawEocd.length < 22) {
      return SealCheck(
        scheme: scheme,
        state: SealState.notChecked,
        noteCodes: ['seal.digest_unavailable'],
      );
    }
    final modifiedEocd = Uint8List.fromList(rawEocd);
    _writeU32(modifiedEocd, 16, blockOffset);

    const chunkSize = 1024 * 1024;
    int chunksOf(int length) =>
        length <= 0 ? 0 : (length + chunkSize - 1) ~/ chunkSize;
    final chunkCount = chunksOf(beforeLength) +
        chunksOf(centralDirLength) +
        chunksOf(modifiedEocd.length);
    final aggregate = BytesBuilder();
    aggregate.addByte(0x5a);
    aggregate.add(_u32Bytes(chunkCount));

    bool addSection({
      required int offset,
      required int length,
      Uint8List? bytes,
    }) {
      var consumed = 0;
      while (consumed < length) {
        final take =
            length - consumed < chunkSize ? length - consumed : chunkSize;
        final Uint8List chunk;
        if (bytes != null) {
          chunk = Uint8List.sublistView(bytes, consumed, consumed + take);
        } else {
          chunk = read(offset + consumed, take);
          if (chunk.length != take) return false;
        }
        // AOSP：每个 1 MiB 块的摘要输入是 0xa5 + uint32(chunk 长度) + chunk。
        final prefixed = Uint8List(5 + take)
          ..[0] = 0xa5
          ..setRange(1, 5, _u32Bytes(take))
          ..setRange(5, 5 + take, chunk);
        final chunkDigest = digest(expected.algorithm, prefixed);
        if (chunkDigest == null) return false;
        final raw = _hexToBytes(chunkDigest);
        if (raw == null) return false;
        aggregate.add(raw);
        consumed += take;
      }
      return true;
    }

    if (!addSection(offset: 0, length: beforeLength) ||
        !addSection(offset: cdOffset, length: centralDirLength) ||
        !addSection(
            offset: eocdOffset,
            length: modifiedEocd.length,
            bytes: modifiedEocd)) {
      return SealCheck(
        scheme: scheme,
        state: SealState.notChecked,
        noteCodes: ['seal.digest_unavailable'],
      );
    }

    final actual = digest(expected.algorithm, aggregate.takeBytes());
    if (actual == null) {
      return SealCheck(
        scheme: scheme,
        state: SealState.notChecked,
        noteCodes: ['seal.digest_unavailable'],
      );
    }

    final expectedHex = _hex(expected.bytes);
    final actualHex = actual.toLowerCase();
    final matches = expectedHex == actualHex;
    return SealCheck(
      scheme: scheme,
      state: matches ? SealState.verified : SealState.mismatch,
      entriesChecked: 1,
      entriesTotal: 1,
      checks: [
        SealEntryCheck(
          path: 'APK contents (v2 content digest)',
          state: matches ? SealState.verified : SealState.mismatch,
          algorithm: expected.algorithm,
          expectedDigestPrefix:
              expectedHex.substring(0, _min(16, expectedHex.length)),
          actualDigestPrefix:
              actualHex.substring(0, _min(16, actualHex.length)),
        ),
      ],
      signatureVerified: false,
    );
  }

  /// 从 v2 signed data 里取第一个 SHA-256 摘要（没有则 SHA-512）。
  static _V2Digest? _v2ExpectedDigest(Uint8List value) {
    final signers = _slice(value, 0, value.length);
    if (signers == null) return null;
    final signer = _slice(value, signers.$1, signers.$2);
    if (signer == null) return null;
    final signedData = _slice(value, signer.$1, signer.$2);
    if (signedData == null) return null;
    final digests = _slice(value, signedData.$1, signedData.$2);
    if (digests == null) return null;

    _V2Digest? sha512;
    var cursor = digests.$1;
    while (cursor + 4 <= digests.$2) {
      final record = _slice(value, cursor, digests.$2);
      if (record == null) break;
      if (record.$1 + 4 > record.$2) break;
      final algId = _u32(value, record.$1);
      final digestField = _slice(value, record.$1 + 4, record.$2);
      if (digestField != null) {
        final bytes = Uint8List.sublistView(
          value,
          digestField.$1,
          digestField.$2,
        );
        final result = _digestFor(algId, bytes);
        if (result != null) {
          if (result.algorithm == 'sha256') return result;
          sha512 = result;
        }
      }
      cursor = record.$2;
    }
    return sha512;
  }

  static _V2Digest? _digestFor(int algId, Uint8List bytes) => switch (algId) {
        0x0101 || 0x0103 || 0x0201 || 0x0301 => _V2Digest('sha256', bytes),
        0x0102 || 0x0104 || 0x0202 => _V2Digest('sha512', bytes),
        _ => null,
      };

  static (int, int)? _slice(Uint8List data, int start, int end) {
    if (start < 0 || start + 4 > end || end > data.length) return null;
    final length = _u32(data, start);
    if (length <= 0) return null;
    final contentStart = start + 4;
    final contentEnd = contentStart + length;
    if (contentEnd > end || contentEnd > data.length) return null;
    return (contentStart, contentEnd);
  }

  static int _u32(Uint8List bytes, int offset) =>
      bytes[offset] |
      (bytes[offset + 1] << 8) |
      (bytes[offset + 2] << 16) |
      (bytes[offset + 3] << 24);

  static void _writeU32(Uint8List bytes, int offset, int value) {
    bytes[offset] = value & 0xff;
    bytes[offset + 1] = (value >> 8) & 0xff;
    bytes[offset + 2] = (value >> 16) & 0xff;
    bytes[offset + 3] = (value >> 24) & 0xff;
  }

  static Uint8List _u32Bytes(int value) => Uint8List.fromList([
        value & 0xff,
        (value >> 8) & 0xff,
        (value >> 16) & 0xff,
        (value >> 24) & 0xff,
      ]);

  static Uint8List? _hexToBytes(String hex) {
    if (hex.length.isOdd) return null;
    final out = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      final value = int.tryParse(hex.substring(i * 2, i * 2 + 2), radix: 16);
      if (value == null) return null;
      out[i] = value;
    }
    return out;
  }

  /// 解析 MANIFEST.MF 的 `Name:` / `SHA-256-Digest:` 记录。
  ///
  /// 支持 RFC 822 的续行（以空格开头）—— 真实 APK 的 base64 摘要可能被折行。
  static Map<String, _DigestRecord> _parseManifest(Uint8List bytes) {
    final text = latin1.decode(bytes, allowInvalid: true);
    final records = <String, _DigestRecord>{};
    String? name;
    final headers = <String, String>{};
    String? lastHeader;

    void flush() {
      if (name != null) {
        final alg = headers.containsKey('SHA-256-Digest')
            ? 'sha256'
            : headers.containsKey('SHA1-Digest')
                ? 'sha1'
                : null;
        final raw = headers['SHA-256-Digest'] ?? headers['SHA1-Digest'];
        if (alg != null && raw != null) {
          final expected = _base64(raw.trim());
          if (expected != null) {
            records[name!] = _DigestRecord(alg, expected);
          }
        }
      }
      name = null;
      headers.clear();
      lastHeader = null;
    }

    for (final rawLine in text.split('\n')) {
      final line = rawLine.endsWith('\r')
          ? rawLine.substring(0, rawLine.length - 1)
          : rawLine;
      if (line.isEmpty) {
        flush();
        continue;
      }
      if (line.startsWith(' ') && lastHeader != null) {
        headers[lastHeader!] = '${headers[lastHeader!] ?? ''}${line.trim()}';
        continue;
      }
      final colon = line.indexOf(':');
      if (colon <= 0) continue;
      final key = line.substring(0, colon).trim();
      final value = line.substring(colon + 1).trim();
      headers[key] = value;
      lastHeader = key;
      if (key == 'Name') name = value;
    }
    flush();
    return records;
  }

  static Uint8List? _base64(String value) {
    try {
      return base64Decode(value);
    } catch (_) {
      return null;
    }
  }

  static String _hex(Uint8List bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  static String _prefix(Uint8List bytes) {
    final hex = _hex(bytes);
    return hex.substring(0, _min(16, hex.length));
  }

  static int _min(int a, int b) => a < b ? a : b;
}

class _DigestRecord {
  final String algorithm;
  final Uint8List expected;

  const _DigestRecord(this.algorithm, this.expected);
}

class _V2Digest {
  final String algorithm;
  final Uint8List bytes;

  const _V2Digest(this.algorithm, this.bytes);
}
