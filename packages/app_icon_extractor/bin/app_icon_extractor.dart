// 无界面图标提取器 —— 供原生 Shell 扩展调用。
//
// ## 为什么是独立进程而不是库
//
// Windows 缩略图处理器是 **in-proc COM 组件**，加载进 `explorer.exe`。
// 把解析逻辑放进 DLL 有两个硬问题：Dart 运行时无法嵌入一个已有消息循环的
// 宿主进程；且任何解析崩溃都会带崩整个桌面。因此 DLL 只做三件事：
// 校验参数 → `CreateProcess` 起本程序 → 读回 PNG。
//
// ## 协议（**这是与原生侧的唯一契约，改动要两边同步**）
//
//   app_icon_extractor --input <安装包路径> [--output <png 路径>] [--json]
//
// - `--output`：成功时把 PNG 字节写入该路径（覆盖）。不给则只报告状态。
// - `--json`：在 stdout 打一行 JSON（诊断用；不影响退出码）。
//
// 退出码：
//   0  成功（PNG 已写入 --output）
//   2  不支持（自适应图标矢量、未知格式…）
//   3  输入无效（不是 ZIP、结构损坏、manifest 读不出…）
//   4  超出资源预算（文件/条目/像素过大）
//   5  用法错误
//   6  内部错误（未预期异常）
//
// **子进程自己不再设时间上限**：超时由调用方（DLL）用
// `WaitForSingleObject` + `TerminateProcess` 强制，因为纯 CPU 阶段
// 不会让出事件循环，Dart 侧的 `Future.timeout` 对它无效。
import 'dart:convert';
import 'dart:io';

import 'package:app_icon_extractor/app_icon_extractor.dart';

const int _exitOk = 0;
const int _exitUnsupported = 2;
const int _exitInvalidInput = 3;
const int _exitResourceLimit = 4;
const int _exitUsage = 5;
const int _exitInternal = 6;

Future<void> main(List<String> args) async {
  String? input;
  String? output;
  var json = false;

  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--input':
        if (i + 1 >= args.length) _usage('--input requires a path');
        input = args[++i];
      case '--output':
        if (i + 1 >= args.length) _usage('--output requires a path');
        output = args[++i];
      case '--json':
        json = true;
      case '--help' || '-h':
        _printUsage();
        exit(_exitOk);
      default:
        // 未知参数一律拒绝：静默忽略会让原生侧「以为传对了」。
        _usage('unknown argument: ${args[i]}');
    }
  }
  if (input == null) _usage('--input is required');

  AppIconResult result;
  try {
    result = await extractAppIcon(input);
  } catch (e) {
    result = AppIconResult.failure(
      AppIconStatus.invalidInput,
      'internal.unhandled',
      detail: '$e',
    );
    if (json) _emitJson(result);
    exit(_exitInternal);
  }

  if (json) _emitJson(result);

  if (result.hasIcon) {
    final png = result.png!;
    if (output != null) {
      try {
        await File(output).writeAsBytes(png, flush: true);
      } on FileSystemException catch (e) {
        stderr.writeln('cannot write $output: ${e.message}');
        exit(_exitInternal);
      }
    }
    exit(_exitOk);
  }

  // 失败时**不写 output**：留下上一次的旧文件会让调用方把过期图标
  // 当成这次的结果。调用方负责在启动子进程前删掉旧文件。
  exit(switch (result.status) {
    AppIconStatus.unsupported => _exitUnsupported,
    AppIconStatus.invalidInput => _exitInvalidInput,
    AppIconStatus.resourceLimit => _exitResourceLimit,
    AppIconStatus.success || AppIconStatus.fallback => _exitOk,
  });
}

void _emitJson(AppIconResult r) {
  stdout.writeln(jsonEncode({
    'status': r.status.name,
    'source': r.source.id,
    'format': r.format.id,
    'bytes': r.png?.length ?? 0,
    'width': r.pixelWidth,
    'height': r.pixelHeight,
    'reason': r.reasonCode,
    'detail': r.detail,
  }));
}

void _printUsage() {
  stdout.writeln('usage: app_icon_extractor --input <apk|ipa> '
      '[--output <png>] [--json]');
}

Never _usage(String message) {
  stderr.writeln('error: $message');
  _printUsage();
  exit(_exitUsage);
}
