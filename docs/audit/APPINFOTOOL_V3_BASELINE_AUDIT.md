# AppInfoTool V3.0 阶段 0：基线审计

日期：2026-11-28
审计对象：`main @ 97ba195`
审计性质：**只读**。本阶段没有修改任何 `lib/` 或 `packages/` 代码，只新增本文档。
上游依据：用户提供的《V3.0 产品升级与完整开发计划说明书》；2.11.0 发布后审计、2.11.1 五阶段整改记录。

> 本文件里的每条「已实现」都带代码位置与可复现命令；没有代码证据的一律标 `Needs Verification` 或 `Missing`。
> 工作量是工程日估算（1 人），不是承诺；估算按「熟悉本仓库的工程师」口径。

---

## 1. 审计方法

```bash
git rev-parse --abbrev-ref HEAD            # main
git rev-parse --short HEAD                 # 97ba195
git tag --points-at HEAD                   # 空（v2.11.0 指向 cfcbaa5）
git rev-list --count v2.11.0..HEAD         # 16
git status --short                         # 空
find lib -name '*.dart' -not -name '*.g.dart' | xargs wc -l
flutter analyze                            # No issues found!
flutter test                               # 2020 passed / 20 skipped（带公开样本时 2030 / 10）
```

- 代码规模（不含生成文件）：`lib/` 50,051 行；`packages/analysis_model` 4,264、`apk_parser` 20,602、
  `ipa_parser` 15,818、`app_icon_extractor` 991、`archive_safety` 904。
- 测试：根 `test/` 188 个 `*_test.dart`，`packages/` 57 个。
- 多语言：`assets/i18n/*.json` 六语言，`zh-CN` 1,696 个叶子键（ja/ko 已在 2.11.1 第三阶段补齐）。
- 报告契约：`lib/utils/analysis_report.dart:2871` `reportSchemaVersion = 11`；契约文件
  `docs/contracts/analysis-report-v11.schema.json`。

---

## 2. 基线状态

| 项 | 状态 | 证据 |
| --- | --- | --- |
| 当前分支 / HEAD | `main @ 97ba195` | 上面的 git 命令 |
| 工作区 | 干净 | `git status --short` 空 |
| `v2.11.0` tag | 未被移动 | `git rev-parse --short v2.11.0^{commit}` = `cfcbaa5` |
| main 与 tag 关系 | main 领先 16 个提交（整改 + 样本门禁 + 文档） | `git rev-list --count v2.11.0..HEAD` = 16 |
| main 合入状态 | 已合入（2.11.1 第二阶段） | merge commit `f996a71`；`git rev-list --count origin/main..HEAD` = 0 |
| 样本门禁 | Android 真实执行 | CI run `46148768077` success；`test/samples/manifest.json` 两个公开 APK |
| iOS 样本门禁 | **未覆盖** | 无可再分发 `.ipa`；smoke 测试按平台显式降级 |
| Windows / Linux 实机 | **未验证** | 只有 CI 构建 + 冒烟；`docs/audit/APPINFOTOOL_2.11.1_MANUAL_ACCEPTANCE.md` 待执行 |
| macOS 签名 | ad-hoc | 无 Developer ID，未公证 |
| 2.11.1 发布判定 | **NO-GO** | `docs/audit/APPINFOTOOL_2.11.1_RELEASE_ACCEPTANCE.md` |
| 静态预算 | 有守卫 | `test/budget_guard_test.dart`（8 条），`packages/archive_safety` |

结论：main 是一份**可构建、可测试、可复现**的基线，但「2.11.1 正式发布」还没获批。
V3 阶段 1 可以在这个基线上开工；阶段 2 之后凡是需要「宣称支持」的平台能力，仍要补实机证据。

---

## 3. 现有能力盘点（V3 可复用的部分）

### 3.1 解析与容器

| 能力 | 位置 | 说明 |
| --- | --- | --- |
| APK / XAPK / APKM / APKS / AAB | `lib/apkparser/apk_info.dart:309` `getApkInfo` | 内置解析优先，aapt2 仅兜底；AAB 有独立 `packages/apk_parser/lib/src/aab/` |
| IPA | `lib/ipaparser/ipa_analysis.dart:45` `IpaAnalysis` / `:252` `IpaAnalysisReader` | 含嵌套 bundle、framework、签名材料 |
| AXML / ARSC / DEX / ELF | `packages/apk_parser/lib/src/` | 纯 Dart，无外部工具 |
| Mach-O / Assets.car | `packages/ipa_parser/lib/src/` | Assets.car 的 deepmap2 约 50% 出图率（已知限制） |
| 归档安全 | `packages/archive_safety/lib/src/bounded_read.dart` | `ZipBudgetLimits`：单条目 512 MiB / 总 2 GiB / 会话 1 GiB |
| 条目枚举 | `ApkReader.listFiles()/readFile()` | 库识别面板已用；文件浏览器可直接复用 |

### 3.2 安全分析（现有）

| 能力 | 位置 | 状态 |
| --- | --- | --- |
| Finding / Evidence / Coverage 模型 | `packages/analysis_model/lib/src/security_finding.dart:256/341/555`、`analysis_coverage.dart:53` | 已实现 |
| Artifact 清单 | `packages/analysis_model/lib/src/artifact_inventory.dart:12/155` | 已实现（path/kind/size/arch/sha256/contentScanned/skipCode） |
| 网络线索 | `packages/analysis_model/lib/src/network_endpoints.dart`、`network_facts.dart:5` | 已实现（domains/ips/clues） |
| 动态加载图 | `packages/analysis_model/lib/src/load_graph.dart:7` | 已实现（只覆盖 `loadLibrary/load` 一类边） |
| DEX 方法引用 / invoke / 调用链 | `packages/apk_parser/lib/src/security/dex_method_scanner.dart:13/63/360` | 已实现（供 load graph、code markers 使用） |
| 载荷探测（熵） | `packages/apk_parser/lib/src/security/payload_probe.dart:18` | 已实现（加密/打包分类，不是密钥检测） |
| Android 权限元数据 | `assets/data/android/protection.json`（1102 条）+ `permission_catalog.dart`（33 条语义规则） | 已实现 |
| 第三方 SDK 识别 | `packages/apk_parser/lib/src/libraries/` + `assets/libchecker/libchecker_v5.json`（3053 条） | 已实现（Android：native / 组件 / DEX 包名） |
| iOS 隐私审计 | `packages/ipa_parser/lib/src/security/ios_privacy_audit.dart:144` | 已实现（相机/相册/ATS/上传等规则，产出 Finding） |
| iOS 用法描述 | `privacyUsageDescriptions` → `lib/pages/info_page.dart:1011` | 已实现 |

### 3.3 结果与呈现

| 能力 | 位置 | 说明 |
| --- | --- | --- |
| 统一分析模型 | `lib/models/analysis/package_analysis_result.dart` | `AndroidPackageInfo` / `IosPackageInfo` / `SignatureAnalysis` / `HardeningHint` |
| 分析记录 | `lib/models/analysis/analysis_run.dart`（`schemaVersion = 1`）+ 仓库 `analysis_run_repository.dart`（索引 schema 2） | 有 `snapshot`，历史页可查看快照 |
| 报告 | `lib/utils/analysis_report.dart`（schema 11） | Markdown / JSON / HTML；含权限分级、库识别、包内证书 |
| 版本对比 | `lib/models/analysis/package_diff_adapter.dart`（23 个字段 id）+ `lib/ui/diff/diff_page.dart` | 只比**当前会话已解析**的两个包 |
| 文件结构 | `ContainerStructure`（`packages/apk_parser/lib/src/container_structure.dart`） | 只有目录统计 + dex/native 清单，没有逐文件浏览 |
| UI | `lib/ui/`（V4）+ `lib/pages/` | Paper & Signal，九个 Tab |
| 多语言 | `assets/i18n/*.json` + `lib/gen/` | 六语言，键全量一致 |

### 3.4 工程能力

| 能力 | 状态 |
| --- | --- |
| 预算守卫 | `test/budget_guard_test.dart`（8 条） |
| 真实样本门禁 | `test/samples/manifest.json`（2 个公开 APK，sha256 固定）、`test/real_samples_smoke_test.dart` |
| CI | `.github/workflows/build.yml`：quality / external-samples / windows / macos / linux / release（9 个 job） |
| 发布 | `v2.11.0` 已发布（5 个产物，带「真实样本未验证」历史警告） |

---

## 4. 十大功能对照表

状态口径：`Implemented` / `Partially Implemented` / `Missing` / `Needs Verification` / `Blocked`。
「工作量」只算**新增**，不含回归与文档；单位：工程日。

| 编号 | 功能 | 状态 | 现有实现（可复用） | 必须新增 | 依赖 | 工作量 |
| --- | --- | --- | --- | --- | --- | --- |
| F01 | 敏感信息与密钥泄漏 | **Missing** | `PayloadProbe._entropy`（熵原语，`payload_probe.dart:307`）、`ArtifactInventory`（文件清单/大小/哈希）、`ZipHelper` 流式读 | `SecretMatch` 模型、规则库（格式+上下文+校验）、脱敏管道、`SecretScanner`、UI 面板、报告节 | 阶段 1 模型；F04 的文件访问 | 8–12 |
| F02 | 隐私与第三方 SDK | **Partially** | LibChecker 3053 条（Android native/组件/DEX）、`sdk_catalog`（25 个服务 SDK + 版本）、权限 1102 条、iOS 隐私审计规则、`NetworkFacts` | 统一 `Component`/`PrivacySignal` 模型、iOS framework→SDK 识别、SDK↔权限↔API↔网络的关系、置信度与来源、UI 与导出 | 阶段 1；F03 共享组件身份 | 10–14 |
| F03 | SBOM | **Missing** | `LibraryReport`（label/iconId/hits/rule）、`ContainerStructure.nativeLibraries`、iOS 嵌套二进制 | `SbomDocument`、PURL 规范化、CycloneDX/SPDX 序列化、Schema 校验、UI 与导出 | 阶段 1；F02 组件身份 | 7–10 |
| F04 | 深度文件浏览器 | **Partially** | `ApkReader.listFiles/readFile`、`ContainerStructure`、`ArtifactInventory`、`ZipBudgetLimits` | 虚拟文件树、搜索/筛选、流式哈希、文本/Hex/图片查看器、安全导出、Evidence 联动 | 阶段 1 | 12–16 |
| F05 | 版本深度差异 | **Partially** | `package_diff_adapter`（23 字段）、diff 页（字段/集合/无法比较）、`AnalysisRun` 快照 | 基于 AnalysisRun 的对比、Artifact/SDK/Evidence/Coverage/SBOM 差异、`notComparable` 语义、身份校验、报告 | 阶段 1；F02/F03 | 10–14 |
| F06 | 误报与处置工作流 | **Missing** | Finding 不可变、历史记录 | `FindingDisposition`、稳定 fingerprint、处置 UI、审计历史、重扫匹配、抑制范围 | 阶段 1（fingerprint 设计） | 8–12 |
| F07 | DEX API 调用关系 | **Partially** | `DexMethodScanner`（method refs、invoke、调用链）、`LoadGraph`、code markers、Evidence | 敏感 API 分类库、通用调用图模型与存储、图查询/深度限制、UI 图、预算与 Coverage | 阶段 1；F02 API 分类 | 12–18 |
| F08 | 离线漏洞情报 | **Missing** | `LibraryReport` / `SdkHit.version`（仅 25 个服务 SDK 有版本）、`artifact_inventory` 哈希 | 组件身份（PURL）、OSV 导入、版本范围比较、本地库与版本化、匹配置信度、UI/报告 | 阶段 1；F02/F03 | 10–16 |
| F09 | CLI 与 CI | **Missing** | 五个 package 均为纯 Dart；`AnalysisReport.renderJson`；`tool/` 已有验证脚本 | 独立 executable、无 Flutter 的分析编排层、命令解析、退出码、JSON/SARIF 输出、Profile 接入 | 阶段 1；F10 的 Profile | 8–12 |
| F10 | Profile 与自定义规则 | **Missing** | 预算常量（`ZipBudgetLimits`、`DexClueScanner` 等） | Profile Schema、规则 Registry、声明式规则引擎（正则安全）、Rule Pack 导入/导出/校验、UI 管理 | 阶段 1 | 12–16 |

**结论：没有任何一项是「已实现」；两项 Partially（F02/F05）、一项 Partially 偏基础（F04/F07），其余 Missing。**
这与「V3 不是加十个页面」的判断一致：真正缺的是**统一数据模型 + 组件身份 + 规则/Profile 机制 + 无头编排**。

---

## 5. 数据模型现状 vs V3 要求

| V3 模型 | 现状 | 结论 |
| --- | --- | --- |
| `AnalysisRun` | 存在：`analysis_run.dart`（schema 1），含 snapshot、limitations、状态机 | **扩展**，不要新建第二套 |
| `Artifact` | 部分：`ArtifactInventory.entries`（有 path/kind/size/sha256/skipCode），仅扫描过的条目有哈希 | **扩展**成一等 identity（artifactId、parentPath、archiveEntry） |
| `Evidence` | 存在：`SecurityEvidence`（source/location/detail + code/args 本地化） | **复用**，补 `redactedValue`/extractor id |
| `Finding` | 存在：`SecurityFinding`（ruleId/severity/confidence/evidence/relationship/limitation） | **复用**，补 fingerprint（当前无） |
| `Component` | 部分：`LibraryGroup`/`LibraryHit`（label/iconId/rule/hits），无 name/version/purl 统一身份 | **新建**统一 Component，LibraryReport 作为数据源之一 |
| `SecretMatch` | 无 | 新建 |
| `PrivacySignal` | 无（iOS 隐私规则产出的是 Finding） | 新建（或先复用 Finding + 分类） |
| `SBOMDocument` | 无 | 新建 |
| `VulnerabilityMatch` | 无 | 新建 |
| `FindingDisposition` | 无 | 新建 |
| `CallGraphNode/Edge` | 部分：`LoadGraph` 只覆盖动态加载边 | 新建通用调用图，LoadGraph 作为其中一类 |
| `ScanProfile` / `RulePack` | 无；预算写死在常量里 | 新建 |

`Finding` 目前**没有 fingerprint**（`grep -rn "fingerprint" lib packages/*/lib` 只命中 baseline 证书指纹）。
F06 的前提是先设计稳定 fingerprint，并考虑 `ruleId + 归一化路径 + 归一化值` 的兼容策略。

---

## 6. 架构与依赖方向

```
lib/ (Flutter app)  ──imports──>  packages/*（纯 Dart，除 app_icon_extractor 用 dart:ui）
   │                                   apk_parser / ipa_parser
   │                                   analysis_model / archive_safety
   └─ 分析编排在 app 层：getApkInfo / IpaAnalysisReader
```

- `packages/apk_parser`、`ipa_parser`、`analysis_model`、`archive_safety` **不依赖 Flutter**（已核对 imports）。
- `packages/app_icon_extractor` 使用 `dart:ui`（图片解码），这是 CLI 复用时要绕开的一块。
- `lib/apkparser/apk_info.dart` 自己 import 了 `dart:ui`、`Config`、slang 生成的 `strings.g.dart`，
  因此**现在的分析入口不能直接在 CLI 里跑**。F09 需要把「编排 + 报告」下沉到一个纯 Dart 包
  （建议 `packages/app_analysis`），app 层只保留 UI 适配。
- 这是一次结构性重构，但比在 CLI 里复制一遍 `getApkInfo` 便宜，也避免两条路径漂移。

---

## 7. 关键风险

| 风险 | 说明 | 缓解 |
| --- | --- | --- |
| 报告契约变更 | 现有 schema v11 被导出/验收引用；新增敏感信息、SBOM、漏洞字段必然升版 | 每阶段只升一次 schema，保留旧契约文件与迁移说明 |
| 快照不是完整模型 | `snapshot` 是报告 JSON，不是可查询模型；F05/F06 需要结构化历史 | 阶段 1 决定：扩展 run 目录（结构化 JSON）还是从 snapshot 反解 |
| 敏感信息落盘 | 一旦把明文写进报告/日志/历史，等于制造新的泄漏面 | 默认脱敏 + 指纹 + 显式导出；阶段 2 的安全设计评审前置 |
| iOS 组件身份弱 | 嵌套 framework 只有路径/名称，没有 bundle id/版本；无可分发 `.ipa` 样本 | F02/F03 先做「可证实字段」，未知不补值；合成 fixture 标注 synthetic |
| 平台验证缺口 | Windows/Linux 无实机，iOS 无真机 | V3 发布标准要求实机证据；阶段 9 前必须解决，否则只能「有条件发布」 |
| 性能与预算 | 已有 idle 基线 +40–50 MiB（2.11.1 AOT 实测）；新扫描器会叠加 | 每个扫描器接 `Coverage` 预算；阶段 9 用真实包做 A/B |
| 自定义规则安全 | 正则灾难性回溯、规则包投毒 | 声明式规则 + 长度/超时/预算 + 规则校验失败不加载 |
| 误报治理 | 没有 fingerprint，重扫无法稳定匹配旧 Finding | 阶段 1 先定 fingerprint，再做处置 UI |
| 真实样本不足 | 只有 2 个公开 APK，无 IPA | 建立 `test/samples` 矩阵；合成样本显式标记 |

---

## 8. 阶段拆分与顺序（按本仓库现实调整）

| 阶段 | 内容 | 依赖 | 出口 |
| --- | --- | --- | --- |
| 0 | 本审计 | — | 本文档 |
| 1 | 分析基础设施：模型统一、`Component`、fingerprint、Profile/规则 Schema、结果持久化、迁移 | 0 | `docs/architecture/APPINFOTOOL_V3_ANALYSIS_ARCHITECTURE.md`；旧数据可读 |
| 2 | F04 文件浏览器（只读）+ F01 敏感信息（脱敏） | 1 | 真样本命中 + 无明文落盘 |
| 3 | F02 SDK/隐私 + F03 SBOM（CycloneDX 先行，SPDX 随后） | 1、2 的文件/组件身份 | Schema 校验通过 |
| 4 | F05 深度差异 + F06 处置工作流 | 1、3 | 历史 run 对比；处置不污染原始结果 |
| 5 | F07 API 调用关系（受限图） | 1、3 | 关系有证据、预算生效 |
| 6 | F08 离线漏洞匹配 | 3 | 固定 fixture 命中，未知版本不定性 |
| 7 | F10 Profile 与自定义规则 | 1 | Profile 真控扫描；规则不执行代码 |
| 8 | F09 CLI / CI | 1、7 | CLI 与 GUI 同配置同结果 |
| 9 | 集成、样本矩阵、跨平台、验收 | 全部 | `APPINFOTOOL_V3_RELEASE_ACCEPTANCE.md` |

说明：F09 被排在 F10 之后，因为 CLI 需要 Profile 作为配置入口；若只想先给「analyze 一个包」，
可以在阶段 4 后插一个**最小 CLI**（仅 `analyze --format json`），但命令面要标 experimental。

---

## 9. 工作量汇总

| 区块 | 工程日（估） |
| --- | --- |
| 阶段 1 基础设施（模型、fingerprint、Profile Schema、迁移） | 15–22 |
| F01 + F04 | 20–28 |
| F02 + F03 | 17–24 |
| F05 + F06 | 18–26 |
| F07 | 12–18 |
| F08 | 10–16 |
| F10 | 12–16 |
| F09 | 8–12 |
| 阶段 9 集成/样本/跨平台/性能 | 12–20 |
| **合计** | **124–182 工程日** |

不含：Windows/Linux 实机环境准备、iOS 设备与描述文件、macOS 公证证书。这些是外部阻塞项，
不解决就只能「有条件发布」。

---

## 10. V3.0 最小可交付范围（MVP）

建议 MVP = 阶段 1 + 阶段 2 的 F01 + 阶段 3 的 F03（只 CycloneDX）+ 阶段 4 的 F05（只 run 级对比）
+ 最小 CLI（`analyze` / `sbom`，JSON + CycloneDX）。

理由：

- 这五项共用同一套「Artifact → 规则 → Evidence → Finding → 导出」链路，做完就有可演示的价值闭环；
- F02 的 iOS 身份与 F07 的图、F08 的漏洞库，都依赖更多外部数据与设计，适合作为第二阶段；
- F06 处置工作流需要 fingerprint 先在阶段 1 定稿，否则会返工。

MVP 验收：

1. 对一个真实 APK：产出文件清单、敏感信息（脱敏）、CycloneDX SBOM、Finding 列表；
2. 两个版本：产出 run 级差异（权限/组件/SDK/Finding/覆盖率）；
3. CLI 在无 GUI 环境跑通，退出码符合约定；
4. 报告 schema 升版并保留旧契约；
5. 全部新扫描器接入预算与 `Coverage`；
6. 每个新扫描器至少一组规则 fixture + 一条预算/取消测试，新增测试合计 ≥ 40 条；
   CI 在 Windows/macOS/Linux 构建通过（实机验收另计）。

---

## 11. 进入阶段 1 的前置条件

| 条件 | 现状 | 是否阻塞阶段 1 |
| --- | --- | --- |
| main 含整改、可独立构建 | 满足 | 否 |
| `v2.11.0` tag 未移动 | 满足（`cfcbaa5`） | 否 |
| 真实样本门禁在 CI 执行（Android） | 满足（`46148768077`） | 否 |
| ja/ko 键一致 | 满足 | 否 |
| Windows/Linux 实机 | 未完成 | 否，但阻塞 V3 发布 |
| iOS 真机 E2E | 未完成 | 否，但阻塞 V3 发布 |
| 2.11.1 发布判定 | NO-GO | 否，阶段 1 只改内部模型 |

结论：**阶段 1 可以立即开始**；阶段 2 起每增加一个「对外宣称」的能力，都要同步补样本与平台证据，
不能等到阶段 9 才发现无法验收。

---

## 12. 阶段 0 自查

- [x] 只读：本阶段没有改任何代码；`git status` 只应有本文档。
- [x] 每项结论有代码位置或命令输出。
- [x] 没有把「已有 Findings UI」写成「已有 F06 处置工作流」。
- [x] 没有把 `PayloadProbe` 的熵写成「已实现密钥检测」。
- [x] 没有把 `LoadGraph` 写成「完整调用图」。
- [x] 没有编造性能数字；AOT 内存引用的是 `APPINFOTOOL_2.11.1_PHASE4_VERIFICATION.md` 的实测。
- [x] 十项功能均有状态、复用清单、依赖与工作量。
