// aapt2 模式下**也要**跑安全审计。
//
// ## 这条守的是什么
//
// `getApkInfo` 有两条路：内建解析（worker：manifest + DEX + 安全审计）与
// aapt2（只给元数据）。aapt2 分支此前直接 `return`，于是把解析引擎设成
// aapt2 的用户看到的是「安全 未检测」—— 而日志里 `aapt2 exitCode=0` 一切正常，
// 看不出任何错误。实测就是这样被用户报上来的。
//
// ## 为什么可能跳过
//
// 需要机器上有 aapt2。CI 上没有，所以 `AAPT2` 没设且找不到时跳过 ——
// **跳过不等于通过**，这条只在有 aapt2 的机器上真正生效。

import 'dart:io';

import 'package:apk_info_tool/apkparser/apk_info.dart';
import 'package:apk_info_tool/config.dart';
import 'package:apk_info_tool/utils/command_tools.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('解析引擎选 aapt2 时，安全审计仍然产出结果', () async {
    final aapt2 = Platform.environment['AAPT2'] ?? CommandTools.findAapt2Path();
    if (aapt2 == null || aapt2.isEmpty || !File(aapt2).existsSync()) {
      markTestSkipped('没有 aapt2（设 AAPT2=/path/to/aapt2），跳过');
      return;
    }

    SharedPreferences.setMockInitialValues({});
    Config.gPrefs = await SharedPreferences.getInstance();
    await Config.parserEngine.updateValue(Config.kParserAapt2);
    await Config.aapt2Source.updateValue(Config.kToolSourceCustom);
    await Config.aapt2Path.updateValue(aapt2);
    await Config.enableSecurityAudit.updateValue(true);

    final apk = Platform.environment['AAPT2_APK'] ??
        'test/fixtures/apk/signed-v2-v3.apk';
    final info = await getApkInfo(apk);
    expect(info, isNotNull, reason: 'aapt2 路径本身要能解析出元数据');
    expect(
      info!.securityResult,
      isNotNull,
      reason: 'aapt2 只给元数据，但安全审计必须照跑 —— '
          '否则界面显示「安全 未检测」，用户会以为工具坏了',
    );
  }, timeout: const Timeout(Duration(minutes: 5)));
}
