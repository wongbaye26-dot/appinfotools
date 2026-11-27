import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/utils/html_report.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('HTML 报告转义不可信字段，不注入脚本', () {
    final html = HtmlReport.render({
      'inputArtifact': {
        'fileName': '<script>alert(1)</script>',
        'sizeBytes': 1,
        'sha256': '" onload="alert(2)',
      },
      'application': {
        'appName': '<img src=x onerror=alert(3)>',
        'packageId': '<b>pkg</b>',
        'version': '1.0',
        'platform': 'android',
      },
      'findings': [
        {
          'ruleId': '<script>rule</script>',
          'severity': 'high',
          'confidence': 'confirmed',
          'finding': '<script>finding</script>',
          'evidence': [
            {'source': '<script>source</script>', 'location': '<b>loc</b>'},
          ],
        },
      ],
    }, t);

    expect(html, isNot(contains('<script>alert')));
    expect(html, isNot(contains('<img src=x')));
    expect(html, contains('&lt;img src=x onerror=alert(3)&gt;'));
    expect(html, contains('&lt;script&gt;rule&lt;&#47;script&gt;'));
    expect(html, contains('&lt;script&gt;finding&lt;&#47;script&gt;'));
  });
}
