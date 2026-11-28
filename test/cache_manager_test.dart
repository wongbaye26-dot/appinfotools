// 缓存清理：范围必须**只有可重建的东西**。
//
// 这里钉住两件最容易越界的事：
// 1. 不能顺手删 `debug.log` 本身（当前写入流还开着，删除在各平台上行为不一）；
// 2. 不能删到配置 / 最近分析 / 下载的工具 —— 那些是用户数据或离线能力。
//
// 盘点与清理都接收注入的 supportDir，测试不碰真实应用数据目录。

import 'dart:io';

import 'package:apk_info_tool/utils/cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('cache_manager_test');
    final icons = Directory(p.join(root.path, 'recent_icons'))
      ..createSync(recursive: true);
    File(p.join(icons.path, 'a.png')).writeAsBytesSync(List.filled(1000, 1));
    File(p.join(icons.path, 'b.png')).writeAsBytesSync(List.filled(500, 2));
    File(p.join(root.path, 'debug.log')).writeAsStringSync('current log');
    File(p.join(root.path, 'debug.log.1')).writeAsStringSync('x' * 300);
    File(p.join(root.path, 'debug.log.2')).writeAsStringSync('y' * 200);
    // 用户数据：绝不能被动。
    File(p.join(root.path, 'config.json')).writeAsStringSync('{"a":1}');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('盘点只算缩略图与日志备份', () async {
    final usage = await CacheManager.inspect(supportDir: root);
    expect(usage.iconBytes, 1500);
    expect(usage.logBytes, 500);
    expect(usage.total, 2000);
  });

  test('清理后缩略图与备份消失，当前日志与用户数据保留', () async {
    final freed = await CacheManager.clear(supportDir: root);
    expect(freed.total, 2000);

    final icons = Directory(p.join(root.path, 'recent_icons'));
    expect(icons.listSync(), isEmpty);
    expect(File(p.join(root.path, 'debug.log')).existsSync(), isTrue);
    expect(File(p.join(root.path, 'debug.log.1')).existsSync(), isFalse);
    expect(File(p.join(root.path, 'debug.log.2')).existsSync(), isFalse);
    expect(File(p.join(root.path, 'config.json')).existsSync(), isTrue);

    final after = await CacheManager.inspect(supportDir: root);
    expect(after.total, 0);
  });

  test('没有缓存目录时是 0，不是异常', () async {
    final empty = await Directory.systemTemp.createTemp('cache_empty');
    addTearDown(() => empty.delete(recursive: true));
    final usage = await CacheManager.inspect(supportDir: empty);
    expect(usage.total, 0);
    expect((await CacheManager.clear(supportDir: empty)).total, 0);
  });

  test('字节格式化沿用工具里的习惯写法', () {
    expect(CacheManager.formatBytes(0), '0 B');
    expect(CacheManager.formatBytes(999), '999 B');
    expect(CacheManager.formatBytes(1536), '1.5 KB');
    expect(CacheManager.formatBytes(12 * 1024 * 1024), '12.0 MB');
  });
}
