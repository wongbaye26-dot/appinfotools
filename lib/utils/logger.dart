import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:apk_info_tool/config.dart';
import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

final log = Logger('ExampleLogger');

class LoggerInit {
  static final LoggerInit _instance = LoggerInit._internal();
  static LoggerInit get instance => _instance;

  LoggerInit._internal();

  File? _logFile;
  IOSink? _logSink;
  StreamSubscription<LogRecord>? _logSubscription;

  /// 日志文件最大大小: 2MB
  static const int _maxLogFileSize = 2 * 1024 * 1024;

  /// 保留的旧日志文件数量
  static const int _maxBackupFiles = 1;

  /// 时间戳格式
  static final DateFormat _timeFormat = DateFormat('yyyy-MM-dd HH:mm:ss.SSS');

  static String _formatTime(DateTime time) {
    return _timeFormat.format(time);
  }

  /// 注册根监听。可重复调用：已有监听时只调整级别，不重复订阅。
  ///
  /// 此前这里直接给 `_logSubscription` 赋值，而设置页切换调试开关的流程是
  /// `dispose()`（取消订阅）→ `init()`（只开文件、不重新订阅）。结果是用户
  /// 一打开「调试日志」，日志就永久停止写入 —— 2.10.4 拿不到 `[PERF]` 分段
  /// 行是日志管线断掉了，不是计时代码没打。
  static Future<void> initLogger() async {
    instance._ensureListening();
  }

  void _ensureListening() {
    Logger.root.level = Config.enableDebug.value ? Level.FINE : Level.INFO;
    if (_logSubscription != null) return;
    _logSubscription = Logger.root.onRecord.listen((record) {
      if (!kReleaseMode) {
        developer.log(
            '${record.level.name}: ${_formatTime(record.time)}: ${record.message}');
      }
      instance.log(record);
    });
  }

  /// [logDirectory] 只给测试注入；正式运行始终用应用数据目录。
  Future<void> init({Directory? logDirectory}) async {
    // dispose() 会取消订阅，所以每次 init 都要确保监听器重新在场。
    _ensureListening();
    if (!Config.enableDebug.value) return;
    final appDir = logDirectory ?? await getApplicationSupportDirectory();
    final logPath = path.join(appDir.path, 'debug.log');
    _logFile = File(logPath);
    await _rotateIfNeeded();
    _logSink = _logFile?.openWrite(mode: FileMode.append);
  }

  /// 测试 / 退出前把缓冲的日志落盘。
  Future<void> flush() => _logSink?.flush() ?? Future<void>.value();

  /// 检查日志文件大小，必要时进行轮换
  Future<void> _rotateIfNeeded() async {
    final file = _logFile;
    if (file == null || !file.existsSync()) return;

    final fileSize = await file.length();
    if (fileSize < _maxLogFileSize) return;

    // 关闭当前写入流
    await _logSink?.flush();
    await _logSink?.close();
    _logSink = null;

    final logDir = file.parent.path;
    final baseName = path.basenameWithoutExtension(file.path);
    final ext = path.extension(file.path);

    // 删除超出保留数量的旧日志
    for (var i = _maxBackupFiles; i >= 1; i--) {
      final older = File(path.join(logDir, '$baseName.$i$ext'));
      if (i == _maxBackupFiles && older.existsSync()) {
        await older.delete();
      } else if (older.existsSync() && i < _maxBackupFiles) {
        await older.rename(path.join(logDir, '$baseName.${i + 1}$ext'));
      }
    }

    // 将当前日志重命名为 .1 备份
    await file.rename(path.join(logDir, '$baseName.1$ext'));
  }

  void log(LogRecord record) {
    if (Config.enableDebug.value && _logSink != null) {
      _logSink?.writeln(
          '${record.level.name}: ${_formatTime(record.time)}: ${record.message}');
    }
  }

  String? get logFilePath => _logFile?.path;

  Future<void> dispose() async {
    await _logSubscription?.cancel();
    _logSubscription = null;
    await _logSink?.flush();
    await _logSink?.close();
    _logSink = null;
    _logFile = null;
  }
}
