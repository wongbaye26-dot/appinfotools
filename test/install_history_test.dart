// 安装历史（安装页「最近安装」与文件条的「未安装过」都读它）。
//
// 这块此前只存在内存里，页面一关就清空 —— 用户第二天回来会以为上次安装
// 失败了。落盘之后要钉住三件事：跨重启仍在、同一包的成功记录能查到、
// 上限 10 条且清空真的清空。

import 'package:apk_info_tool/config.dart';
import 'package:apk_info_tool/utils/install_history.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 每个用例从「全新安装」开始：必须显式写 `install_history` 键，
/// 否则 `ConfigItem.loadValue()` 会沿用进程内上一个用例留下的值。
Future<void> _freshInstall() async {
  SharedPreferences.setMockInitialValues(<String, Object>{
    'install_history': '[]',
  });
  await Config.init();
  await Config.loadConfig();
}

Future<void> _flushConfig() => Config.flushAll();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(_flushConfig);

  test('空列表必须是可变列表（add 会就地插入）', () async {
    await _freshInstall();
    final entries = InstallHistoryManager.load();
    expect(entries, isEmpty);
    expect(() => entries.insert(0, _record()), returnsNormally);
  });

  test('记录落盘，重新 load 仍在，并按时间倒序', () async {
    await _freshInstall();
    await InstallHistoryManager.add(
      _record(fileName: 'old.apk', at: DateTime(2026, 11, 20, 10)),
    );
    await InstallHistoryManager.add(
      _record(fileName: 'new.apk', at: DateTime(2026, 11, 21, 10)),
    );
    await _flushConfig();

    final loaded = InstallHistoryManager.load();
    expect(loaded.map((e) => e.fileName), ['new.apk', 'old.apk']);
    expect(loaded.first.ok, isTrue);
    expect(loaded.first.packageName, 'com.example.demo');
  });

  test('上限 10 条，超出丢最旧的', () async {
    await _freshInstall();
    for (var i = 0; i < 12; i++) {
      await InstallHistoryManager.add(_record(fileName: 'p$i.apk'));
    }
    final loaded = InstallHistoryManager.load();
    expect(loaded.length, 10);
    expect(loaded.first.fileName, 'p11.apk');
    expect(loaded.last.fileName, 'p2.apk');
  });

  test('wasInstalled 只认成功的同包记录', () async {
    await _freshInstall();
    await InstallHistoryManager.add(
      _record(packageName: 'com.example.failed', ok: false),
    );
    await InstallHistoryManager.add(
      _record(packageName: 'com.example.ok', ok: true),
    );

    expect(InstallHistoryManager.wasInstalled('com.example.ok'), isTrue);
    expect(InstallHistoryManager.wasInstalled('com.example.failed'), isFalse);
    expect(InstallHistoryManager.wasInstalled(null), isFalse);
    expect(InstallHistoryManager.wasInstalled(''), isFalse);
  });

  test('坏掉的 JSON 不抛异常，按空历史处理', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'install_history': 'not json',
    });
    await Config.init();
    await Config.loadConfig();
    expect(InstallHistoryManager.load(), isEmpty);
  });

  test('clear 之后彻底为空', () async {
    await _freshInstall();
    await InstallHistoryManager.add(_record());
    await InstallHistoryManager.clear();
    expect(InstallHistoryManager.load(), isEmpty);
  });
}

InstallRecord _record({
  String fileName = 'demo.apk',
  String packageName = 'com.example.demo',
  bool ok = true,
  DateTime? at,
}) =>
    InstallRecord(
      fileName: fileName,
      size: '18.4 MB',
      device: 'Pixel 8',
      packageName: packageName,
      ok: ok,
      at: at ?? DateTime(2026, 11, 21, 14, 32),
    );
