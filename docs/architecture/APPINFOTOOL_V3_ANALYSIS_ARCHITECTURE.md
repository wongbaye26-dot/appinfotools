# AppInfoTool V3.0 分析基础设施架构（阶段 1）

状态：进行中（阶段 1）
日期：2026-11-28
上游：`docs/audit/APPINFOTOOL_V3_BASELINE_AUDIT.md`、`docs/product/APPINFOTOOL_V3_PROGRESS.md`

本文只回答一件事：**V3 的十项功能共用什么数据基础、这些数据怎么标识、怎么存、怎么兼容旧版本。**
具体扫描器的实现细节放在各功能自己的设计文档里（阶段 2 起）。

---

## 1. 原则

1. 平台中立模型放 `packages/analysis_model`；Android / iOS 只负责**产出**，不定义公共模型。
2. 已有模型优先扩展，不因说明书里的命名重复建类。
3. 所有 V3 新模型都**可 JSON 往返**，且带 `schemaVersion`。
4. 未知就是未知：版本、厂商、许可证拿不到就留空，不用 `unknown` 之类的假值填充。
5. 关系分四档：`explicitEvidence` / `staticReference` / `inferred` / `unknown`，不允许把推断写成确定。
6. 任何新扫描器都必须接**预算**与 `Coverage`，超预算要能说出来。

---

## 2. 目录与依赖方向

```
packages/analysis_model/lib/src/v3/
├── component.dart              # Component / ComponentIdentity / PURL
├── finding_fingerprint.dart    # 稳定指纹
├── artifact_identity.dart      # Artifact 身份派生与规范化
├── scan_profile.dart           # Profile / RulePack 模型（阶段 1 只做模型与校验）
└── (后续) secret_match.dart / privacy_signal.dart / sbom_document.dart

packages/app_analysis/          # 阶段 8 新建：无头编排（纯 Dart）
├── lib/app_analysis.dart
└── lib/src/analyze.dart        # 输入路径 → 完整结果 → 报告

lib/                            # Flutter app：只做 UI 适配
```

- `analysis_model` 保持**零 Flutter 依赖**；新增依赖只允许纯 Dart 包（如 `crypto`）。
- `apk_parser` / `ipa_parser` 只依赖 `analysis_model`，不反向依赖。
- 阶段 8 之前，`lib/apkparser/apk_info.dart` 仍是唯一 Android 编排入口；阶段 8 把它下沉，
  app 层改成薄封装。**不提前复制第二份编排逻辑。**

---

## 3. 模型定义

### 3.1 Component（F02 / F03 / F08 共用）

```dart
enum ComponentEcosystem { maven, npm, cocoapods, swift, generic }
enum ComponentPlatform { android, ios, unknown }
enum ComponentIdentificationMethod {
  manifestName,      // 清单/Info.plist 里能直接读到的名字
  mavenPom,          // META-INF/maven/**/pom.properties
  dexPackage,        // DEX 包名前缀（LibChecker type 5）
  nativeLibrary,     // .so / .dylib 文件名（LibChecker type 0）
  componentClass,    // 组件类名（LibChecker type 1–4）
  frameworkBundle,   // iOS 嵌套 bundle 的 Info.plist
  ruleMatch,         // 通用规则命中（如已知 SDK 特征）
  userImport,        // 用户导入的 SBOM/规则
}
enum ComponentConfidence { high, medium, low, unknown }
enum ComponentRelationType { contains, dependsOn, evidencedBy }
```

`Component` 字段（全部可空 = 不知道）：

| 字段 | 说明 |
| --- | --- |
| `id` | 稳定本地 id：`cmp_<sha1(name|version|ecosystem|platform)>`，不含路径 |
| `name` / `version` | 组件名与版本；版本拿不到必须为 null |
| `ecosystem` / `platform` | PURL 生态与平台 |
| `purl` | 由 `ComponentPurl.build(...)` 生成，拼不出来就 null |
| `supplier` / `licenses` | 厂商、许可证标识（SPDX 表达式或原文） |
| `hashes` | `Map<String, String>`，算法 → 小写十六进制 |
| `sourceArtifacts` | 包内路径列表（去重、排序） |
| `identification` | 识别方式 + 置信度 + 数据来源版本 |
| `confidence` | `high` 仅当 name 与 version 都可证实 |

**PURL 规则**（`ComponentPurl`）：

- `maven`：`pkg:maven/<groupId>/<artifactId>@<version>`，groupId 的 `.` 保留、`/` 转义；
- `cocoapods`：`pkg:cocoapods/<name>@<version>`；
- `swift`：`pkg:swift/<name>@<version>`；
- `generic`：`pkg:generic/<name>@<version>`；
- 名称与版本做 PURL 百分号编码（空格 → `%20`，`@` → `%40`，`/` 在 name 里 → `%2F`）；
- 没有 version 时**不输出** `@`，且调用方要能看出这是「无版本」。

### 3.2 FindingFingerprint（F06 前提）

```dart
class FindingFingerprint {
  static const int version = 1;
  static String of({
    required String ruleId,
    required String platform,
    String? artifactPath,
    String? location,
    String? value,
  });
}
```

- 组成：`v1|<platform>|<ruleId>|<artifactPath>|<location>|<sha256(value)[:16]>` 的 SHA-256，取前 32 位十六进制；
- 规范化：
  - 路径：统一 `/`、去前导 `/`、去 `./`、小写；
  - 位置：去 `+0x…` 偏移与 `:行号` 行号（构建会变），合并空白，小写；
  - 值：trim + 合并空白 + 小写；哈希后只保留 16 位，避免指纹本身泄漏明文；
- **不含**数组下标、时间戳、分析 id；
- 版本号写进指纹（`v1`），将来调整算法必须升版本，并保留旧版本读取。

### 3.3 Artifact identity（F04 / F05 前提）

在现有 `ArtifactEntry` 上扩展（不新建平行类型）：

| 新字段 | 说明 |
| --- | --- |
| `artifactId` | `art_<sha1(path)[:16]>`，同一包内稳定 |
| `parentPath` | 目录或父归档路径，根为 null |
| `archiveEntry` | 嵌套归档内的条目名（普通 zip 条目为 null） |

兼容：全部可选、默认 null；旧 JSON 反序列化不变；新 JSON 多出字段不影响旧读取方。

### 3.4 Evidence 扩展

在 `SecurityEvidence` 上增加两个可选字段：

- `redactedValue`：脱敏后的展示值（如 `sk-…a1b2`），用于 F01；
- `extractorId`：产出该证据的扫描器 id（`secret.regex.v1` 等），用于溯源与规则统计。

约束：新增字段**不得**改变现有构造调用的语义；序列化只在非 null 时写出。

### 3.5 ScanProfile / RulePack（阶段 1 只做模型与校验）

```json
{
  "schemaVersion": 1,
  "id": "full",
  "name": "Full Scan",
  "version": "1.0.0",
  "platforms": ["android", "ios"],
  "scanners": ["manifest", "permissions", "artifacts", "secrets", "sdk", "sbom"],
  "budgets": {"maxTotalBytes": 1073741824, "maxEntries": 20000},
  "rulePacks": ["core/android", "core/secrets"],
  "thresholds": {"failOn": "high"}
}
```

校验规则（Dart validator，后续 CLI 共用）：

- 必填：`schemaVersion` / `id` / `name` / `version` / `platforms` / `scanners`；
- `scanners` 必须是已知集合的子集，未知扫描器直接拒绝（不做「忽略未知继续跑」）；
- `budgets` 不得超过全局硬上限；
- `rulePacks` 必须可解析（阶段 7 接真实规则包）；
- 校验失败**整体拒绝加载**，不允许部分生效。

---

## 4. 唯一性与序列化

- `AnalysisRun.id` 已有规则（时间 + 哈希前缀），不改。
- `Component.id`、`artifactId`、`Evidence.id`、`Finding` 的 fingerprint 都**不含分析 id**，便于跨 run 对比。
- JSON 键一律 `camelCase`；时间一律 ISO-8601 UTC；哈希一律小写十六进制；路径一律 `/`。
- 每个新模型带 `toJson()` / `fromJson()`，并配往返测试（含未知字段忽略、缺字段容错）。

---

## 5. 持久化与迁移

现状：`AnalysisRun`（schema 1）把 `AnalysisReport.renderJson` 的整份快照塞进 `snapshot`；
索引 `index.json`（schema 2）只存摘要。

阶段 1 的决定：

1. **不改变 run 目录结构**，先给 `AnalysisRun` 增加可选 `model` 字段（结构化 V3 模型），
   旧 run 没有该字段时视为「只有快照」。
2. `snapshot` 继续保留：它是导出契约的一部分，不能被结构化模型替代。
3. 索引 schema 只有在字段变化影响列表展示时才 +1（与 2.11.1 的处理方式一致）。
4. 迁移只做**读兼容**：旧 run 缺字段 → 默认值；不批量重写用户历史（除非用户显式触发重建）。

---

## 6. 预算与 Coverage 约定

每个新扫描器必须声明并遵守：

- 输入预算（字节 / 条目数）；
- 输出预算（条数上限）；
- 超限时写 `CoverageEntry(status: partial/unsupported, limit:, note:)`；
- 可取消（长任务接 `CancellationToken`，阶段 8 的 CLI 也要能中断）。

现有常量作为硬上限基线：`ZipBudgetLimits`（512 MiB / 2 GiB / 1 GiB）、
`SdkInventoryScanner.maxDexBytes = 64 MiB`、`DexClueScanner`（8/48 MiB）等，
由 `test/budget_guard_test.dart` 钉住。

---

## 7. 向后兼容规则

- 报告 schema：阶段 2 起每升一次版（v12…），都要新增契约文件并保留旧契约；
- 旧 JSON 读取必须容错：未知键忽略、缺失键用默认值、非法类型报可读错误；
- 不删除已有公开字段；重命名走「新字段 + 旧字段兼容读取」；
- 每次改模型都要有「旧样例 → 新代码」测试。

---

## 8. 测试策略（阶段 1）

1. 每个模型：JSON 往返、缺字段、未知字段、非法类型；
2. PURL：maven/cocoapods/generic 的正常与转义用例；
3. fingerprint：同输入稳定、路径/大小写/偏移变化不变、规则变化必变；
4. Artifact identity：同路径稳定、跨包不同、嵌套条目区分；
5. Profile validator：缺字段、未知 scanner、预算超上限、通过用例；
6. 兼容：用 2.11.x 的真实 run JSON 样例做读取测试。

---

## 9. 阶段 1 出口检查

- [ ] 新模型全部可序列化/反序列化；
- [ ] 2.11.x 的 run/索引可读（至少一条真实样例）；
- [ ] `Component`、fingerprint、artifact identity 有测试；
- [ ] Profile/RulePack Schema 与校验器可用；
- [ ] 没有重复存储同一业务数据（快照 vs 结构化模型边界清楚）；
- [ ] UI 与未来的 CLI 都能复用同一模型（不 import Flutter）。
