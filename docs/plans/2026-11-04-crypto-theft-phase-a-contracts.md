# 盗 U 检测能力 — Phase A 契约冻结
## 接口契约 / 数据模型草案 / JSON Schema v8 / Golden 设计

> **状态**：Phase A 契约冻结稿（**尚未实现任何代码**）
> **基线**：AppInfoTool `2.8.7`（`b7adbc5`）｜**日期**：2026-11-04
> **依据**：`docs/plans/2026-11-04-crypto-theft-detection-design.md` v1.1
> **已确认决策**：D1 无语料；D2 你们可提供官方包/公开证书或 Team 指纹；D3 只给风险证据、不给恶意判决
> **本阶段不做**：不改生产代码、不建 Dart 模型文件、不加依赖、不跑样本、不联网
> **交付物**：本契约 + `docs/contracts/crypto-theft-security-v8.schema.json` + `docs/contracts/official-baseline-v1.schema.json` + 3 份示例 JSON
> **冻结后**：Phase B 才创建 Dart 模型与扫描器；任何字段变更必须回到本文件升版本

---

## 0. 验收清单（Phase A 结束时逐项打勾）

- [ ] 设计文档 v1.1 与契约中的枚举、字段名、JSON 路径、规则 ID 完全一致。
- [ ] `security` 新对象的 JSON Schema 通过 `json-schema` 校验（Draft 2020-12）。
- [ ] 两份 `security-v8.*.example.json` 均通过 Schema 校验。
- [ ] `official-baseline-v1.example.json` 通过基线 Schema 校验。
- [ ] 每个字段都有 `null` 语义（未做/不可得）与 `unknown` 语义（做了但判不出），不用空串/空列表冒充。
- [ ] 16 条规则 ID 冻结；2 条 IoC 标记 deferred；MVP 启用的 10 条明确列出。
- [ ] 官方基线库格式、匹配算法、指纹规范化、数据来源/复核流程冻结。
- [ ] Golden 用例矩阵（12 例）与不变量（10 条）冻结，Phase B/C 可直接落成测试。
- [ ] `SecurityAnalysisResult.withLimitation` / `SecurityFinding.withDedupedEvidence` 的拷贝完整性列入专项测试。
- [ ] Markdown / JSON / UI 同源断言（键集合包含关系）冻结。
- [ ] 无生产代码改动（`git status` 只多文档/契约文件）。

---

## 1. 依赖与边界（冻结）

| 项 | 冻结内容 |
|---|---|
| 依赖方向 | `analysis_model` 保持零依赖；`apk_parser` / `ipa_parser` **不新增** `crypto` 或其它包；应用层注入 `ContentDigestFn` 与基线库 |
| 哈希 | 通过 `ContentDigestFn` 注入；未注入时 `seal.state=notChecked` + 覆盖 `notCovered`，**不得**显示 `verified` |
| 基线库 | 应用层加载 `assets/baseline/official_baseline_v1.json`，通过参数注入审计/评估器；parser 包不读 Flutter assets |
| 家族 IoC | **deferred（D1）**：`IocRule` 接口保留，v8 不输出 `iocMatches`；`T-KNOWN-FAMILY` / 2 条 IOC 规则不启用 |
| 运行环境 | 不执行样本、不联网、不落盘敏感内容；证据只出现路径/偏移/哈希前缀 |
| iOS 审计 | Phase B 前置：从 `lib/pages/info_page.dart:429` 的 UI 同步调用移入后台任务；Phase A 只冻结接口 |
| 输出口径 | PASS/HIT/UNKNOWN；不出现"木马/恶意"；P1 只用于事实级（基线不匹配/密封不匹配） |

---

## 2. 模块与文件契约

Phase B/C 将创建以下文件；**本阶段只冻结职责与接口，不创建空实现**。

| # | 文件 | 职责 | 归属 | 依赖 |
|---|---|---|---|---|
| C1 | `packages/analysis_model/lib/src/container_facts.dart` | 条目事实（平台无关） | analysis_model | 无 |
| C2 | `packages/analysis_model/lib/src/artifact_inventory.dart` | 制品清单模型 | analysis_model | 无 |
| C3 | `packages/apk_parser/lib/src/security/artifact_inventory_scanner.dart` | APK 条目 → 清单 | apk_parser | C1/C2 |
| C4 | `packages/ipa_parser/lib/src/security/ios_artifact_inventory.dart` | IPA 条目 → 清单 | ipa_parser | C1/C2 |
| C5 | `packages/analysis_model/lib/src/load_graph.dart` | 加载链模型 | analysis_model | C2 |
| C6 | `packages/apk_parser/lib/src/security/android_load_graph.dart` | DEX/原生加载点 × 包内文件 | apk_parser | C1/C2/C5 |
| C7 | `packages/ipa_parser/lib/src/security/ios_load_graph.dart` | Mach-O load commands × 包内文件 | ipa_parser | C1/C2/C5 |
| C8 | `packages/apk_parser/lib/src/security/payload_probe.dart` | 载荷探测（有界头部） | apk_parser | C1/C2 |
| C9 | `packages/ipa_parser/lib/src/security/ios_payload_probe.dart` | 同上（IPA） | ipa_parser | C1/C2 |
| C10 | `packages/analysis_model/lib/src/package_seal.dart` | 密封模型 + 摘要注入类型 | analysis_model | 无 |
| C11 | `packages/apk_parser/lib/src/security/apk_seal_check.dart` | APK v1/v2 摘要比对 | apk_parser | C10 |
| C12 | `packages/ipa_parser/lib/src/security/ios_code_resources_check.dart` | CodeResources 哈希比对 | ipa_parser | C10 |
| C13 | `packages/analysis_model/lib/src/crypto_theft.dart` | 评估/证据链模型 | analysis_model | C2/C5/C10 |
| C14 | `packages/apk_parser/lib/src/security/crypto_theft_chain.dart` | Android 判级（纯函数） | apk_parser | C13 |
| C15 | `packages/ipa_parser/lib/src/security/ios_crypto_theft_chain.dart` | iOS 判级（纯函数） | ipa_parser | C13 |
| C16 | `packages/analysis_model/lib/src/official_baseline.dart` | 官方基线模型 | analysis_model | 无 |
| C17 | `packages/analysis_model/lib/src/security_finding.dart`（改） | 新证据来源 / 盲区字段 / 结果字段 | analysis_model | C2/C5/C10/C13/C16 |
| C18 | `packages/apk_parser/lib/src/apk_reader.dart`（改） | 一次遍历暴露条目事实表 | apk_parser | C1 |
| C19 | `lib/apkparser/parse_task.dart`、`lib/ipaparser/ipa_parse_task.dart`（改） | 注入条目事实/digest/基线；iOS 后台化 | app | C3/C6/C8/C11/C14/C15/C18 |
| C20 | `lib/utils/official_baseline_store.dart` | 加载/校验基线 JSON | app | C16 |
| C21 | `lib/utils/crypto_theft_assessor.dart` | 静态证据 + 签名 + 基线 → 评估 | app | C13/C16 |
| C22 | `lib/widgets/crypto_theft_card.dart`、`lib/utils/analysis_report.dart`（改）、`lib/pages/info_page.dart`（改） | UI/报告同源 | app | C13/C21 |

> `ContainerEntryFact` 与两个 parser 的 `ArtifactInventory` 共用模型放 `analysis_model`；`ContentDigestFn` 放 `analysis_model/src/package_seal.dart`。

---

## 3. 数据模型契约（Dart 签名草案，Phase B 才落地）

> 约定：`null` = 本次未做 / 不可得；`unknown` 枚举值 = 做了但判不出；**禁止**用空串或空列表表示二者。

### 3.1 条目与制品

```dart
class ContainerEntryFact {
  final String path;            // 归一化 '/'，稳定排序键
  final int sizeBytes;          // 未压缩大小
  final int? compressedBytes;   // 存储型 = sizeBytes；不可得 = null
  final int? compressionMethod; // ZIP method；非 ZIP = null
  final bool isDirectory;
}

enum ArtifactKind {
  dex, elf, machO, dylib, framework, staticLibrary, nestedCodeBundle,
  assetArchive, assetBinary, assetText, script, resourceTable, manifest,
  signatureBlock, unknown,
}

enum ArtifactOrigin {
  embedded,        // 正常包内路径
  bundleRoot,      // iOS .app 根目录（注入强信号）
  frameworks,      // iOS Frameworks/
  nestedBundle,    // 嵌套 .appex/watch/app
  assets,          // assets/ 下的载荷
  remoteReferenced,// 仅被加载链引用、包内不存在
  unknown,
}

class ArtifactEntry {
  final String path;
  final ArtifactKind kind;
  final ArtifactOrigin origin;
  final int sizeBytes;
  final String? arch;              // arm64-v8a / arm64 / x86_64 / null
  final String? sha256;            // 小写 hex；null=未哈希（不是空串）
  final bool contentScanned;       // 是否进入内容级扫描
  final String? skipCode;          // budget.size|budget.count|not.selected|null
  final List<String> suspicionCodes; // payload.encrypted|payload.nestedArchive|...
}

class ArtifactInventory {
  final List<ArtifactEntry> entries; // 只收有安全意义的条目
  final int totalEntries;            // 归档条目总数（覆盖率分母）
  final int inventoriedEntries;      // 实际清单条目数
  final bool entriesComplete;        // 是否被预算/上限截断
  final List<String> skippedCodes;   // inventory.entries_truncated|...
}
```

### 3.1a 载荷探测（Phase B 实现所需的最小模型）

```dart
enum PayloadKind { dex, zip, apk, jar, elf, machO, script, unknown }

class PayloadSignal {
  final String path;
  final PayloadKind kind;
  final String code;       // payload.magicMismatch|payload.nestedArchive|...
  final int sizeBytes;
  final double? entropy;   // 0..8；不可得为 null
  final Map<String, Object> args;
}

class PayloadProbeInput {
  final String path;
  final int sizeBytes;
  final Uint8List headBytes; // 调用方先套 4 KiB 预算
  final String? declaredExtension;
}

class PayloadProbeResult {
  final List<PayloadSignal> signals;
  final int entriesProbed;
  final int entriesTotal;
  final bool complete;
  final List<String> noteCodes;
}
```

> 载荷探测只回答“内容像什么”，不判断恶意；`PayloadSignal` 不携带 severity/confidence。

### 3.2 加载链

```dart
enum LoadNodeKind { dex, elf, machO, dylib, framework, script, missing, unknown }

enum LoadEdgeKind {
  systemLoadLibrary, systemLoad, dexClassLoader, inMemoryDexLoader,
  nativeDlopen, nativeDlsym, machoLinkedLibrary, machoWeakLinked,
  machoRPath, bundleEntryReference, unknown,
}

class LoadNode {
  final String id;                // 'artifact:<path>' | 'runtime:<name>'
  final LoadNodeKind kind;
  final String? resolvedPath;     // null=未映射到包内条目
  final bool presentInPackage;
}

class LoadEdge {
  final String fromId;
  final String toId;
  final LoadEdgeKind kind;
  final SecurityEvidenceSource source; // artifactEntry|loadGraph|nativeSymbol|machoSymbol
  final String location;               // 'Lcom/...@0x12' | 'LC_LOAD_DYLIB#3'
}

class LoadGraph {
  final List<LoadNode> nodes;
  final List<LoadEdge> edges;
  final List<String> danglingEdgeIds; // 目标不在包内
  final bool complete;
}
```

### 3.3 密封

```dart
/// 返回小写 hex；`null` = 该算法不可用；**不得抛异常**。
/// 生产实现由应用层用 `package:crypto` 提供；测试可注入假实现。
typedef ContentDigestFn = String? Function(String algorithm, Uint8List bytes);

enum SealState { verified, mismatch, entryMissing, unsealed, notChecked, unknown }

class SealEntryCheck {
  final String path;
  final SealState state;
  final String algorithm;             // sha256|sha1|md5
  final String? expectedDigestPrefix; // 前 16 hex
  final String? actualDigestPrefix;
}

class SealCheck {
  final String scheme; // apk.v1.manifest|apk.v2.content|ipa.codeResources.v1|ipa.codeResources.v2
  final SealState state;
  final int entriesChecked;
  final int entriesTotal;
  final List<SealEntryCheck> checks; // <=64，mismatch 优先
  final bool signatureVerified;      // 恒 false（本版本不验签）
  final List<String> noteCodes;      // seal.digest_unavailable|seal.entry_limit|...
}
```

### 3.4 评估与证据链

```dart
enum CryptoTheftLevel {
  none, capabilityOnly, suspicious, strongEvidence, knownFamily, unknown,
}

enum TheftTechnique {
  addressSwap, clipboardHijack, mnemonicPhish, keyExfiltration,
  approvalPhish, unknown,
}

enum ChainStage { capability, source, injection, payload, family }

enum TechniqueStrength {
  stringOnly, codeReference, callSite, artifact, baseline, knownFamily,
}

class TechniqueEvidence {
  final TheftTechnique technique;
  final ChainStage stage;
  final String signalId;           // marker id / artifact kind / baseline entry id
  final TechniqueStrength strength;
  final bool supported;
  final List<SecurityEvidence> evidence;
  final List<String> noteCodes;
}

class MissingLink {
  final ChainStage stage;
  final String whyCode; // missing.noSource|missing.noSink|missing.payloadEncrypted|
                        // missing.notCovered.<dimension>|missing.shellPacked
  final Map<String, Object> args;
}

class CryptoTheftAssessment {
  final String id;                      // android.crypto.theft|ios.crypto.theft
  final CryptoTheftLevel level;
  final TheftTechnique? primaryTechnique;
  final List<TechniqueEvidence> chain;  // 恰好 5 项，顺序见 §6
  final List<MissingLink> missing;
  final SecurityConfidence confidence;
  final SecuritySeverity severity;
  final int? score;                     // 0..100；null=未评分
  final String scoringVersion;          // 'theft-1.0'
  final String? baselineEntryId;        // 命中官方基线时非空
}
```

### 3.5 官方基线

```dart
enum BaselineStatus { match, mismatch, noBaseline, unavailable }

class OfficialBaselineEntry {
  final String id;
  final SecurityPlatform platform;
  final String packageId;          // Android 包名 / iOS Bundle ID
  final String displayName;
  final List<String> certSha256;   // 小写 64 hex；Android 至少 1
  final List<String> teamIds;      // iOS Team ID；iOS 至少 1
  final List<BaselineSource> sources;
  final String? notes;
}

class BaselineSource {
  final String type;        // google-play|app-store|official-site|public-fingerprint|other
  final String url;
  final DateTime retrievedAt;
  final String? method;
}

class OfficialBaselineMatch {
  final BaselineStatus status;
  final String dbVersion;
  final String? entryId;
  final String packageId;
  final List<String> expectedFingerprintPrefixes; // 前 16 hex
  final List<String> actualFingerprintPrefixes;
  final List<String> noteCodes;
}
```

### 3.6 结果与发现项

```dart
class SecurityAnalysisResult {
  // 既有字段不变
  final CryptoTheftAssessment? cryptoTheft;
  final ArtifactInventory? artifacts;
  final LoadGraph? loadGraph;
  final SealCheck? seal;
  final OfficialBaselineMatch? baseline;
}

class SecurityFinding {
  // 既有字段不变
  /// R9 修复：稳定 code 的盲区标记；Android/iOS 都填。
  /// 允许值见 §5.4；默认 const []。
  final List<String> blindSpots;
}
```

**拷贝完整性**：`SecurityAnalysisResult.withLimitation` 必须原样拷贝 `cryptoTheft/artifacts/loadGraph/seal/baseline`；`SecurityFinding.withDedupedEvidence` 必须拷贝 `blindSpots` 与既有 `*Code` 字段。Phase B 加专项单测。

---

## 4. 规则 ID 冻结（16 条；2 条 deferred）

| # | 规则 ID | 平台 | 阶段 | 判级上限 | 启用 |
|---|---|---|---|---|---|
| 1 | `ANDROID-THEFT-CHAIN` | Android | B/C | P1（含事实级） | MVP |
| 2 | `ANDROID-CLIPBOARD-ADDRESS-SWAP` | Android | B/C | P2 | MVP |
| 3 | `ANDROID-MNEMONIC-EXFIL` | Android | C | P2 | MVP |
| 4 | `ANDROID-PAYLOAD-DROPPED` | Android | B/C | P1 | MVP |
| 5 | `ANDROID-LOAD-GRAPH-DANGLING` | Android | B | P2 | MVP |
| 6 | `ANDROID-APK-SEAL-MISMATCH` | Android | D | P1（confirmed） | D |
| 7 | `ANDROID-ACCESSIBILITY-ABUSE` | Android | C | P2 | MVP |
| 8 | `ANDROID-OFFICIAL-BASELINE-MISMATCH` | Android | E | P1（confirmed） | E |
| 9 | `ANDROID-IOC-FAMILY-MATCH` | Android | —— | —— | **deferred（D1）** |
| 10 | `IOS-THEFT-CHAIN` | iOS | B/C | P1（含事实级） | MVP |
| 11 | `IOS-CLIPBOARD-ADDRESS-SWAP` | iOS | B/C | P2 | MVP |
| 12 | `IOS-SEAL-MISMATCH` | iOS | D | P1（confirmed） | D |
| 13 | `IOS-INJECTED-DYLIB-LOADED` | iOS | B/C | P2 | MVP |
| 14 | `IOS-DANGLING-LOAD` | iOS | B | P2 | MVP |
| 15 | `IOS-OFFICIAL-BASELINE-MISMATCH` | iOS | E | P1（confirmed） | E |
| 16 | `IOS-IOC-FAMILY-MATCH` | iOS | —— | —— | **deferred（D1）** |

**MVP 启用 10 条**：1–5、7、10、11、13、14。  
**D/E 完成后启用 14 条**；2 条 IoC 保留 ID、接口与模型，不产出 finding。

**判级不变量**：
- 无 `confirmed` 事实时，`ANDROID/IOS-THEFT-CHAIN` 最高 P2；
- `P1` 只允许来自 `*SEAL-MISMATCH`、`*OFFICIAL-BASELINE-MISMATCH`、`*THEFT-CHAIN` 含上述事实、`PAYLOAD-DROPPED`（injection+payload+wallet）；
- `unknown` 只允许在必需覆盖维度 `partial/notCovered` 时出现，且必须同时有 `CoverageEntry`；
- 2 条 IoC 规则永不产出 finding（本版本）。

---

## 5. 证据来源 / 覆盖 / 盲区

### 5.1 `SecurityEvidenceSource` 新增（枚举增量）

在既有 13 项后追加 5 项：
`artifactEntry`、`loadGraph`、`sealDigest`、`iocDatabase`、`officialBaseline`。

- `artifactEntry`：路径/类型/来源，如 `Payload/X.app/secret.dylib (bundleRoot)`；
- `loadGraph`：加载边，如 `Lcom/foo/Loader;.run()V @0x12 → payload.so`；
- `sealDigest`：摘要比对，如 `CodeResources: Payload/X.app/X (sha256 mismatch)`；
- `iocDatabase`：**deferred**，v8 不产出；
- `officialBaseline`：官方基线匹配/不匹配，位置写包名与基线条目 id。

`label` switch 必须补分支（编译器强制）；JSON 用 `.name`。

### 5.2 `SecurityFinding.blindSpots` 稳定 code

允许值（Phase A 冻结，Phase B 可加但需升契约版本）：

| code | 含义 |
|---|---|
| `dexPartial` | DEX 因预算只读了一部分 |
| `nativePartial` | 原生库因预算/数量只扫了一部分 |
| `nativePacked` | 原生库疑似加密/加壳 |
| `iosStringsPartial` | iOS 字符串扫描被预算截断 |
| `artifactsPartial` | 制品清单被预算/数量截断 |
| `sealPartial` | 密封校验只覆盖部分条目 |
| `baselineUnavailable` | 基线库不可用/无匹配条目 |
| `payloadUnavailable` | 载荷读不出（加密/嵌套超限） |

- Android 现有 `messageArgs['blindSpots']`（`dexPartial/nativePartial/nativePacked`）保留兼容 1 个大版本；新代码统一用 `SecurityFinding.blindSpots`。
- iOS 必须填（R9）；无盲区时 `const []`，不是 `null`。

### 5.3 新增覆盖维度（`CoverageEntry.id`）

| id | covered | limit |
|---|---|---|
| `android.artifacts` | `inventoriedEntries` | `totalEntries` |
| `android.loadGraph` | 已解析边数 | 检测到的加载点总数 |
| `android.payloadProbe` | 已探测条目数 | 需探测条目数 |
| `android.seal` | `entriesChecked` | `entriesTotal` |
| `android.dex.unicodeStrings` | 已扫字节/条数 | 总字节/条数 |
| `ios.artifacts` | `inventoriedEntries` | `totalEntries` |
| `ios.loadGraph` | 已解析边数 | 加载点总数 |
| `ios.payloadProbe` | 已探测条目数 | 需探测条目数 |
| `ios.seal` | `entriesChecked` | `entriesTotal` |
| `ios.unicodeStrings` | 已扫字节 | 二进制总字节 |
| `crypto.theft.chain` | 已评估技术点数 | 适用技术点数 |

口径：分子分母来自同一次遍历的同一计数；分母不可得时 `limit=null` + `notCovered`，不编造。

### 5.4 错误码 / 说明 code（进 `AnalysisNote` / `noteCodes`）

**Phase B 已实现并冻结以下 code**：`inventory.entries_truncated`、`payload.entries_truncated`、`payload.bytes_truncated`、`payload.head_unavailable`、`payload.magicMismatch`、`payload.nestedArchive`、`payload.encrypted`、`payload.executableInAssets`、`loadgraph.parse_failed`、`seal.digest_unavailable`、`seal.entry_limit`、`baseline.db_load_failed`、`baseline.integrity_mismatch`、`baseline.no_entry`、`baseline.fingerprint_unavailable`。

> 原稿的 `probe.head_unreadable` 在 Phase B 统一为 `payload.head_unavailable`（两端一致）；后续若改名需按 §11 升契约版本。

每条附 `args`（计数/路径/前缀），**不拼整句**。

---

## 6. JSON Schema v8（冻结）

### 6.1 放置位置

**当前 JSON 没有 `security` 顶层对象**（只有 `securitySummary` / `findings` / `coverage`）。v8 新增**顶层 `security` 对象**，避免与 `securitySummary` 混淆：

```json
{
  "reportSchemaVersion": 8,
  "securitySummary": { "…既有字段不变…": null },
  "security": {
    "cryptoTheft": { /* … */ },
    "artifacts": { /* … */ },
    "loadGraph": { /* … */ },
    "seal": { /* … */ },
    "baseline": { /* … */ }
  },
  "findings": [
    { "…既有字段…": null, "blindSpots": [] }
  ],
  "coverage": { "…既有字段…": null }
}
```

规则：
- 未做安全分析 → `security: null`；做了但某块未执行 → 该块 `null`（不输出空对象）。
- `security` 存在时，五个键**必须全部出现**（值可为 null），便于消费者稳定解析。
- 既有键名/类型/含义**一律不变**；v7 读取器忽略新键即可。
- `securityOnly: true` 时必须包含 `security` 与 `findings[].blindSpots`。

### 6.2 字段契约（与 schema 文件一一对应）

- `security.cryptoTheft`：`id`、`level`、`primaryTechnique`（null 允许）、`chain`（恰好 5 项，顺序 `capability→source→injection→payload→family`；每项含 `ruleIds[]` 规则映射）、`missing[]`、`confidence`、`severity`、`score`（0–100/null）、`scoringVersion`、`baselineEntryId`（null 允许）。
- `security.artifacts`：`entries[]`、`totalEntries`、`inventoriedEntries`、`entriesComplete`、`skippedCodes[]`。
- `security.loadGraph`：`nodes[]`、`edges[]`、`danglingEdgeIds[]`、`complete`。
- `security.seal`：`scheme`、`state`、`entriesChecked`、`entriesTotal`、`checks[]`、`signatureVerified`（**const false**）、`noteCodes[]`。
- `security.baseline`：`status`、`dbVersion`、`entryId`（null 允许）、`packageId`、`expectedFingerprintPrefixes[]`、`actualFingerprintPrefixes[]`、`noteCodes[]`。
- `findings[].blindSpots`：`string[]`（稳定 code，见 §5.2）。
- 不在 v8 输出 `security.iocMatches`（deferred）。

### 6.3 枚举字符串（必须在 Dart 用 `.name`）

| 枚举 | 值 |
|---|---|
| `CryptoTheftLevel` | `none` `capabilityOnly` `suspicious` `strongEvidence` `knownFamily` `unknown` |
| `TheftTechnique` | `addressSwap` `clipboardHijack` `mnemonicPhish` `keyExfiltration` `approvalPhish` `unknown` |
| `ChainStage` | `capability` `source` `injection` `payload` `family` |
| `TechniqueStrength` | `stringOnly` `codeReference` `callSite` `artifact` `baseline` `knownFamily` |
| `SecurityConfidence` | `confirmed` `suspected` `independentCapability` `unknown` |
| `SecuritySeverity` | `p0` `p1` `p2` `p3` `info` `unknown` |
| `ArtifactKind` | 见 §3.1 |
| `ArtifactOrigin` | 见 §3.1 |
| `LoadNodeKind` | `dex` `elf` `machO` `dylib` `framework` `script` `missing` `unknown` |
| `LoadEdgeKind` | 见 §3.2 |
| `SealState` | `verified` `mismatch` `entryMissing` `unsealed` `notChecked` `unknown` |
| `BaselineStatus` | `match` `mismatch` `noBaseline` `unavailable` |
| `SecurityEvidenceSource` | 既有 13 项 + `artifactEntry` `loadGraph` `sealDigest` `iocDatabase` `officialBaseline` |

### 6.4 语义约束（Schema 表达不了的，用测试守）

1. `chain` 长度 5 且阶段顺序固定；`supported=false` 的段数必须等于 `missing` 中对应 stage 的条目数。
2. `unknown` 级 ⇒ 至少一个必需覆盖维度为 `partial/notCovered`。
3. `seal.state=notChecked` 时 `checks=[]`、`entriesChecked=0`；不得为 `verified`。
4. `baseline.status=mismatch` ⇒ `severity=p1` 且 `confidence=confirmed`；`baseline.status=unavailable/noBaseline` 时不得出 `*OFFICIAL-BASELINE-MISMATCH`。
5. `signatureVerified` 恒 `false`（v8）。
6. `score != null` ⇒ `0 <= score <= 100`；`score` 不参与 severity 判定。
7. `blindSpots` 只允许 §5.2 的 code。
8. 报告渲染文本不得出现 `malware` / `木马` / `恶意软件` 定性（P1 文案用"与官方基线不一致"）。
9. 不得出现任何百分比"检出率/准确率"。

---

## 7. Markdown / UI 契约

### 7.1 Markdown（`## 盗 U 风险`）

固定子节（JSON 有的块 Markdown 必须有）：

```
## 盗 U 风险
### 结论
- 等级 / 置信度 / 评分（若有）/ 一句话定性
### 能力
### 来源
### 注入
### 载荷
### 官方基线
### 缺失环节
### 覆盖与局限
### 下一步
```

- 每节必须能对应 JSON 字段：能力/来源/注入/载荷 → `chain[].stage`；官方基线 → `baseline`；缺失环节 → `missing`；覆盖 → `coverage`。
- `securityOnly` 导出必须包含以上全部。
- 断言：JSON 新增键集合 ⊆ Markdown 小节映射集合（golden 测试）。

### 7.2 UI（安全 Tab）

固定 5 行（与 chain 一致）+ 顶部状态 + 底部动作：

| 行 | 数据源 | 缺省文案 |
|---|---|---|
| 能力 | `chain.capability` | `本次未发现钱包/密钥材料证据`（灰） |
| 来源 | `chain.source` | `未观察到地址来源` |
| 注入 | `chain.injection` | `未观察到注入痕迹` |
| 载荷 | `chain.payload` | `未覆盖（预算/加固）`（UNKNOWN，不允许空白） |
| 官方基线 | `baseline.status` | `未命中官方基线` / `基线不可用` |

- 状态徽标：PASS/HIT/UNKNOWN + `severity` + `confidence`；
- 禁止"木马/恶意"；禁止百分比可信度；
- 证据可展开到路径/方法/偏移/原文样本；
- "下一步"固定 3 条：导出地址清单、核对签名/密封、与官方渠道包比对。

### 7.3 i18n

新增 code 前缀：
`security.crypto_risk.title/state_*/stage_*/missing_*/baseline_*/next_*`、`security.crypto_risk.technique_*`。

- 6 语言；zh/en 必填，ja/ko 回退英文（现有策略）。
- 所有新增 code 必须进"未注册 code 守卫测试"。
- 禁止在 UI 拼英文整句（规则：引擎给 code + args，呈现层本地化）。

---

## 8. 官方基线库契约（D2）

### 8.1 文件与加载

- 路径：`assets/baseline/official_baseline_v1.json`（Phase E 加入 `pubspec.yaml` 的 assets）。
- 应用层 `OfficialBaselineStore` 读取、校验、缓存；**parser 包不读 assets**。
- 文件不存在/校验失败 → `baseline.status=unavailable` + `noteCodes=[baseline.db_load_failed]`；**不得**静默当作"无基线"。

### 8.2 格式（详见 `official-baseline-v1.schema.json`）

```json
{
  "schemaVersion": 1,
  "dbVersion": "2026.11.0",
  "generatedAt": "2026-11-04T00:00:00Z",
  "reviewedBy": ["security", "architect"],
  "integritySha256": "<可选：内容完整性哈希>",
  "entries": [
    {
      "id": "android.imtoken",
      "platform": "android",
      "packageId": "im.token.app",
      "displayName": "imToken",
      "certSha256": ["<64 hex>"],
      "sources": [
        {"type": "google-play", "url": "https://play.google.com/store/apps/details?id=im.token.app", "retrievedAt": "2026-11-04T00:00:00Z"}
      ],
      "status": "active"
    }
  ]
}
```

### 8.3 指纹规范化

- **Android `certSha256`**：apksigner 的 `certificate SHA-256 digest` 去掉冒号/空格、转小写、64 hex；一个包可多张（Play App Signing 轮换）。
- **iOS `teamIds`**：`codesign -d` 的 `TeamIdentifier=`；10 位大写字母/数字；一个包可多个（历史/重签）。
- 不存证书本体、不存官方包；只存指纹与来源。

### 8.4 匹配算法（冻结）

```
entry = active entries.where(platform==p && packageId==id)
if entry is empty: status = noBaseline
else if entry.certSha256/teamIds is empty: status = unavailable
else:
  actual = 签名分析得到的证书/Team 指纹集合
  if actual is empty: status = unavailable  // 工具不可用/读不到
  else if actual ∩ entry.fingerprints != empty: status = match
  else: status = mismatch  // P1
```

- 多 entry 命中同一 packageId：取并集；若条目冲突（同一包不同官方集合）→ `unavailable` + `baseline.db_conflict`（Phase E 加）。
- `mismatch` 只在**拿到实际指纹**且**基线有指纹**时成立；否则 `unavailable`，不得 P1。
- `match` 用于降低能力链误报：官方包不因"钱包+剪贴板+地址"单独 P2（仍可 P3 能力线索）。

### 8.5 数据来源与复核（D2 执行）

1. 维护人从**官方渠道**获取安装包（Google Play / App Store / 官方站），或使用官方公开的证书/Team 指纹；
2. 计算指纹（apksigner / codesign），记录 `sources`（type/url/retrievedAt/method）；
3. 双人复核（security + architect/lead），签字进 `reviewedBy`；
4. 提交 JSON（不提交安装包），升 `dbVersion`；
5. 新增/移除/变更在 CHANGELOG 记录；保留 retired 条目（不删）以便历史包判断；
6. 官方换证书时**新增**指纹，不删旧指纹（除非确认废弃且记录原因）；
7. 更新失败/损坏 → `unavailable`，不影响 L3 结论。

---

## 9. Golden 设计（Phase B/C 落成测试）

### 9.1 用例矩阵（12 例）

| # | 夹具 | 期望 `cryptoTheft.level` | 期望事实 | 关键断言 |
|---|---|---|---|---|
| G01 | 官方包（基线 match）+ 钱包能力 | `capabilityOnly`/`suspicious` | baseline=`match` | 不出 P1；官方包不被判 P2 能力链 |
| G02 | 同包改证书/Team（基线 mismatch） | `strongEvidence` | baseline=`mismatch` | P1 confirmed；`*OFFICIAL-BASELINE-MISMATCH` |
| G03 | iOS `.app` 根目录 dylib + `LC_LOAD_DYLIB` | `strongEvidence` | loadGraph dangling/根 dylib | `IOS-INJECTED-DYLIB-LOADED` P2；文件事实 |
| G04 | 加壳/加密（字符串密度低） | `unknown` | 覆盖 partial/notCovered | 不得 PASS；`missing.shellPacked` |
| G05 | APK v1 摘要篡改 1 字节 | `strongEvidence` | seal=`mismatch` | P1；`ANDROID-APK-SEAL-MISMATCH` |
| G06 | 未注入 digest | `capabilityOnly` 或 `unknown` | seal=`notChecked` | 不得 `verified`；覆盖 notCovered |
| G07 | 悬空加载边（`loadLibrary("x")` 包内无 x） | `suspicious` | loadGraph dangling | `*LOAD-GRAPH-DANGLING` P2；missing.payload |
| G08 | 钱包 + 剪贴板写 + 地址（无来源） | `suspicious` | source=false | P2；`missing.noSource` |
| G09 | 中文假客服 + 助记词输入 + 网络 | `suspicious` | Unicode 字符串命中 | `*MNEMONIC-EXFIL` P2；乱码/漏扫记 partial |
| G10 | 无基线条目但包名像官方 | `capabilityOnly`/`suspicious` | baseline=`noBaseline` | 不做冒充 P1；文案"未收录" |
| G11 | 预算截断（清单/密封超限） | 取决于证据 | coverage `partial` | `entriesChecked<entriesTotal`；不得 `verified` |
| G12 | 干净普通 App | `none` | 无 crypto 信号 | 不产出盗 U finding；无 P1/P2 |

### 9.2 不变量（Phase B/C 测试清单）

1. `chain.length==5`，stage 顺序固定；`supported=false` 与 `missing` 一一对应。
2. `unknown` ⇒ 至少一个 `CoverageEntry` 为 `partial/notCovered`。
3. `seal.notChecked` ⇒ `checks=[]` 且绝不为 `verified`。
4. `baseline.mismatch` ⇒ P1 + confirmed；`baseline.unavailable/noBaseline` ⇒ 无基线 P1 规则。
5. `signatureVerified == false`（v8）。
6. `withLimitation` 保留 5 个新字段；`withDedupedEvidence` 保留 `blindSpots`/code 字段。
7. JSON 新增键集合 ⊆ Markdown 小节映射集合；`securityOnly` 含全部。
8. 文案不含 `malware`/`木马`/`恶意软件`；不含任何百分比检出率。
9. `findings[].blindSpots` 在 Android/iOS 都存在（可为空）。
10. `reportSchemaVersion==8`；v7 既有键名/类型不变（diff 只允许新增）。

### 9.3 示例文件（本阶段已产出，Phase B 直接当 golden 底稿）

- `docs/contracts/examples/security-v8.baseline-mismatch.json`
- `docs/contracts/examples/security-v8.unknown-packed.json`
- `docs/contracts/examples/official-baseline-v1.example.json`

---

## 10. Phase A 完成定义（DoD）

- 本文件评审通过（architect + security + lead）；
- Schema 校验：三份示例 + 两个 schema 文件均通过 Draft 2020-12 校验；
- 字段/枚举/规则 ID 无 TBD；
- 设计文档 v1.1 的 JSON 路径改为顶层 `security`（与契约一致）；
- 记录"Phase B 可开工"的结论与剩余输入（官方基线首批清单/指纹）。

---

## 11. 冻结后的变更规则

- 字段增删/改名/枚举值变化 → 升 `reportSchemaVersion`（8→9）并更新本文件版本号；
- 规则 ID 变化 → 同步 `rulesVersion` 与 golden；
- 基线格式变化 → 升 `schemaVersion`（1→2），旧库仍可读或明确拒绝；
- 任何变更必须通知 `apk_parser` / `ipa_parser` / 应用层 / 报告 / QA 的消费者。

---

## 12. 剩余待确认（不阻塞 Phase B 编码，但阻塞 E）

1. 首批 20–30 个钱包/交易所清单（Android 包名 + iOS Bundle ID/Team）。
2. 官方包/指纹的获取人与复核人（建议 security + architect 双人）。
3. 基线库更新频率（建议随版本发布，季度至少一次）。
4. 平台优先级（建议双端 MVP；若只能先做一端，iOS 的注入/基线证据更强）。
5. MVP 是否只做 A+B+C（不含 D/E 密封/基线）——**当前契约默认是**；若要 MVP 含基线，需把 E 提前并补数据。

---

## 13. 批准记录

| 角色 | 结论 | 日期 |
|---|---|---|
| Lead（交付） | 契约冻结，Phase A 通过 | 2026-11-04 |
| 安全（security） | 待签（阈值/措辞/合规已并入） | —— |
| 架构（architect） | 待签（字段/依赖/性能已并入） | —— |
| 产品 | D1–D3 已确认 | 2026-11-04 |

---

## 13a. Phase B 实现边界（2026-11-04，已实现后回填）

| 边界 | 实现事实 | 后续 |
|---|---|---|
| Android 加载链强度 | `System.loadLibrary`/`System.load`/`DexClassLoader` 的**调用点**与路径字面量按**同现**配对；`location` 明写 `loader call + literal co-occurrence` | Phase C 可加 `const-string`/寄存器参数解析；本阶段不承诺调用点级参数关联 |
| `PathClassLoader` | 契约无对应 `LoadEdgeKind`，实现映射成 `unknown` 保留事实 | Phase C 若需要精确类型，回契约加枚举 |
| `Runtime.exec`/`ProcessBuilder` | 不产出加载边（它们不是制品加载） | 若要检测命令执行，走既有恶意指标规则 |
| iOS weak/reexport | `MachOImage.linkedLibraries` 已合并 weak/reexport/upward，`machoWeakLinked` 暂不可达 | Phase C 若需区分，给模型加「每条 load command 类型」 |
| `payload.nestedArchive` / `executableInAssets` | 只在 `assets/` 下产出；`Frameworks/`、`res/raw` 未覆盖 | Phase C 决定是否扩（两端同改） |
| assets 里的 APK | 不标 `executableInAssets`，靠 `nestedArchive` 表达 | 同上 |
| 主可执行文件识别 | 缺 `_CodeSignature/` 时记 `unknown/unknown`，不硬判 | Phase C 可结合 Mach-O magic 再判 |

---

## 14. 契约评审记录（冲突解决）

| 冲突点 | 底稿/初稿 | 冻结结论 | 理由 |
|---|---|---|---|
| 规则数 | 架构底稿 14 条（Android 8 / iOS 6） | **16 条**（+2 条 `*OFFICIAL-BASELINE-MISMATCH`） | D2 官方基线是唯一 L4 路径，必须单列规则；IoC 2 条保留但 deferred |
| 证据来源数 | 架构底稿 4 项 | **5 项**（+`officialBaseline`） | 基线匹配需要独立来源，不能借 `sealDigest`/`artifactEntry` |
| JSON 路径 | 初稿 `securitySummary.cryptoTheft` + `security.*`（当时无 `security` 对象） | **新增顶层 `security` 对象**：`security.cryptoTheft/artifacts/loadGraph/seal/baseline`；`securitySummary` 不变 | 避免与 summary 混淆；纯增量，v7 消费者忽略新键 |
| 检出率门槛 | 设计初稿有 P2+ 精确率/召回率表 | **删除作为当前验收** | D1 无语料；阈值保留在"将来有语料"附录，不作为发布门禁 |
| 家族 IoC | 设计初稿含 `family` / `IOC-FAMILY-MATCH` | **deferred**：ID/接口保留，v8 不产出 | D1 无语料，无法建立/验证家族库 |
| `TechniqueStrength` | 初稿无 `baseline` | **增加 `baseline`** | 基线命中与"已知家族"是不同强度证据，不能混用 `knownFamily` |
| R7 证据来源错标 | Android native 地址被标 `dexString` | **修复**：native 地址证据必须用 `nativeString` / `artifactEntry` | 复核会按错误来源查找（设计文档 §2.5） |
| R8 CodeResources | 只解析结构 | **C12 增加哈希校验**；`signatureVerified` 恒 false | 不能把"结构解析"说成"密封验证" |
| R9 iOS 盲区 | iOS finding 无 `blindSpots` | **`SecurityFinding.blindSpots` 统一字段**，双端必填（可为空） | 预算截断不能被读成"未发现" |

---

## 15. Phase A 校验记录（本机实跑）

```bash
cd /Users/wangbaye/Projects/AppInfoTool
python3 - <<'PY'
import json
from pathlib import Path
from jsonschema import Draft202012Validator

b = Path('docs/contracts')
s = json.loads((b / 'crypto-theft-security-v8.schema.json').read_text(encoding='utf-8'))
bs = json.loads((b / 'official-baseline-v1.schema.json').read_text(encoding='utf-8'))
Draft202012Validator.check_schema(s)
Draft202012Validator.check_schema(bs)
for f in ['examples/security-v8.baseline-mismatch.json',
          'examples/security-v8.unknown-packed.json']:
    assert not list(Draft202012Validator(s).iter_errors(
        json.loads((b / f).read_text(encoding='utf-8'))))
assert not list(Draft202012Validator(bs).iter_errors(
    json.loads((b / 'examples/official-baseline-v1.example.json').read_text(encoding='utf-8'))))
print('contract schemas + examples: OK')
PY
```

实测结果（2026-11-04）：

- 3 份 JSON 语法合法；
- 2 个 Schema 通过 Draft 2020-12 `check_schema`；
- 2 份 `security` 示例对 `crypto-theft-security-v8.schema.json` **0 错误**；
- 1 份基线示例对 `official-baseline-v1.schema.json` **0 错误**；
- `git status` 仅新增 `docs/contracts/` 与两份设计文档，**无生产代码改动**。

> 该脚本是 Phase A 的一次性验收命令，不进入生产；Phase B 会把等价断言落成 Dart 测试（不新增 `jsonschema` 依赖）。
