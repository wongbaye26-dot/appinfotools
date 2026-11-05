import 'package:apk_info_tool/utils/adb_install_error.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('从混杂输出里提取失败码', () {
    expect(
      adbInstallFailureCode(
        'Performing Streamed Install\nadb: failed to install x.apk: '
        'Failure [INSTALL_FAILED_ALREADY_EXISTS: ...]',
      ),
      'INSTALL_FAILED_ALREADY_EXISTS',
    );
    expect(
      adbInstallFailureCode('Failure [INSTALL_PARSE_FAILED_NO_CERTIFICATES]'),
      'INSTALL_PARSE_FAILED_NO_CERTIFICATES',
    );
  });

  test('没有失败码时返回 null', () {
    expect(adbInstallFailureCode('error: no devices/emulators found'), isNull);
  });
}
