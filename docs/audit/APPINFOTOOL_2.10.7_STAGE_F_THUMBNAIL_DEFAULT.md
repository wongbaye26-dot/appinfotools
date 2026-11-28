# AppInfoTool 2.10.7 — Stage F 验收报告（Windows 缩略图默认行为）

- 起点 commit：`5c4db5a`（v2.10.6）
- 本轮状态：未提交工作区，基于 `5c4db5a` + Stage A–F 修改
- 范围：P1-7 Windows 缩略图默认行为统一
- 结论：**代码与文档侧完成；Windows 真机/安装器运行验收未执行，P1-7 不能标记为“已通过”**

## 1. 整改目标

审计发现“README 说默认关闭”与“实际默认开启、启动自动注册、安装器无条件写注册表”矛盾。P1-7 要求：

1. 推荐默认关闭；
2. 配置默认 `false`；
3. 启动不自动注册；
4. 安装器不默认注册；
5. 设置页主动启用；
6. 停用必须真实确认；
7. 失败不能假报成功；
8. README 与行为统一。

## 2. 修改文件

| 文件 | 修改 |
| --- | --- |
| `lib/config.dart` | `system_icon_enabled` 默认值 `true → false`；注释说明启动不读取、真实状态以注册表查询为准 |
| `lib/main.dart` | 删除启动时 `SystemThumbnailManager.ensureRegistered()` 自动注册块；仅文件关联仍在启动时注册（与缩略图无关） |
| `windows/installer/appinfotool.iss` | 删除全部缩略图 `[Registry]` HKCU 写入；安装器不再注册缩略图处理器；旧版注册项不自动删除 |
| `lib/utils/system_thumbnail.dart` | 增加 `isKnown`、`ThumbnailToggleOutcome`、`classifyToggle()`；未知状态不再被当作“已停用”；区分“完全停用 / 仍有 HKLM / 失败” |
| `lib/pages/setting_page.dart` | 启停后按真实状态刷新；未知或部分失败时重新 `getStatus()`；按 `classifyToggle` 给出诚实提示；配置写入实际 `usable`，不再写用户点击意图 |
| `assets/i18n/{en,zh-CN,zh-TW,zh-HK,ja,ko}.json` | 新增 `settings.system_icon.disabled_machine_wide`；六语言真实翻译 |
| `README.md` / `README_en.md` | 明确安装器/启动不写注册表、仅在设置页启用时写 HKCU；停用会尝试清理旧版 HKLM，无管理员权限时明确提示“未能完全停用”；升级不自动删除旧 HKCU 注册 |
| `test/system_thumbnail_section_test.dart` | 新增 5 个纯函数分类测试（未知、启用成功、停用成功、HKLM 残留、HKCU 残留） |
| `test/system_thumbnail_defaults_test.dart`（新） | 守住 `Config.systemIconEnabled` 默认 `false` |

未修改 Windows C++ 缩略图实现，也未修改安装器其它文件关联注册逻辑。

## 3. 行为对照

| 场景 | 修改前 | 修改后 |
| --- | --- | --- |
| 全新安装 | 安装器写 HKCU 缩略图项，默认即启用 | 安装器不写；默认关闭 |
| 每次启动 | 配置为 true 时自动 `ensureRegistered()` | 不读配置、不注册 |
| 用户在设置页启用 | 写 HKCU | 写 HKCU；只有 `usable == true` 才提示成功 |
| 用户停用且无 HKLM | 删除后提示“已停用” | 确认 HKCU/HKLM 均无残留后提示“已停用” |
| 停用但 HKLM 删不掉 | 可能提示“已停用” | 提示“未能完全停用”，说明 HKLM 仍在 |
| 查询/写入异常 | 可能被当成“已停用” | `unknown` → 失败提示，不写虚假成功 |
| 配置持久化 | 写“用户点击方向” | 写实际 `usable`，避免下次显示从未生效的“已启用” |
| 旧版已写 HKCU 的用户 | 升级后仍启用 | 升级不静默删除；用户可在设置页停用；README 已说明 |

## 4. 验证命令与结果

```text
~/development/flutter/bin/flutter test \
  test/system_thumbnail_section_test.dart \
  test/system_thumbnail_defaults_test.dart
→ 28 passed

~/development/flutter/bin/flutter test
→ 1871 passed / 19 skipped / 0 failed

packages:
  analysis_model 142
  apk_parser 226
  ipa_parser 250
  archive_safety 40
  app_icon_extractor 25
→ 683 passed

~/development/flutter/bin/flutter analyze --fatal-infos --fatal-warnings
→ No issues found

~/development/flutter/bin/dart format --output=none --set-exit-if-changed .
→ 452 files, 0 changed

~/development/flutter/bin/flutter build bundle
→ exit 0

git diff --check
→ OK
```

根测试由 Stage E 的 `1865` 增加到 `1871`：新增 5 个分类测试 + 1 个默认值测试。包测试数量不变。

## 5. 未执行项（必须如实记录）

以下项目当前环境无法执行，**不是通过**：

1. **未在 Windows 上编译Inno安装器**：本机为 macOS，无 Inno Setup / Windows 工具链；删除注册表行后未实际编译 `.iss`。
2. **未在 Windows 上安装/升级**：无法验证“全新安装不写 HKCU”“旧版升级保留旧注册项”。
3. **未在 Windows 资源管理器验证缩略图**：无法确认启用后图标出现、停用后图标消失。
4. **未验证 HKLM 清理的真实行为**：非管理员场景、HKLM 键权限、路径不一致等只能由原生代码语义推断，未实机执行。
5. **未跑 Windows CI**：Stage E 新增的启动级 CI smoke 尚未在 GitHub Actions 上运行；它也只验证启动，不验证缩略图。

因此 P1-7 当前状态应记录为：**代码与文档整改完成，Windows 运行验收未完成**。不能把“设置页逻辑测试通过”等同于“Windows 缩略图行为已验收”。

## 6. 已知风险 / 限制

- **旧版 HKCU 残留**：<=2.10.6 安装器写过的 HKCU 键不会在升级时自动删除；用户需在设置页停用。这是有意的保守选择，避免静默删除用户已有的系统集成。
- **HKLM 机器级注册**：旧版可能写过 HKLM；非管理员无法删除时，界面提示“未能完全停用”，但 Explorer 仍可能继续使用该处理器。该分支只有原生语义，未实机验证。
- **路径不一致**：注册路径仍指向旧安装目录时，`usable` 可能为 true 但实际图标加载失败；本轮未改变该既有状态机。
- **安装器语法**：只删除了 `[Registry]` 行并改注释，未新增语法；仍建议在 Windows 构建机上跑一次 Inno 编译。
- **配置语义**：`system_icon_enabled` 仍保留，作为“上次实际可用状态”的记录，但启动和安装器都不再信任它做自动注册。

## 7. 阶段验收结论

- P1-7 的代码/文档整改项：**完成**（默认 false、启动不注册、安装器不注册、设置页显式启用、停用真实确认、失败不假报成功、README 对齐）。
- P1-7 的 Windows 运行验收：**未完成**。
- 建议 Stage F 状态：**代码侧通过，真机侧待验收**。
- 下一步：等待人工确认是否接受该 partial 状态并进入 Stage G；在 Windows 真机验收完成前，发布结论仍为 **NO-GO**。
