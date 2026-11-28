import 'package:apk_info_tool/config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('系统文件图标默认关闭，安装/启动不能自动写注册表', () {
    // 配置只是「用户上次成功操作的结果」；默认必须是 false。
    // 启动路径不再读取它做自动注册（见 lib/main.dart），因此这里同时守住
    // 默认值，避免以后又被改回 true。
    expect(Config.systemIconEnabled.value, isFalse);
  });
}
