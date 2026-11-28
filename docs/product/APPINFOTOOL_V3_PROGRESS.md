# AppInfoTool V3.0 开发进度表

更新：2026-11-28（Asia/Bangkok）
基线：`main @ 2a52fcc`（阶段 1 基础设施）
维护规则：**每完成一个子步骤就更新本表并提交**；状态只写实际证据，不写「预计完成」。

## 状态图例

| 标记 | 含义 |
| --- | --- |
| ✅ | 完成，有测试/命令证据 |
| 🟡 | 进行中 |
| ⬜ | 未开始 |
| ⛔ | 阻塞（外部条件） |
| ⏸️ | 暂缓（依赖未就绪） |

## 总览

| 阶段 | 内容 | 状态 | 出口物 | 门禁 |
| --- | --- | --- | --- | --- |
| 0 | 基线审计 | ✅ | `docs/audit/APPINFOTOOL_V3_BASELINE_AUDIT.md`（`01971a2`） | 十项功能有状态与证据 |
| 1 | 分析基础设施 | ✅ | `docs/architecture/APPINFOTOOL_V3_ANALYSIS_ARCHITECTURE.md` | 新模型可序列化；旧数据可读；ID 唯一 |
| 2 | F04 文件浏览器 + F01 敏感信息 | 🟡 | 代码 + 样本回归 | 真样本命中；无明文落盘 |
| 3 | F02 SDK/隐私 + F03 SBOM | ⬜ | 代码 + Schema 校验 | CycloneDX/SPDX 过校验 |
| 4 | F05 深度差异 + F06 处置 | ⬜ | 代码 + 历史 run 对比 | 处置不污染原始结果 |
| 5 | F07 API 调用关系 | ⬜ | 代码 + 图查询 | 关系有证据、预算生效 |
| 6 | F08 离线漏洞情报 | ⬜ | 代码 + fixture | 未知版本不定性 |
| 7 | F10 Profile 与自定义规则 | ⬜ | 代码 + Schema | 规则不执行代码 |
| 8 | F09 CLI / CI | ⬜ | `packages/app_analysis` + executable | CLI 与 GUI 同配置同结果 |
| 9 | 集成 / 跨平台 / 验收 | ⬜ | `APPINFOTOOL_V3_RELEASE_ACCEPTANCE.md` | 十大功能全过 + 三平台实机 |

## 阶段 1 明细（分析基础设施）

| 步骤 | 内容 | 状态 | 证据 |
| --- | --- | --- | --- |
| 1.1 | 架构与模型口径文档 | ✅ | `docs/architecture/APPINFOTOOL_V3_ANALYSIS_ARCHITECTURE.md`（含 PURL/fingerprint/identity/PROFILE 决策） |
| 1.2 | `Component` + PURL 身份模型 | ✅ | `component.dart`；`test/v3/component_test.dart` 11 条 |
| 1.3 | Finding 稳定 fingerprint | ✅ | `finding_fingerprint.dart`；`test/v3/finding_fingerprint_test.dart` 7 条 |
| 1.4 | Artifact identity（artifactId / parentPath / archiveEntry） | ✅ | `ArtifactIdentity` + `ArtifactEntry.stableId`；`test/v3/artifact_identity_test.dart` 5 条 |
| 1.5 | Evidence 扩展（redactedValue / extractorId） | ✅ | 可选字段，旧构造不变；`test/v3/evidence_fields_test.dart` |
| 1.6 | ScanProfile / RulePack Schema + 校验器 | ✅ | `scan_profile.dart`（未知阶段/超预算整体拒绝）；`test/v3/scan_profile_test.dart` 7 条 |
| 1.7 | 结果持久化与迁移（run 目录结构化） | ✅ | `AnalysisRun.model` 可选键 + 旧 run 无该键可读；索引 schema 不动（`indexSchemaVersion=2` 保持） |
| 1.8 | UI / CLI 复用点验证（无头分析入口） | ⏸️ | 模型层已纯 Dart（`dart test` 可跑）；`getApkInfo` 仍依赖 Flutter，无头入口留给阶段 8，见架构文档 §2 |

阶段 1 命令证据（2026-11-28）：

```
cd packages/analysis_model && dart test            # 183 passed（阶段 1 新增 35 条）
cd packages/analysis_model && dart analyze          # No issues found
flutter analyze                                     # No issues found
flutter test test/analysis_run_test.dart            # 12 passed
```

## 阶段 2 明细（F04 + F01）

| 步骤 | 内容 | 状态 | 证据 |
| --- | --- | --- | --- |
| 2.1 | 虚拟归档文件系统（复用 `ApkReader` / `ZipHelper` + 预算） | ✅ | `archive_safety/lib/src/file_tree.dart` + `lib/utils/package_archive_tree.dart`（嵌套条目读取走同一 budget ledger） |
| 2.2 | 文件树 / 搜索 / 筛选 / 导出 | ⬜ | |
| 2.3 | 文本 / Hex / 图片查看器 | ⬜ | |
| 2.4 | `SecretMatch` 模型 + 规则库（格式/上下文/校验） | ✅ | `secret_{match,rules,scanner}.dart`（8 条规则）+ `lib/utils/secret_scan_service.dart`（文本条目 400 条上限、DEX 8 个/8 MiB、总 12 MiB） |
| 2.5 | 脱敏管道与显式查看流程 | 🟡 | `SecretRedactor` + 上下文替换明文已完成；「显式查看明文」的二次确认流程待做（当前 UI 只展示脱敏值） |
| 2.6 | 敏感信息 UI + 报告节 | 🟡 | `lib/widgets/secret_scan_panel.dart` + 独立「敏感信息」Tab（Android/iOS）；报告节待接 schema v12 |
| 2.7 | 安全设计评审（明文不落盘/不入日志） | ⬜ | |

## 阶段 3 明细（F02 + F03）

| 步骤 | 内容 | 状态 | 证据 |
| --- | --- | --- | --- |
| 3.1 | Android SDK → `Component` 映射（复用 LibChecker/LibraryReport） | ⬜ | |
| 3.2 | iOS framework 身份识别（bundle id / 版本，可证实才填） | ⬜ | |
| 3.3 | `PrivacySignal` 与 SDK↔权限↔API↔网络关系 | ⬜ | |
| 3.4 | SBOM 生成器（CycloneDX 先行） | ⬜ | |
| 3.5 | SPDX 输出 | ⬜ | |
| 3.6 | Schema 校验测试 | ⬜ | |
| 3.7 | SDK / Privacy / SBOM UI | ⬜ | |

## 阶段 4 明细（F05 + F06）

| 步骤 | 内容 | 状态 | 证据 |
| --- | --- | --- | --- |
| 4.1 | 基于 AnalysisRun 的对比输入（不再依赖会话缓存） | ⬜ | |
| 4.2 | Artifact / SDK / Evidence / Coverage / SBOM 差异 | ⬜ | |
| 4.3 | 对比状态语义（added/removed/modified/unknown/notComparable） | ⬜ | |
| 4.4 | `FindingDisposition` 模型 + 审计历史 | ⬜ | |
| 4.5 | 处置 UI + 重扫匹配 | ⬜ | |
| 4.6 | 报告同时展示原始结果与处置 | ⬜ | |

## 阶段 5–8 明细

| 步骤 | 内容 | 状态 | 证据 |
| --- | --- | --- | --- |
| 5.1 | 敏感 API 分类库 + 通用调用图模型 | ⬜ | |
| 5.2 | 图查询 / 深度与节点限制 / UI | ⬜ | |
| 6.1 | 组件身份 → PURL → OSV 导入 | ⬜ | |
| 6.2 | 版本范围比较 + 匹配置信度 | ⬜ | |
| 6.3 | 本地库版本化 / 更新 / 回滚 | ⬜ | |
| 7.1 | Profile Schema + 预设 Profile | ⬜ | |
| 7.2 | 规则 Registry + 声明式匹配器（正则安全） | ⬜ | |
| 7.3 | Rule Pack 导入/导出/校验 + UI | ⬜ | |
| 8.1 | `packages/app_analysis`（无头编排） | ⬜ | |
| 8.2 | CLI executable + 退出码 + JSON/SARIF | ⬜ | |
| 8.3 | GitHub Actions / GitLab CI 示例 | ⬜ | |

## 阶段 9 明细（验收）

| 步骤 | 内容 | 状态 | 证据 |
| --- | --- | --- | --- |
| 9.1 | 十大功能集成回归 | ⬜ | |
| 9.2 | 样本矩阵（APK/IPA/多 DEX/Native/SDK/敏感/漏洞/超大） | ⬜ | |
| 9.3 | 三平台构建 + 实机运行 | ⛔ | 需 Windows/Linux 机器 |
| 9.4 | iOS 真机安装 E2E | ⛔ | 需设备与描述文件 |
| 9.5 | 性能 A/B（2.11.x vs 3.0） | ⬜ | |
| 9.6 | 验收报告 GO/NO-GO | ⬜ | |

## 变更记录

| 日期 | 变更 | 提交 |
| --- | --- | --- |
| 2026-11-28 | 阶段 0 审计完成 | `01971a2` |
| 2026-11-28 | 建立进度表（本文件） | 待提交 |
