// 重命名的三级回退（就地改名 → 复制+删除 → 保存对话框）。
//
// 这里只覆盖真实文件 IO 能覆盖的两条：
// - 成功路径：同目录改名后旧文件消失、内容逐字节不变；
// - 彻底失败：如实返回 failed，且**不动原文件**。
//
// 第 2、3 级回退要靠平台通道才能触发（跨卷 / 沙箱 / 保存对话框），
// 在 `flutter test` 里没有对应实现，因此不在这里断言 —— 与其用 mock
// 把「我以为的失败方式」写死，不如让它走真实路径。
import 'dart:io';

import 'package:apk_info_tool/utils/file_rename.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('appinfotool_rename_');
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  test('就地改名：旧文件消失、新文件内容逐字节不变', () async {
    final original = List<int>.generate(64, (i) => i);
    final src = File(p.join(dir.path, '33ZB_nosigned.ipa'))
      ..writeAsBytesSync(original);

    final result = await renameFile(
      src,
      newName: '33-v8.5.5.ipa',
      saveDialogTitle: '重命名文件',
    );

    final expected = p.join(dir.path, '33-v8.5.5.ipa');
    expect(result.outcome, RenameOutcome.renamed);
    expect(result.path, expected);
    expect(result.error, isNull);
    expect(File(expected).existsSync(), isTrue);
    expect(
      src.existsSync(),
      isFalse,
      reason: '改名后旧文件必须消失 —— 否则那是复制，不是重命名',
    );
    expect(File(expected).readAsBytesSync(), original);
  });

  test('连保存对话框都救不回来时返回 failed，并且不动原文件', () async {
    final original = [1, 2, 3];
    final src = File(p.join(dir.path, 'a.ipa'))..writeAsBytesSync(original);

    // 目标父目录不存在 → rename 与 copy 都会失败；
    // 测试环境没有 file_picker 的平台实现，保存对话框也会抛异常。
    final result = await renameFile(
      src,
      newName: p.join('ghost-dir', 'b.ipa'),
      saveDialogTitle: '重命名文件',
    );

    expect(result.outcome, RenameOutcome.failed);
    expect(result.path, isNull);
    expect(result.error, isNotNull);
    expect(src.existsSync(), isTrue, reason: '失败时必须原封不动');
    expect(src.readAsBytesSync(), original);
  });
}
