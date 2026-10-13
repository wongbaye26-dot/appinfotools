import 'dart:io';

import 'package:apk_info_tool/utils/format.dart';
import 'package:apk_info_tool/utils/zip_guard.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

void main() {
  group('formatFileSize', () {
    test('returns empty string for null', () {
      expect(formatFileSize(null), '');
    });

    test('formats plain byte counts', () {
      expect(formatFileSize(0), '0 B');
      expect(formatFileSize(1), '1 B');
      expect(formatFileSize(512), '512 B');
      expect(formatFileSize(1023), '1023 B');
    });

    test('promotes to KB at the 1024 boundary', () {
      expect(formatFileSize(1024), '1 KB');
      expect(formatFileSize(1536), '1.5 KB');
    });

    test('regression: 1048575 must be 1 MB, not "1024 KB"', () {
      // 1048575 == 1024*1024 - 1. The old implementation rounded to two
      // decimals while still in the KB unit, producing the nonsensical
      // "1024 KB" instead of rolling over to the next unit.
      expect(formatFileSize(1048575), '1 MB');
      expect(formatFileSize(1048576), '1 MB');
      expect(formatFileSize(1048577), '1 MB');
    });

    test('never emits a value >= 1024 for a non-terminal unit', () {
      for (final bytes in [1048575, 1048576, 1073741823, 1073741824]) {
        final text = formatFileSize(bytes);
        final value = double.parse(text.split(' ').first);
        expect(value, lessThan(1024), reason: '$bytes -> "$text"');
      }
    });

    test('formats large sizes', () {
      expect(formatFileSize(1099511627776), '1 TB');
      expect(formatFileSize(999999999999), '931.32 GB');
    });

    test('handles negative sizes', () {
      expect(formatFileSize(-2048), '-2 KB');
    });
  });

  group('ZipGuard.safeJoin', () {
    final root = path.join(Directory.systemTemp.path, 'zip_guard_test');

    test('joins a normal nested entry', () {
      final result = ZipGuard.safeJoin(root, 'Android/obb/pkg/main.7.com.obb');
      expect(
          path.isWithin(path.normalize(path.absolute(root)), result), isTrue);
    });

    test('normalises backslash separators', () {
      final result = ZipGuard.safeJoin(root, r'lib\arm64-v8a\libfoo.so');
      expect(
          path.isWithin(path.normalize(path.absolute(root)), result), isTrue);
    });

    test('rejects parent traversal', () {
      expect(
        () => ZipGuard.safeJoin(root, '../../etc/passwd'),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => ZipGuard.safeJoin(root, 'a/b/../../../evil'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rejects absolute POSIX paths', () {
      expect(
        () => ZipGuard.safeJoin(root, '/etc/passwd'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rejects Windows drive-letter paths', () {
      expect(
        () => ZipGuard.safeJoin(root, r'C:\Windows\System32\cmd.exe'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rejects UNC paths', () {
      expect(
        () => ZipGuard.safeJoin(root, r'\\server\share\evil.exe'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rejects tilde expansion', () {
      expect(
        () => ZipGuard.safeJoin(root, '~/.ssh/authorized_keys'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rejects an empty entry name', () {
      expect(
        () => ZipGuard.safeJoin(root, ''),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('allows traversal-looking but contained names', () {
      // "a..b" is a legitimate file name and must not be rejected.
      final result = ZipGuard.safeJoin(root, 'res/drawable/a..b.png');
      expect(
          path.isWithin(path.normalize(path.absolute(root)), result), isTrue);
    });
  });
}
