import 'package:analysis_model/analysis_model.dart';
import 'package:apk_parser/apk_parser.dart';
import 'package:test/test.dart';

void main() {
  test('常见高危权限已编目，不再落入 UNCATEGORIZED', () {
    final byName = {
      for (final rule in PermissionCatalog.rules) rule.name: rule,
    };
    for (final name in [
      'READ_SMS',
      'READ_CALL_LOG',
      'READ_CALENDAR',
      'POST_NOTIFICATIONS',
    ]) {
      expect(byName.containsKey(name), isTrue, reason: name);
    }
    expect(byName['READ_SMS']!.baseSeverity, SecuritySeverity.p3);
    expect(byName['READ_CALL_LOG']!.baseSeverity, SecuritySeverity.p3);
    expect(byName['READ_CALENDAR']!.baseSeverity, SecuritySeverity.p3);
    expect(byName['POST_NOTIFICATIONS']!.baseSeverity, SecuritySeverity.info);
    expect(byName['POST_NOTIFICATIONS']!.minApi, 33);
  });
}
