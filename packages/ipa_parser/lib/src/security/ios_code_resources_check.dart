import 'dart:convert';
import 'dart:typed_data';

import 'package:analysis_model/analysis_model.dart';
import 'package:archive/archive.dart';
import 'package:archive_safety/archive_safety.dart';

import '../ipa_container.dart';
import '../plist/plist_parser.dart';
import '../plist/plist_value.dart';

/// 一条 CodeResources 记录。
class _SealRecord {
  final String algorithm;

  /// 期望摘要（原始字节；v1 的 base64 已解码）。
  final Uint8List expected;

  const _SealRecord(this.algorithm, this.expected);
}

/// iOS `_CodeSignature/CodeResources` 的逐文件摘要校验。
///
/// **只验证摘要一致性，不验证签名**：`signatureVerified` 恒为 `false`。
/// 重签名工具会重算 CodeResources，因此“校验通过”不代表未被注入；
/// 它抓的是“改了文件但没重签”。
class IosCodeResourcesCheck {
  IosCodeResourcesCheck._();

  static const String _codeResourcesPath = '_CodeSignature/CodeResources';

  /// 最多校验 64 个文件（契约 C12）。
  static const int maxEntries = 64;

  /// 单文件读取上限（32 MiB）。
  static const int maxEntryBytes = 32 * 1024 * 1024;

  /// 全部文件读取/哈希的总预算（64 MiB，契约 C12）。
  static const int maxTotalBytes = 64 * 1024 * 1024;

  static SealCheck check({
    required Archive archive,
    required IosBundle bundle,
    required ContentDigestFn digest,
    BoundedReadLedger? ledger,
  }) {
    final path = '${bundle.path}/$_codeResourcesPath';
    final entry = archive.findFile(path);
    if (entry == null) {
      return const SealCheck(
        scheme: 'ipa.codeResources.v2',
        state: SealState.unsealed,
        noteCodes: ['seal.not_parsed'],
      );
    }

    final budget = ledger ?? BoundedReadLedger.session();
    final read = readEntryBounded(
      entry,
      maxEntryBytes: 8 * 1024 * 1024,
      ledger: budget,
    );
    if (!read.isOk || read.bytes == null) {
      return const SealCheck(
        scheme: 'ipa.codeResources.v2',
        state: SealState.unknown,
        noteCodes: ['seal.not_parsed'],
      );
    }

    final PlistValue value;
    try {
      value = PlistParser.parse(read.bytes!);
    } catch (_) {
      return const SealCheck(
        scheme: 'ipa.codeResources.v2',
        state: SealState.unknown,
        noteCodes: ['seal.not_parsed'],
      );
    }
    if (value is! PlistDict) {
      return const SealCheck(
        scheme: 'ipa.codeResources.v2',
        state: SealState.unknown,
        noteCodes: ['seal.not_parsed'],
      );
    }

    final files = value.value['files'];
    final files2 = value.value['files2'];
    final records = <String, _SealRecord>{};
    if (files2 is PlistDict) {
      for (final item in files2.value.entries) {
        final record = _recordFromV2(item.value);
        if (record != null) records[_normalize(item.key)] = record;
      }
    }
    if (files is PlistDict) {
      for (final item in files.value.entries) {
        final key = _normalize(item.key);
        if (records.containsKey(key)) continue; // v2 优先
        final record = _recordFromV1(item.value);
        if (record != null) records[key] = record;
      }
    }

    // 大包 CodeResources 有上千条；64 条预算必须优先给代码/清单，
    // 否则前 64 条可能全是资源，真正的可执行文件一个都没验。
    final ordered = records.entries.toList()
      ..sort((a, b) => _priority(a.key).compareTo(_priority(b.key)));
    final checks = <SealEntryCheck>[];
    var checked = 0;
    var checkedBytes = 0;
    var mismatch = false;
    var missing = false;
    var notChecked = false;
    final notes = <String>['seal.digest_unavailable'];
    for (final item in ordered) {
      if (checks.length >= maxEntries) {
        // 只校验了前 64 个；不能把「没看完」说成「全部一致」。
        notChecked = true;
        notes.add('seal.entry_limit');
        break;
      }
      final relative = item.key;
      final archivePath = '${bundle.path}/$relative';
      final target = archive.findFile(archivePath);
      if (target == null || target.isDirectory) {
        missing = true;
        checks.add(SealEntryCheck(
          path: archivePath,
          state: SealState.entryMissing,
          algorithm: item.value.algorithm,
          expectedDigestPrefix: _prefix(item.value.expected),
        ));
        continue;
      }
      if (target.size > maxEntryBytes ||
          checkedBytes + target.size > maxTotalBytes) {
        // 大包的主可执行文件/大型资源可能单条就几十 MB；全读会显著抬高
        // 峰值内存。预算内能验多少验多少，其余如实记为未覆盖。
        notChecked = true;
        notes.add('seal.entry_limit');
        checks.add(SealEntryCheck(
          path: archivePath,
          state: SealState.notChecked,
          algorithm: item.value.algorithm,
          expectedDigestPrefix: _prefix(item.value.expected),
        ));
        continue;
      }
      final data = readEntryBounded(
        target,
        maxEntryBytes: maxEntryBytes,
        ledger: budget,
      );
      if (!data.isOk || data.bytes == null) {
        notChecked = true;
        checks.add(SealEntryCheck(
          path: archivePath,
          state: SealState.notChecked,
          algorithm: item.value.algorithm,
          expectedDigestPrefix: _prefix(item.value.expected),
        ));
        continue;
      }
      final actual = digest(item.value.algorithm, data.bytes!);
      checked++;
      checkedBytes += target.size;
      if (actual == null) {
        notChecked = true;
        checks.add(SealEntryCheck(
          path: archivePath,
          state: SealState.notChecked,
          algorithm: item.value.algorithm,
          expectedDigestPrefix: _prefix(item.value.expected),
        ));
        continue;
      }
      final expected = _hex(item.value.expected);
      final normalizedActual = actual.toLowerCase();
      if (normalizedActual != expected) {
        mismatch = true;
        checks.add(SealEntryCheck(
          path: archivePath,
          state: SealState.mismatch,
          algorithm: item.value.algorithm,
          expectedDigestPrefix:
              expected.substring(0, _min(16, expected.length)),
          actualDigestPrefix:
              normalizedActual.substring(0, _min(16, normalizedActual.length)),
        ));
      } else {
        checks.add(SealEntryCheck(
          path: archivePath,
          state: SealState.verified,
          algorithm: item.value.algorithm,
          expectedDigestPrefix:
              expected.substring(0, _min(16, expected.length)),
          actualDigestPrefix:
              normalizedActual.substring(0, _min(16, normalizedActual.length)),
        ));
      }
    }

    final state = mismatch
        ? SealState.mismatch
        : missing
            ? SealState.entryMissing
            : notChecked
                ? SealState.notChecked
                : checked > 0
                    ? SealState.verified
                    : SealState.unknown;

    return SealCheck(
      scheme:
          files2 is PlistDict ? 'ipa.codeResources.v2' : 'ipa.codeResources.v1',
      state: state,
      entriesChecked: checked,
      entriesTotal: records.length,
      checks: checks,
      signatureVerified: false,
      noteCodes:
          state == SealState.notChecked ? notes.toSet().toList() : const [],
    );
  }

  /// 64 条预算内的优先级：清单/可执行代码优先，资源最后。
  static int _priority(String path) {
    final lower = path.toLowerCase();
    if (lower == 'info.plist') return 0;
    if (lower.endsWith('.dylib')) return 1;
    if (lower.startsWith('frameworks/')) return 2;
    if (lower.startsWith('plugins/') || lower.startsWith('watch/')) return 3;
    if (!path.contains('/')) return 4;
    return 9;
  }

  static _SealRecord? _recordFromV1(PlistValue value) {
    if (value is PlistString) {
      final bytes = _base64(value.value);
      return bytes == null ? null : _SealRecord('sha1', bytes);
    }
    if (value is PlistDict) {
      final hash = value.value['hash'];
      if (hash is PlistData) return _SealRecord('sha1', hash.value);
    }
    return null;
  }

  static _SealRecord? _recordFromV2(PlistValue value) {
    if (value is! PlistDict) return null;
    final hash2 = value.value['hash2'];
    if (hash2 is PlistData) return _SealRecord('sha256', hash2.value);
    final hash = value.value['hash'];
    if (hash is PlistData) return _SealRecord('sha1', hash.value);
    return null;
  }

  static String _normalize(String path) {
    var out = path.replaceAll('\\', '/');
    while (out.startsWith('./')) {
      out = out.substring(2);
    }
    while (out.startsWith('/')) {
      out = out.substring(1);
    }
    return out;
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
