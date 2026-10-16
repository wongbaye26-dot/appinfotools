import 'dart:io';

import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';

/// 保存失败时给用户看的一句话。
class ReportSaveFailure {
  const ReportSaveFailure(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 保存一份报告的结果 —— **三种状态必须分开**。
///
/// 「用户取消」不是失败。v2.4.0 的导出对话框把取消与失败混成一类处理，
/// 调用方只能靠 `result == null` / `true` / `异常对象` 三态去猜；这里直接
/// 把三态做进类型里，调用方写不出「取消也报失败」这种代码。
class ReportSaveResult {
  const ReportSaveResult.saved()
      : failure = null,
        _saved = true;

  const ReportSaveResult.cancelled()
      : failure = null,
        _saved = false;

  const ReportSaveResult.failed(this.failure) : _saved = false;

  final ReportSaveFailure? failure;
  final bool _saved;

  bool get isSaved => _saved;
  bool get isCancelled => !_saved && failure == null;
}

/// 把一段报告正文写盘 —— **全项目只有这一份实现**。
///
/// 此前「弹保存面板 → 写文件」在 `ExportReportDialog` 与 `ExportDiffDialog`
/// 里各写了一遍。收成一份，顺带把 `file_picker` 那个读不懂的
/// `PlatformException` 换成人话。
///
/// ## 关于 `ENTITLEMENT_REQUIRED_WRITE`
///
/// `file_picker`(>=10) 的 macOS 端在弹面板**之前**就用 `SecTaskCreateFromSelf`
/// 检查 `files.user-selected.read-write` 这个 entitlement。本应用**刻意不开
/// 沙箱**（要在用户选中的文件旁边改名，而沙箱只授予那一个文件、不含它所在的
/// 目录），但插件不管这些，照样要求授权存在 —— 于是保存面板根本不弹，
/// 用户只看到一句 `PlatformException(ENTITLEMENT_REQUIRED_WRITE, ...)`。
///
/// 授权已在 v2.4.1 的 entitlements 里补上；这里再把兜底提示写成**可操作的**，
/// 万一将来在某个构建里又丢了，用户也知道该做什么，而不是只看到一串错误码。
class ReportExporter {
  const ReportExporter._();

  static Future<ReportSaveResult> save({
    required Translations t,
    required String dialogTitle,
    required String suggestedFileName,
    required String content,
    // 保存面板里限制的扩展名（如 `['md']`）。不传则不限制。
    //
    // 两个调用方原先各传各的（`FileType.custom` + `allowedExtensions`），
    // 收成一份时不能顺手丢掉 —— 丢了以后 macOS 的保存面板会允许任意后缀，
    // 用户可以把 `.md` 存成 `.txt`，报告打开方式就乱了。
    List<String>? allowedExtensions,
  }) async {
    String? savePath;
    try {
      savePath = await FilePicker.platform.saveFile(
        dialogTitle: dialogTitle,
        fileName: suggestedFileName,
        type: allowedExtensions == null ? FileType.any : FileType.custom,
        allowedExtensions: allowedExtensions,
        lockParentWindow: true,
      );
    } on PlatformException catch (e) {
      // 面板没弹出来 === 权限检查就没过。这是**环境问题**，不是用户操作失误，
      // 所以要说清「该怎么办」而不是复述错误码。
      return ReportSaveResult.failed(
        ReportSaveFailure(_permissionMessage(t, e)),
      );
    }

    // 用户按了取消：保存面板返回 null。这不是失败。
    if (savePath == null) return const ReportSaveResult.cancelled();

    try {
      await File(savePath).writeAsString(content);
      return const ReportSaveResult.saved();
    } on FileSystemException catch (e) {
      // 只把「用户能改的那部分」写进提示（权限 / 路径 / 空间），
      // 不把 `OS Error: No such file or directory, errno = 2` 原样拍在脸上。
      final reason = e.osError?.message ?? e.message;
      return ReportSaveResult.failed(
        ReportSaveFailure(t.report.export_failed(error: reason)),
      );
    }
  }

  /// 把 entitlement 类失败翻译成可操作的一句话。
  static String _permissionMessage(Translations t, PlatformException e) =>
      switch (e.code) {
        // file_picker 的 macOS 端用的两个错误码：保存要求 read-write，
        // 打开/选目录要求 read-only 或 read-write 任一。
        'ENTITLEMENT_REQUIRED_WRITE' ||
        'ENTITLEMENT_NOT_FOUND' =>
          t.report.save_error_entitlement,
        _ => t.report.export_failed(error: e.toString()),
      };
}
