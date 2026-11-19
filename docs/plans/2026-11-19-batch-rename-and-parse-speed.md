# 批量重命名与解析速度（2.10.1）

> 日期：2026-11-19｜状态：已实现

## 起点：两条用户反馈

1. 应用解析速度要更快；
2. 批量重命名「超过 10 个以上都会失败」，iOS 包也失败。

## 批量重命名：先查清楚「失败」是哪一种

按代码逐层核对，找到四个**确定的**缺陷（都在生产路径上）：

| 缺陷 | 后果 |
|---|---|
| `_prepare` 对每个文件调 `getApkInfo` | 每个文件跑完整流水线（资源表 + DEX 方法扫描 + 原生库符号 + 载荷探测 + 图标渲染 + 安全审计）。20 个包就是几十分钟的等待，且没有任何进度 |
| `getApkInfo` 不认 `.ipa` | IPA 拿不到名字 → 退回文件名 → 新旧名相同 → **界面报「已重命名 N 个」而磁盘上什么都没变** |
| 计划生成只看批次内部，不看磁盘 | 目标名已被占用时 `rename(2)` **静默覆盖**；而占用者若不在本批次，用户没有任何提示 |
| 同一批里名字互换 / 链式改名 | 逐个直接改名会把还没搬走的那个文件覆盖掉 |

另外两处：`p.extension` 把 `xxx.apk.1` 截成 `.1`（丢掉 `.apk`）；失败只报
「N 个文件失败」，不说是哪一个、为什么。

### 关于「超过 10 个」

**没有找到 10 这个硬阈值。** 实测把同一个真实 APK 复制 15 份连续解析，
第 11～15 次与第 1 次耗时一致（约 200 ms），无异常；用纯逻辑改名 24 个
文件也全部成功。`file_picker` 的 macOS 端也没有数量上限。

因此本轮按「让规模化失败不可能发生」处理：去掉每个文件的完整解析、
补上磁盘占用判定、补上两阶段改名、并把失败原因逐条列出来。
如果仍有失败，对话框会直接给出是哪一类（源文件不存在 / 目标被占用 /
写入失败 + 具体异常），不需要再猜。

`test/batch_rename_test.dart` 里新增 24 个文件的回归用例，
`test/batch_rename_dialog_test.dart` 用 24 条路径渲染对话框。

## 批量重命名：现在的实现

- `lib/utils/package_identity.dart`（新增）
  - `.ipa` → `IpaContainerReader` + `IpaInfoPlistReader`（只读一个 plist）；
  - `.xapk` / `.apkm` / `.apks` → `parseXapkManifest`；
  - 其余 → `ApkReader.open` + `parse()`（`android:label` 常是
    `@string/app_name`，必须靠资源表解出真名）；
  - 全部跑在 `Isolate.run` 里，不冻结界面；任何异常都兜成「取不到名字」。
- `lib/utils/batch_rename.dart`
  - `buildBatchRenamePlans` 增加 `exists` 注入点：按**目录 + 名字**
    （大小写不敏感）判冲突，磁盘占用时追加 ` (2)`；
  - 本批次自己的源名不算「已占用」（重跑同一批不会全变 ` (2)`）；
  - `batchRenameFiles` 检测交叉后走两阶段（临时名 → 最终名），失败回滚；
  - 目标被**外部**文件占用时拒绝执行而不是覆盖；
  - 失败分类：`sourceMissing` / `targetExists` / `ioError`。
- `lib/widgets/batch_rename_dialog.dart`
  - 进度「正在读取 3/12」、平台图标、「读不到应用名」提示；
  - 失败逐条列出（`原文件名 → 目标名：原因`）；
  - 全部已是目标名时按钮置灰；
  - `pop()` 之前先取 `ScaffoldMessenger` 与 `Navigator`（之后 context 已失效）。

## 解析速度：找到一处可证的白解压

`_probePayloads` 只看条目开头 4 KiB，却用 `readFile` 把整条解压出来。
`assets/` 下 64 条 8 MiB 资源包 = 436 MB 的纯浪费。

同一批条目实测（合成 17.6 MiB 包，64 条 8 MiB 条目）：

| 做法 | 耗时 | 解压字节 |
|---|---|---|
| `readFile`（整条） | 159 ms | 436 MB |
| `readFilePrefix`（64 KiB 上限） | 2 ms | 3.4 MB |

改动：
- `packages/apk_parser/lib/src/apk_reader.dart` 新增 `readFilePrefix`，
  与 `readFile` 共用同一个 `BoundedReadLedger`；
- `parse_task.dart` 的 `_probePayloads` 与 `apk_info.dart` 的
  `_probePayloadsForBase` 改用它；
- `PayloadProbeInput.sizeBytes` 改用**声明**大小 —— 与 `PayloadProbe`
  自己的注释一致（中央目录可伪造，信号里标注来源是「声明」）。

**没有动的**：`_collectResourceStrings` 仍然整条读文本型 `assets/`
（≤2 MiB × 64）。它要的是**内容**而不是文件头，改成前缀读会改变中文话术
的提取范围，那属于安全检测的覆盖口径，不能顺手改。

## 门禁

| 项 | 结果 |
|---|---|
| 根 `flutter test` | 1,816 通过 / 16 跳过（样本未配置） |
| 五个包 `dart test` | 40 + 141 + 222 + 245 + 25 = 673 通过 |
| `flutter analyze --fatal-infos --fatal-warnings` | 0 问题 |
| 五个包 `dart analyze` | 0 问题 |
| `dart format --set-exit-if-changed` | 0 changed |
