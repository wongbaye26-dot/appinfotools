// `ReportExporter` 的三态与错误分支 —— v2.4.1 那次修复的回归测试。
//
// ## 背景
//
// v2.4.0 的「导出报告」有两个问题：
//   1. **保存面板根本不弹**，只回一句 `PlatformException(ENTITLEMENT_REQUIRED_WRITE, …)`
//      —— 根因是 `file_picker` 的 macOS 端在弹面板**之前**就查
//      `com.apple.security.files.user-selected.read-write` 这个 entitlement；
//   2. 两个导出对话框各自把「用户取消（面板返回 null）」与「写盘失败」混成一类，
//      调用方只能靠 `null` / `true` / 异常对象三态去猜 —— 于是**取消也会报导出失败**。
//
// 修复是：entitlements 补上授权（见 `test/macos_entitlements_test.dart`），
// 以及把「弹面板 + 写盘」收成 `ReportExporter`，结果做成**三态类型**。
//
// ## 本测试怎么隔离平台
//
// `file_picker` 的 `FilePicker.platform` 是**可写的静态字段**，`FilePicker` 是
// `abstract class … extends PlatformInterface`，所以测试里 `extends FilePicker`
// 造一个假实现替换即可 —— **不需要改任何生产代码，也不需要真实的保存面板**。
//
// 写盘那一半用**真实临时目录**（`dart:io` 在 `flutter test` 里可用）：
// 成功路径写真实文件、失败路径指向一个不存在的目录以触发 `FileSystemException`。

import 'dart:convert';
import 'dart:io';

import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/utils/report_exporter.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 一次 `saveFile` 调用收到的参数（用来断言透传）。
class _SaveFileCall {
  const _SaveFileCall({
    required this.dialogTitle,
    required this.fileName,
    required this.type,
    required this.allowedExtensions,
    required this.lockParentWindow,
  });

  final String? dialogTitle;
  final String? fileName;
  final FileType type;
  final List<String>? allowedExtensions;
  final bool lockParentWindow;
}

/// 假的文件选择器：记录参数，并把结果交给调用方给定的行为。
class _FakeFilePicker extends FilePicker {
  _FakeFilePicker(this._behaviour);

  final Future<String?> Function() _behaviour;

  final List<_SaveFileCall> calls = [];

  @override
  Future<String?> saveFile({
    String? dialogTitle,
    String? fileName,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Uint8List? bytes,
    bool lockParentWindow = false,
  }) {
    calls.add(_SaveFileCall(
      dialogTitle: dialogTitle,
      fileName: fileName,
      type: type,
      allowedExtensions: allowedExtensions,
      lockParentWindow: lockParentWindow,
    ));
    return _behaviour();
  }
}

/// 装一个假面板并返回它。
_FakeFilePicker _install(Future<String?> Function() behaviour) {
  final fake = _FakeFilePicker(behaviour);
  FilePicker.platform = fake;
  return fake;
}

/// 取「写到一个不存在的目录」时操作系统给出的原因，用于独立核对提示文案。
String _osReasonForFailedWrite(String path) {
  try {
    File(path).writeAsStringSync('probe');
  } on FileSystemException catch (e) {
    return e.osError?.message ?? e.message;
  }
  fail('这个路径本应写失败：$path');
}

void main() {
  late Directory tmp;

  setUpAll(() async {
    // 语言包是 deferred 的，必须 await。
    await LocaleSettings.setLocaleRaw('en');
  });

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('report_exporter_test');
  });

  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  Future<ReportSaveResult> saveTo(
    String? path, {
    List<String>? allowedExtensions,
    String content = '# report\n',
  }) {
    _install(() async => path);
    return ReportExporter.save(
      t: t,
      dialogTitle: 'Export',
      suggestedFileName: 'report.md',
      content: content,
      allowedExtensions: allowedExtensions,
    );
  }

  // -------------------------------------------------------------------
  // 三态
  // -------------------------------------------------------------------

  group('三态：saved / cancelled / failed 必须分得开', () {
    test('面板返回路径且写盘成功 → saved', () async {
      final target = '${tmp.path}/out.md';
      final result = await saveTo(target, content: '# hello\n');

      expect(result.isSaved, isTrue);
      expect(result.isCancelled, isFalse);
      expect(result.failure, isNull);
      expect(File(target).readAsStringSync(), '# hello\n');
    });

    test('写盘内容与传入的 content 逐字节一致', () async {
      final target = '${tmp.path}/exact.md';
      const content = '# 标题\n\n- 项一\n- 项二\n';
      await saveTo(target, content: content);

      expect(File(target).readAsBytesSync(), utf8.encode(content));
    });

    test('面板返回 null（用户取消）→ cancelled，**不是** failed', () async {
      final result = await saveTo(null);

      expect(result.isCancelled, isTrue);
      expect(result.isSaved, isFalse);
      expect(
        result.failure,
        isNull,
        reason: '取消不是失败 —— v2.4.0 的缺陷正是把这两者混成一类',
      );
    });

    test('写盘失败 → failed，且不是 cancelled', () async {
      // 目录不存在 → FileSystemException
      final missing = '${tmp.path}/no-such-dir/out.md';
      final result = await saveTo(missing);

      expect(result.isSaved, isFalse);
      expect(result.isCancelled, isFalse);
      expect(result.failure, isNotNull);
      expect(result.failure!.message, isNotEmpty);
    });

    test('写盘失败的提示里带操作系统给出的原因（不是一串原始 dump）', () async {
      final missing = '${tmp.path}/no-such-dir/out.md';
      final reason = _osReasonForFailedWrite(missing);

      final result = await saveTo(missing);

      expect(
        result.failure!.message,
        contains(reason),
        reason: '用户能看懂的是「没有那个目录」，而不是 errno 编号',
      );
    });

    test('三种状态互斥：任意一次调用只落在一种状态上', () async {
      final saved = await saveTo('${tmp.path}/a.md');
      final cancelled = await saveTo(null);
      final failed = await saveTo('${tmp.path}/nope/x.md');

      for (final entry in {
        'saved': saved,
        'cancelled': cancelled,
        'failed': failed,
      }.entries) {
        final flags = [
          entry.value.isSaved,
          entry.value.isCancelled,
          entry.value.failure != null,
        ].where((f) => f).length;
        expect(flags, 1, reason: '${entry.key} 命中了 $flags 种状态');
      }
    });
  });

  // -------------------------------------------------------------------
  // entitlement 与其它平台异常
  // -------------------------------------------------------------------

  group('平台异常：entitlement 专用文案 vs 其它异常', () {
    Future<ReportSaveResult> saveThrowing(PlatformException e) {
      _install(() async => throw e);
      return ReportExporter.save(
        t: t,
        dialogTitle: 'Export',
        suggestedFileName: 'report.md',
        content: 'x',
      );
    }

    test('ENTITLEMENT_REQUIRED_WRITE → 走可操作的专用文案', () async {
      final result = await saveThrowing(
        PlatformException(
          code: 'ENTITLEMENT_REQUIRED_WRITE',
          message: 'The Read-Write entitlement is required for this action.',
        ),
      );

      expect(result.isSaved, isFalse);
      expect(result.isCancelled, isFalse);
      expect(result.failure!.message, t.report.save_error_entitlement);
      expect(
        result.failure!.message,
        isNot(contains('ENTITLEMENT_REQUIRED_WRITE')),
        reason: '给用户的是「该怎么办」，不是复述错误码',
      );
    });

    test('ENTITLEMENT_NOT_FOUND → 同一句专用文案（打开/选目录那条路径）', () async {
      final result = await saveThrowing(
        PlatformException(code: 'ENTITLEMENT_NOT_FOUND', message: 'not found'),
      );

      expect(result.failure!.message, t.report.save_error_entitlement);
    });

    test('其它 PlatformException → 走通用失败文案，**不得**误用 entitlement 文案', () async {
      final other =
          PlatformException(code: 'SOME_OTHER_FAILURE', message: 'boom');
      final result = await saveThrowing(other);

      expect(result.isSaved, isFalse);
      expect(result.failure, isNotNull);
      expect(
        result.failure!.message,
        isNot(t.report.save_error_entitlement),
        reason: '非 entitlement 的异常套上「缺授权」的提示会把人引到错方向',
      );
      expect(result.failure!.message, contains('SOME_OTHER_FAILURE'));
    });

    test('PlatformException 也算 failed（不是 cancelled）', () async {
      final result = await saveThrowing(
        PlatformException(code: 'ENTITLEMENT_REQUIRED_WRITE'),
      );
      expect(result.isCancelled, isFalse);
    });
  });

  // -------------------------------------------------------------------
  // 面板参数透传
  // -------------------------------------------------------------------

  group('传给保存面板的参数', () {
    test('给了 allowedExtensions → FileType.custom 且原样透传', () async {
      final fake = _install(() async => '${tmp.path}/out.md');
      await ReportExporter.save(
        t: t,
        dialogTitle: 'Export Report',
        suggestedFileName: 'report.md',
        content: 'x',
        allowedExtensions: const ['md'],
      );

      expect(fake.calls, hasLength(1));
      final call = fake.calls.single;
      expect(call.type, FileType.custom);
      expect(call.allowedExtensions, const ['md']);
    });

    test('没给 allowedExtensions → FileType.any 且不限制后缀', () async {
      final fake = _install(() async => '${tmp.path}/out.md');
      await ReportExporter.save(
        t: t,
        dialogTitle: 'Export Report',
        suggestedFileName: 'report.json',
        content: 'x',
      );

      final call = fake.calls.single;
      expect(call.type, FileType.any);
      expect(call.allowedExtensions, isNull);
    });

    test('dialogTitle / fileName / lockParentWindow 都透传', () async {
      final fake = _install(() async => '${tmp.path}/out.md');
      await ReportExporter.save(
        t: t,
        dialogTitle: '导出报告',
        suggestedFileName: 'demo-2.4.1.md',
        content: 'x',
      );

      final call = fake.calls.single;
      expect(call.dialogTitle, '导出报告');
      expect(call.fileName, 'demo-2.4.1.md');
      expect(
        call.lockParentWindow,
        isTrue,
        reason: '面板必须锁父窗口，否则 macOS 上会弹出两个可交互窗口',
      );
    });
  });
}
