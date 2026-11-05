# 原审计 6 条 P1 修复记录

> **日期**：2026-11-05｜**状态**：5 条已修，1 条部分修复
> **依据**：`docs/audit/2026-11-04-module-completeness-audit.md` §5

---

## P1-1 缩略图“停用”无效 → 已修（待 Windows 验证）

**改动**：`windows/installer/appinfotool.iss` 的缩略图注册从 `Root: HKA`
改为 `Root: HKCU`，与应用的启用/停用/状态查询保持同一注册表根。

**效果**：
- 新安装不再写 HKLM，应用停用只删 HKCU 即可真正生效；
- 文件关联仍走 HKA，不受影响；
- C++ 状态查询同时读 HKCU/HKLM：发现机器级注册时 `machineWideRegistered=true`；
- 设置页显示“检测到机器级注册”警告，说明需要管理员清理；
- 停用时会尝试删除 HKLM；没权限则返回 `unregister_failed`，不会假装成功。
- 待办：旧版升级机器仍可能残留 HKLM，需要管理员运行一次；未在 Windows
  真机验证 Explorer 行为，也未重新编译安装包。

## P1-2 安装页不检测 adb 缺失 → 已修

`lib/pages/install_page.dart`：
- 生产路径先检查 `AdbService.adbExecutable`；
- 缺失时显示“未找到 adb”+ 说明 + “打开设置”按钮，不再显示“没有找到设备”。

## P1-3 XAPK 完整元数据硬依赖 aapt2 → 已修

`lib/apkparser/apk_info.dart`：
- aapt2 缺失/失败时调用内置 `ApkReader`，通过 `_applyMetaToApkInfo` 补齐
  package/version/SDK/组件/ABI/语言/密度/屏幕/图标等元数据；
- 不再只靠容器内 `manifest.json` 的少数字段。

## P1-4 语言选择器 3/6 → 已修

`lib/pages/setting_page.dart`：
- 增加 zh-HK / zh-TW / ja / ko；
- 使用完整 locale 标签（`zh-CN` 等），并把旧值 `zh` 归一为 `zh-CN`；
- 共 6 个可选项 + Auto。

## P1-5 Markdown 报告缺字段 → 已修

`lib/utils/analysis_report.dart` Android 小节补：
`archiveType / ABI / languages / densities / screen size / split APKs / OBB / ICP`。

iOS 小节补：
`urlSchemes / backgroundModes / icons` 摘要。

## P1-6 发布说明 macOS 版本 → 已修

`docs/release-install-notes.md`：`macOS 11+` → `macOS 12+`。

## 附加：损坏 manifest 的部分解析提示

- `ApkInfo.parseFailureReason != null` 时，概览页与分析页显示
  `ManifestPartialBanner`；
- 文案说明“包名来自 resources.arsc；版本/组件/权限未知；安全审计仍覆盖
  DEX 和资源”；
- 6 语言文案已补。

## 门禁

| 项 | 结果 |
|---|---|
| 根项目 `flutter test` | **1,772 通过 / 15 跳过 / 0 失败** |
| 根项目 `flutter analyze` | No issues found |
| `analysis_model` | 141 通过 |
| `apk_parser` | 216 通过 |
| `ipa_parser` | 239 通过 |
| `archive_safety` / `app_icon_extractor` | 40 / 25 通过 |
| `dart format` | 405 files，0 changed |

## 仍需真机/管理员验证

- Windows 缩略图停用在**升级安装**上的 HKLM 残留；
- Windows 安装包重新编译与 Explorer 真机调用；
- XAPK 无 aapt2 时的真实容器端到端（当前靠内置解析器单测/代码路径）。
