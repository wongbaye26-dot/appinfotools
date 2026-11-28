import 'package:analysis_model/analysis_model.dart';
import 'package:test/test.dart';

void main() {
  Map<String, Object?> validJson() => {
        'schemaVersion': 1,
        'id': 'full',
        'name': 'Full Scan',
        'version': '1.0.0',
        'platforms': ['android', 'ios'],
        'scanners': ['manifest', 'permissions', 'secrets'],
        'budgets': {'maxTotalBytes': 1073741824, 'maxEntries': 20000},
        'rulePacks': ['core/android'],
        'thresholds': {'failOn': 'high'},
      };

  group('ScanProfile', () {
    test('合法 JSON 解析成功并保留字段顺序无关的语义', () {
      final profile = ScanProfile.fromJson(validJson());
      expect(profile.id, 'full');
      expect(profile.platforms, ['android', 'ios']);
      expect(profile.scanners, [
        ScanStage.manifest,
        ScanStage.permissions,
        ScanStage.secrets,
      ]);
      expect(profile.budgets.maxTotalBytes, 1073741824);
      expect(profile.thresholds['failOn'], 'high');
    });

    test('toJson / fromJson 往返一致', () {
      final profile = ScanProfile.fromJson(validJson());
      final restored = ScanProfile.fromJson(profile.toJson());
      expect(restored.toJson(), profile.toJson());
    });

    test('未知扫描阶段整体拒绝，并给出字段名', () {
      final json = validJson()..['scanners'] = ['manifest', 'madeUp'];
      expect(
        () => ScanProfile.fromJson(json),
        throwsA(isA<ScanProfileException>().having(
          (e) => e.issues.join('\n'),
          'issues',
          contains('未知扫描阶段'),
        )),
      );
    });

    test('未知平台、缺必填、预算超硬上限都拒绝', () {
      expect(
        () => ScanProfile.fromJson(
            validJson()..['platforms'] = ['android', 'windows']),
        throwsA(isA<ScanProfileException>()),
      );
      expect(
        () => ScanProfile.fromJson(validJson()..remove('id')),
        throwsA(isA<ScanProfileException>()),
      );
      expect(
        () => ScanProfile.fromJson(validJson()
          ..['budgets'] = {'maxTotalBytes': ScanBudgets.hardMaxTotalBytes + 1}),
        throwsA(isA<ScanProfileException>()),
      );
      expect(
        () =>
            ScanProfile.fromJson(validJson()..['budgets'] = {'maxEntries': 0}),
        throwsA(isA<ScanProfileException>()),
      );
    });

    test('多个问题一次返回，不是遇到第一个就停', () {
      final json = validJson()
        ..['platforms'] = ['linux']
        ..['scanners'] = ['nope']
        ..remove('version');
      try {
        ScanProfile.fromJson(json);
        fail('应当抛异常');
      } on ScanProfileException catch (e) {
        expect(e.issues.length, greaterThanOrEqualTo(3));
      }
    });

    test('不支持的 schemaVersion 拒绝', () {
      expect(
        () => ScanProfile.fromJson(validJson()..['schemaVersion'] = 2),
        throwsA(isA<ScanProfileException>()),
      );
    });
  });
}
