import 'package:apk_info_tool/utils/baseline_entry_id.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('稳定 id：小写、非法字符归一、64 字符截断', () {
    expect(
        buildBaselineEntryId(platform: 'android', packageId: 'com.Example.App'),
        'android.com.example.app');
    expect(buildBaselineEntryId(platform: 'ios', packageId: 'Top.Model'),
        'ios.top.model');
    final long = buildBaselineEntryId(
      platform: 'android',
      packageId: 'com.${'a' * 100}',
    );
    expect(long.length, 64);
    expect(long.startsWith('android.com.'), isTrue);
  });
}
