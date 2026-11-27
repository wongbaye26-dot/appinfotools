# AppInfoTool 2.11.0 实施计划

> 依据：`docs/audit/APPINFOTOOL_2.11.0_BASELINE_AUDIT.md`  
> 原则：只做真实数据；不改解析引擎/规则；复用 V4 UI；每阶段独立验收。  
> 当前版本基线：2.10.6 / `5c4db5a` / `v2.10.6`。  
> 基线冻结：分支 `feature/2.11.0`，commit `7dc863b`（V4 UI + 2.10.7 整改）。

## 0. 基线冻结（阻断项）

V4 UI 与 2.10.7 整改已冻结到 `feature/2.11.0` 的基线 commit（`7dc863b`），当前工作区只剩 2.11 Stage 1 的新增文件。

当前状态：

1. ✅ 已建 `feature/2.11.0` 并提交基线 `7dc863b`。
2. ✅ Stage 1 模型/仓库/测试已新增；尚未接入解析入口/页面。

## 1. 阶段总表

| 阶段 | 目标 | 主要产出 | 依赖 | 状态 |
|---|---|---|---|---|
| 1 | AnalysisRun 模型 + 本地持久化 | `AnalysisRun`、`AnalysisRunRepository`、序列化/索引/测试、解析入口接入 | 基线冻结 | ✅ 完成 |
| 2 | Evidence + Finding 关联 + Coverage | 独立 Evidence、evidenceIds、Coverage status/scanner 统计 | Stage 1 | 待开始 |
| 3 | Artifact + Load Graph | split inventory、按需 SHA、edge id/evidence、表格 UI | Stage 1/2 | 待开始 |
| 4 | Network Clues | URL/IPv6/WS 模型、来源、去重、UI | Stage 1/2 | 待开始 |
| 5 | 报告 + 历史复查 | 2.11 report schema、HTML、run 读取、历史筛选 | Stage 1–4 | 待开始 |
| 6 | 样本回归 | 固定样本矩阵、异常包、关系/报告一致性、跨平台记录 | Stage 1–5 | 待开始 |

## 2. Stage 1：AnalysisRun 与持久化

### 2.1 目标

每次分析产生一个不可变、可保存、可恢复的 AnalysisRun；关闭应用/切换页面后仍可读。

### 2.2 数据模型

`lib/models/analysis/analysis_run.dart`：

- `id`：`analysis_<UTC timestamp>_<sha prefix>`，稳定唯一。
- `toolVersion`、`appName`、`platform`、`packagePath`、`packageSha256`。
- `startedAt`、`completedAt`、`status`。
- `status`：`queued/running/success/partial/failed/cancelled`。
- `snapshot`：当前阶段先保存 `AnalysisReport.renderJson` 的 JSON 快照（真实数据；后续 Stage 2–5 再拆成 evidence/graph/network 顶层结构）。
- `limitations`：分析级限制。
- `toJson/fromJson`，坏数据抛 `FormatException`，不允许静默成功。

### 2.3 仓库

`lib/services/analysis_run_repository.dart`（或 `lib/utils/`，按现有目录习惯）：

- 根目录由调用方注入（生产用 `path_provider` 的 ApplicationSupportDirectory；测试用临时目录）。
- `runs/<id>.json` 单 run 文件；`runs/index.json` 索引。
- 原子写：临时文件 + rename。
- `save/read/list/delete`；索引缺失或损坏时从 run 文件重建。
- 限制：最多保留 100 条；超限删除最旧 run（不删除正在 running 的）。
- 路径安全：id 白名单，拒绝 `../`。
- 旧 `RecentFiles` 不当作 run；需要时只显示为“无结果旧记录”。

### 2.4 接入（需基线冻结后做）

- `FileState` 增加 `runId`、`runStatus`。
- 解析开始创建 `running` run；成功/部分/失败/取消更新状态。
- 完成时用 `FileState.analysis` + `AnalysisReport.renderJson` 生成 snapshot。
- 不做“每次 build 自动写 run”；只在解析事件边界写。
- 旧的 `RecentFilesManager` 保留，但历史列表逐步切换为 run 索引。

### 2.5 验收

- 应用重启后 `list()` 仍能读到 run。
- 同一路径不同内容/版本不会覆盖旧 run。
- 文件不存在时仍能读 run 快照。
- 损坏的 run 文件被跳过并记诊断，不崩溃。
- 索引损坏可从 run 文件重建。
- 序列化/反序列化 roundtrip 测试通过。
- 不改变现有解析流程与 UI。

### 2.6 不在 Stage 1 做

- Evidence/Finding/Graph/Network 的完整模型拆分。
- HTML 报告。
- 历史 UI 大改。
- 重新解析历史文件。

## 3. Stage 2：Evidence + Finding + Coverage

- 独立 Evidence 实体：ID/analysisId/category/type/raw/normalized/source/offset（可为空）/confidence。
- 从现有 `SecurityEvidence` 适配生成，Finding 增加 `evidenceIds`，保留内嵌 evidence 兼容旧报告。
- Coverage 增加 `failed/notScanned` 与 scanner 统计；由 audit 真实执行记录写入。
- 验收：finding 的 evidenceIds 全部有效，或明确 limitation；无来源 evidence 不进入正式列表。

## 4. Stage 3：Artifact + Load Graph

- Artifact：split 合并、按需 SHA-256、contentScanned 真实化、表格/搜索/筛选。
- Load Graph：edge id/evidenceIds/inferred、端点校验、表格优先、图形可选。
- 验收：artifact 数量与实际归档一致；edge 端点有效；哈希与外部工具一致；大包不一次性载入全部内容。

## 5. Stage 4：Network Clues

- 新 `NetworkClue`：type/raw/normalized/source artifact/evidence/confidence。
- 基于现有 `NetworkEndpoints` 扩展 URL/WS/IPv6（只做可靠识别），不联网。
- UI 列表 + 搜索/复制/来源跳转；报告导出。
- 验收：来源可追踪；去重/过滤测试；无主动网络请求。

## 6. Stage 5：报告 + 历史复查

> 实际实现：HTML 导出 + 历史列表/打开原包/删除快照；report schema 仍为 v8，未做 AnalysisRun 头/evidence[] 迁移，列入 2.11 遗留。

- 2.11 report schema（AnalysisRun 头、evidence[]、graph、networkClues、artifacts）。
- 保留 v8 旧报告读取；新报告从 AnalysisRun 渲染。
- HTML 报告：全量 HTML escape，禁止不可信字符串拼 script。
- 历史列表筛选/删除/重开；文件移动不覆盖旧 run。
- 验收：JSON 可解析；HTML 本地打开；数量与 run 一致；导出失败有错误信息。

## 7. Stage 6：样本回归

- 固定样本 manifest：名称/SHA/来源/权限/预期能力/预期 evidence/finding/coverage。
- 覆盖普通/多 DEX/Native/多组件/网络线索/大包/普通 IPA/加密 IPA/损坏包/特殊归档。
- 专项：路径穿越、超大文件、重复名、HTML 注入、扫描取消。
- 跨平台实际启动/导入/分析/导出；未执行平台明确标注。
- 输出 `docs/audit/APPINFOTOOL_2.11.0_RELEASE_ACCEPTANCE.md`。

## 8. 每个阶段的固定门禁

```bash
git status --short
git rev-parse HEAD
dart format --output=none --set-exit-if-changed .
flutter analyze --fatal-infos --fatal-warnings
flutter test
# 以及对应 package tests / 样本测试 / 跨平台运行记录
```

每个阶段必须记录：修改文件、新增文件、命令、结果、未执行项、风险、验收结论；不通过不进入下一阶段。

## 9. 当前执行状态

- [x] Stage 0 基线审计
- [x] 实施计划表
- [x] 基线冻结：`feature/2.11.0` / `7dc863b`
- [x] Stage 1 模型 / 仓库 / 测试（`analysis_run.dart`、`analysis_run_repository.dart`、10 项测试）
- [x] Stage 1 入口接入（Android/iOS 解析生命周期、真实快照、切文件保护）
- [x] Stage 2 Evidence / Finding / Coverage
- [x] Stage 3 Artifact Inventory / Load Graph
- [x] Stage 4 Network
- [x] Stage 5 Report / History（commit `975dc66`；未升 report schema，HTML/历史基于 v8 快照）

## 10. 2.11.0 收口后补充（2026-11-28）

- [x] Step 1 report schema v9：`reportSchemaVersion=9`，新增 `analysisRun` 头、finding `evidenceIds`、`security.evidence[]`、证据条目稳定 `id`；契约 `docs/contracts/analysis-report-v9.schema.json`。
- 证据 ID 规则：`SecurityEvidence.evidenceId` FNV-1a 64（`ev_<12 hex>`），finding 直接引用该 ID。
- 旧报告：历史 v8 快照仍可读取/展示；新生成报告为 v9，未做自动迁移。
- 门禁：`flutter test` 1899 passed / 20 skipped；analyze 干净；format 473 文件 0 变化；build bundle 0。
- 剩余顺序不变：历史页 widget 测试/快照语义 → Windows/Linux 实机 → CI 样本门禁 → 版本/CHANGELOG/发布验收。

### 2026-11-28 顺序执行进度

- [x] Step 1 report schema v9（commit `5f360d6`）
- [x] Step 2 历史页 widget 测试 + “重新分析”语义（commit `7f8dcbc`）
- [ ] Step 3 Windows/Linux 实机验收：**阻塞**，当前机器为 macOS，无 Windows/Linux 环境
- [ ] Step 4 CI 样本清单与三平台门禁
- [ ] Step 5 版本/CHANGELOG/发布验收
