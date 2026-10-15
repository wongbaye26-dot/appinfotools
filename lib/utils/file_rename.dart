import 'dart:io';

import 'package:apk_info_tool/utils/logger.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;

/// 重命名的结局。
enum RenameOutcome {
  /// 已在原目录就地改名。
  renamed,

  /// 就地改名不可行，用户通过保存对话框选定了新位置。
  ///
  /// macOS 沙箱下这是**唯一**能成的路径，见 [renameFile] 的说明。
  savedElsewhere,

  /// 用户在保存对话框里点了取消。
  cancelled,

  /// 三级回退全部失败。
  failed,
}

/// [renameFile] 的结果。
class RenameResult {
  final RenameOutcome outcome;

  /// 改名之后的绝对路径；只有 [RenameOutcome.renamed] /
  /// [RenameOutcome.savedElsewhere] 时非空。
  final String? path;

  /// 失败原因，仅 [RenameOutcome.failed] 时非空。
  final Object? error;

  const RenameResult(this.outcome, {this.path, this.error});
}

/// 把 [file] 改名为 [newName]（`newName` 含扩展名）。
///
/// **为什么要三级回退** —— 三档平台的限制不一样，而且失败方式各不相同：
///
/// 1. `rename()`：同卷时是原子的，Windows / Linux 走这条。
/// 2. `copy()` + `delete()`：跨卷、或源文件被占用时（Windows 上很常见）。
/// 3. **保存对话框**：macOS 沙箱下前两条都会以 `EPERM` 失败 ——
///    `com.apple.security.files.user-selected.read-write` 只把读写权限授予
///    用户**选中的那一个文件**，不含它所在的目录，而改名要在同一个目录里
///    **新建**一个文件。实测报错：
///
///    ```
///    PathAccessException: Cannot copy file to '.../33-v8.5.5.ipa',
///    path = '.../33ZB_nosigned.ipa' (OS Error: Operation not permitted, errno = 1)
///    ```
///
///    保存对话框会把权限授予用户**选定的目标路径**，所以这条一定成立。
///    导报告、导图标一直没问题，正是因为它们走的就是保存对话框。
///
/// [saveDialogTitle] 是保存对话框的标题（调用方传本地化文案）。
Future<RenameResult> renameFile(
  File file, {
  required String newName,
  required String saveDialogTitle,
}) async {
  final directory = file.parent;
  final newPath = p.join(directory.path, newName);

  // 第 1 级：就地改名。
  try {
    await file.rename(newPath);
    return RenameResult(RenameOutcome.renamed, path: newPath);
  } catch (e) {
    log.info('rename failed ($e), falling back to copy+delete');
  }

  // 第 2 级：复制 + 删除。跨文件系统或文件被锁定时用这条。
  try {
    await file.copy(newPath);
    await file.delete();
    return RenameResult(RenameOutcome.renamed, path: newPath);
  } catch (e) {
    log.info('copy+delete failed ($e), falling back to save dialog');
  }

  // 第 3 级：让用户通过保存对话框授予目标路径的写权限。
  try {
    final savePath = await FilePicker.platform.saveFile(
      dialogTitle: saveDialogTitle,
      fileName: newName,
      initialDirectory: directory.path,
      lockParentWindow: true,
    );
    if (savePath == null) {
      return const RenameResult(RenameOutcome.cancelled);
    }
    await file.copy(savePath);
    await file.delete();
    return RenameResult(RenameOutcome.savedElsewhere, path: savePath);
  } catch (e) {
    log.info('save dialog fallback failed ($e)');
    return RenameResult(RenameOutcome.failed, error: e);
  }
}
