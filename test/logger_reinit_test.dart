// 调试日志开关的重新初始化。
//
// 设置页切换「调试日志」时会先 dispose()（取消根监听）再 init()。此前 init()
// 只负责打开文件，不重新注册监听 —— 于是开关一开，日志就永久停止写入。
// 2.10.4 的分段计时已经打出来了，用户却拿不到，根因在这一层。

import 'dart:io';

import 'package:apk_info_tool/config.dart';
import 'package:apk_info_tool/utils/logger.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late Directory tmp;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    Config.gPrefs = await SharedPreferences.getInstance();
  });

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('logger_reinit');
    await Config.enableDebug.updateValue(true);
  });

  tearDown(() async {
    await LoggerInit.instance.dispose();
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  test('关闭再打开调试日志后，新的日志仍写进同一个文件', () async {
    await LoggerInit.initLogger();
    await LoggerInit.instance.init(logDirectory: tmp);

    log.info('MARKER_BEFORE_TOGGLE');
    await LoggerInit.instance.flush();
    final before = File('${tmp.path}/debug.log').readAsStringSync();
    expect(before, contains('MARKER_BEFORE_TOGGLE'));

    // 复现设置页的开关流程：dispose → init。
    await LoggerInit.instance.dispose();
    await LoggerInit.instance.init(logDirectory: tmp);

    log.info('MARKER_AFTER_TOGGLE');
    await LoggerInit.instance.flush();
    final after = File('${tmp.path}/debug.log').readAsStringSync();
    expect(after, contains('MARKER_AFTER_TOGGLE'));
  });

  test('重复初始化不会重复订阅，一条日志只写一次', () async {
    await LoggerInit.initLogger();
    await LoggerInit.initLogger();
    await LoggerInit.instance.init(logDirectory: tmp);

    log.info('MARKER_ONCE');
    await LoggerInit.instance.flush();
    final text = File('${tmp.path}/debug.log').readAsStringSync();
    expect('MARKER_ONCE'.allMatches(text).length, 1);
  });

  test('调试关闭后 root level 回到 INFO，文件不再写入', () async {
    await LoggerInit.initLogger();
    await LoggerInit.instance.init(logDirectory: tmp);
    await Config.enableDebug.updateValue(false);
    await LoggerInit.instance.dispose();
    await LoggerInit.instance.init(logDirectory: tmp);

    expect(Logger.root.level, Level.INFO);
    expect(LoggerInit.instance.logFilePath, isNull);
  });
}
