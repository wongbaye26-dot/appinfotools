# P2-6：`INSTALL_FAILED_*` 映射（第一阶段）

> 日期：2026-11-05

## 改动

新增 `lib/utils/adb_install_error.dart`：

- 从混杂的 adb 输出里提取 `INSTALL_FAILED_*` / `INSTALL_PARSE_FAILED_*`；
- 无失败码时返回 `null`，由调用方保留原始输出。

`install_page.dart` 单 APK 安装失败时：

- 提取稳定失败码；
- 映射到本地化文案：
  - already exists；
  - insufficient storage；
  - invalid APK / parse failed；
  - version downgrade；
  - update incompatible；
  - no matching ABIs；
  - signature/shared-user incompatible；
  - 其它码走 `error_generic(code)`。
- 6 语言文案已补。

## 测试

- 新增 `test/adb_install_error_test.dart`，覆盖混杂输出、`INSTALL_PARSE_FAILED_*`、无码场景。

## XAPK / APKS 分支（已补）

`XapkInstaller` 现在：

- `_runProcess` 同时保留 stdout/stderr（截断到 64 KiB），不再直接 drain 丢输出；
- 暴露 `lastOutput` / `lastFailureCode`；
- 安装页 XAPK 失败时复用同一套失败码本地化文案。

## 仍未做

- 取消仍只杀本地 adb 客户端，server 侧可能继续；
- USB 热插拔仍需手动刷新；
- `getSplitApks` 的 manifest 解码仍用 `String.fromCharCodes`，非 ASCII 分包名会乱码。

## 门禁

| 项 | 结果 |
|---|---|
| 根项目 `flutter test` | 1,775 通过 |
| `ipa_parser` / `apk_parser` | 244 / 217 |
| 根项目 analyze | 0 问题 |
| `dart format` | 409 files，0 changed |
