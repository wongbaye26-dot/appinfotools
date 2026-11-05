# 盗 U 检测能力 — Phase B 事实层实现报告

> **状态**：Phase B（事实层）**已实现并通过回归**（2026-11-04）
> **依据**：`docs/plans/2026-11-04-crypto-theft-detection-design.md` v1.1 + `docs/plans/2026-11-04-crypto-theft-phase-a-contracts.md`
> **范围**：制品清单 / 载荷探测 / 加载链 / APK 条目事实（契约 C1–C9、C18）
> **未做**：Phase C 规则/评估/UI/报告；Phase D 密封；Phase E 官方基线；运行时（L5）
> **纪律**：未新增 pub 依赖；未改根 `lib/` UI/报告；未执行样本；未联网

---

## 0. 结论

Phase B 已完成：**Android 与 iOS 的事实层扫描器全部落地，共享模型已冻结，测试与静态分析全绿**。

| 验证项 | 结果 |
|---|---|
| `analysis_model` 测试 | **111 条通过**（基线 93 + 新增 18） |
| `apk_parser` 测试 | **193 条通过**（基线 144 + 新增 49） |
| `ipa_parser` 测试 | **215 条通过**（基线 145 + 新增 70） |
| `archive_safety` / `app_icon_extractor` | 40 / 25 条通过（未受影响） |
| 根项目 `flutter analyze --fatal-infos --fatal-warnings` | **No issues found** |
| 根项目 `flutter test` | **1,746 通过 / 15 跳过 / 0 失败** |
| `dart format`（全仓 CI 口径） | **364 files，0 changed** |
| 新增依赖 | **0** |

**结论**：可以进入 Phase C（证据链/规则/UI/报告），不需要再补事实层基础。

---

## 1. 交付物

### 1.1 共享模型（`analysis_model`，零依赖）

| 文件 | 行数 | 内容 |
|---|---:|---|
| `lib/src/container_facts.dart` | 71 | `ContainerEntryFact`、`normalizeArchivePath` |
| `lib/src/artifact_inventory.dart` | 269 | `ArtifactKind` / `ArtifactOrigin` / `ArtifactEntry` / `ArtifactInventory`、`PayloadKind` / `PayloadSignal` / `PayloadProbeInput` / `PayloadProbeResult` |
| `lib/src/load_graph.dart` | 136 | `LoadNodeKind` / `LoadEdgeKind` / `LoadNode` / `LoadEdge` / `LoadGraph` |
| `lib/analysis_model.dart` | +3 | 导出以上文件 |
| `lib/src/security_finding.dart` | +29 | 新增 5 个 `SecurityEvidenceSource`；新增 `SecurityFinding.blindSpots`；`withDedupedEvidence` 补拷 `isMeta`/`blindSpots` |

测试：`container_facts_test.dart`（51）、`artifact_inventory_test.dart`（93）、`load_graph_test.dart`（116）。

### 1.2 Android 事实层（`apk_parser`）

| 文件 | 行数 | 职责 |
|---|---:|---|
| `lib/src/security/artifact_inventory_scanner.dart` | 232 | 归档条目 → 制品清单（只读目录） |
| `lib/src/security/payload_probe.dart` | 336 | 有界头部 → 魔数/熵/嵌套包/伪装扩展名 |
| `lib/src/security/android_load_graph.dart` | 503 | DEX 加载调用 × 包内制品；悬空边 |
| `lib/src/apk_reader.dart` | +68 | `entryFacts()`：一次遍历暴露条目事实 + 压缩字段 |
| `lib/apk_parser.dart` | +9 | 导出三个 scanner |

测试：`artifact_inventory_scanner_test.dart`（254）、`payload_probe_test.dart`（304）、`android_load_graph_test.dart`（247）、`apk_reader_entry_facts_test.dart`（117）。
夹具：`test/fixtures/loader-api.dex`（1,224 B，d8 生成；README 记录复现命令与 sha256）。

### 1.3 iOS 事实层（`ipa_parser`）

| 文件 | 行数 | 职责 |
|---|---:|---|
| `lib/src/security/ios_artifact_inventory.dart` | 479 | IPA 条目 → 清单（根目录 dylib/Frameworks/appex/assets） |
| `lib/src/security/ios_payload_probe.dart` | 432 | 与 Android 同口径的载荷探测 |
| `lib/src/security/ios_load_graph.dart` | 525 | `LC_LOAD_DYLIB`/`LC_RPATH` × 包内条目；悬空边 |
| `lib/ipa_parser.dart` | +5 | 导出三个 scanner |

测试：`ios_artifact_inventory_test.dart`（308）、`ios_payload_probe_test.dart`（382）、`ios_load_graph_test.dart`（537）。
夹具：根目录 `test/fixtures/macho/{thin-arm64,fat-x86_64-arm64,libnative-fixture-fat}.dylib`（相对路径，无个人绝对路径）。

---

## 2. 关键实现口径（可直接指导 Phase C）

### 2.1 制品清单

- **只读路径，不读内容**：`sha256=null`、`contentScanned=false`、`skipCode='not.selected'`（不用 `null`，避免被下游读成“扫过且没问题”）。
- **只收文件**：目录不进清单；`totalEntries` = 文件条目数；排序后再截断（重打包改变 ZIP 顺序不影响结论）。
- **Android**：`classes*.dex`、`lib/<abi>/*.so`（arch 从路径取）、`assets/**`、`resources.arsc`、`AndroidManifest.xml`、`META-INF` v1 签名材料；非标准位置的 `.dex` 也收。
- **iOS**：主可执行文件（`.app` 根、无扩展名、`_CodeSignature/` 同级；缺签名目录时 `unknown/unknown`）、根目录 dylib→`bundleRoot`、`Frameworks/`→`frameworks`、`.appex`/Watch→`nestedBundle`、`Assets.car`→`assetArchive`。

### 2.2 载荷探测

- 魔数优先：DEX / ZIP(APK/JAR) / ELF / Mach-O / shebang；扩展名与魔数不符 → `payload.magicMismatch`。
- `assets/` 下的 ZIP → `payload.nestedArchive`；`assets/` 下的代码 → `payload.executableInAssets`。
- 熵：头部 ≥256 B 才计算；熵 ≥7.5 且可打印 ASCII ≤0.45 → `payload.encrypted`（阈值经两端对齐；均匀随机约 38% 可打印）。
- 预算：≤256 条 / 单条 4 KiB / 合计 1 MiB；超限 `complete=false` + `payload.entries_truncated` / `payload.bytes_truncated` / `payload.head_unavailable`。

### 2.3 加载链

- **Android**：`System.loadLibrary` / `System.load` / `DexClassLoader` / `InMemoryDexClassLoader` / `PathClassLoader`(→`unknown`)；调用点 + 同 DEX 路径字面量**同现**配对（**不是参数级关联**）；绝对路径永远悬空；多 ABI 取字典序最小。
- **iOS**：`LC_LOAD_DYLIB`（含 weak/reexport/upward 合并）、`LC_RPATH`、`@executable_path`、`@loader_path`；系统库不建节点/边；`/Library/MobileSubstrate`、`frida`、`/var/jb` → missing+dangling；包外 rpath 建 `machoRPath` 边。
- `complete=false` 四源：清单截断 / Mach-O 无镜像 / 边超限 / 主 bundle 未知（iOS）；Android 另含结构不可遍历、walk 截断/desync、字符串或字面量上限。

### 2.4 APK 条目事实

`ApkReader.entryFacts()` 一次遍历 `ArchiveFile`，填 `path/sizeBytes/isDirectory`；压缩大小/方法号优先取 `ZipFile.header`，拿不到时 `null`（目录、AES 占位、未知压缩方法都不猜）。

---

## 3. 与契约的偏差 / 已登记边界

| # | 事项 | 处理 |
|---|---|---|
| 1 | 契约 §5.4 原写 `probe.head_unreadable` | 实现统一为 **`payload.head_unavailable`**；契约已同步（§13a/§5.4）。 |
| 2 | `PathClassLoader` / `Runtime.exec` 无对应 `LoadEdgeKind` | 前者映射 `unknown`；后者不产出边（不是制品加载）。要精确类型需契约加枚举。 |
| 3 | `MachOImage.linkedLibraries` 合并 weak/reexport/upward | `LoadEdgeKind.machoWeakLinked` 当前不可达；Phase C 若需区分，模型加“每条 load command 类型”。 |
| 4 | Android 加载链是**同现**不是参数关联 | `location` 明写 `loader call + literal co-occurrence`；Phase C 判级不得把它当调用点级证据。 |
| 5 | `payload.nestedArchive` / `executableInAssets` 只在 `assets/` 下产出 | `Frameworks/`、`res/raw` 未覆盖；Phase C 决定是否扩（两端同改）。 |
| 6 | assets 里的 APK 不标 `executableInAssets` | 由 `nestedArchive` 表达，避免重复计数。 |
| 7 | iOS 主可执行文件缺 `_CodeSignature/` 时 | 记 `unknown/unknown`，不硬判 Mach-O；Phase C 可结合魔数再判。 |

---

## 4. 未做（Phase C/D/E）

| 阶段 | 内容 |
|---|---|
| Phase C | 五段证据链、`CryptoTheftAssessment`、16 条规则（10 条 MVP 启用）、覆盖率接入、UI“盗 U”块、Markdown/JSON 同源、iOS 审计后台化 |
| Phase D | APK v1/v2 摘要校验、IPA CodeResources 哈希校验、`ContentDigestFn` 注入、`SealCheck` |
| Phase E | 官方基线库 JSON/Schema、首批 20–30 钱包/交易所指纹、匹配算法接线、`baselineUnavailable` 降级 |

---

## 5. 验证证据（可复现）

```bash
cd /Users/wangbaye/Projects/AppInfoTool

# 共享模型
(cd packages/analysis_model && dart test)        # +111
(dart analyze --fatal-infos --fatal-warnings)

# Android 事实层
(cd packages/apk_parser && dart test)            # +193
(dart analyze --fatal-infos --fatal-warnings)

# iOS 事实层
(cd packages/ipa_parser && dart test)            # +215
(dart analyze --fatal-infos --fatal-warnings)

# 根项目门禁
flutter analyze --fatal-infos --fatal-warnings   # No issues found
flutter test                                     # 1,746 pass / 15 skip / 0 fail
dart format --output=none --set-exit-if-changed $(git ls-files -co --exclude-standard '*.dart')
                                                 # 364 files, 0 changed
```

环境：Flutter 3.47.7 stable，macOS arm64，commit 基线 `b7adbc5` + Phase B 工作树。

---

## 6. Phase C 开工前置

1. **契约冻结范围**：Phase C 需要新增 `CryptoTheftAssessment`/规则/报告字段；按契约 §11 升 `reportSchemaVersion` 到 8（已在 Phase A 冻结，Phase C 落地）。
2. **iOS 后台化**：Phase C 前把 `IosPrivacyAudit.audit` 从 `info_page.dart:429` 移入任务/isolate；否则新增清单/链条会卡 UI。
3. **规则阈值**：按契约 §7.3 纯函数判级；所有 `unknown` 必须伴随 `CoverageEntry`。
4. **UI/报告同源**：Markdown 小节 ⊇ JSON 新增键；`securityOnly` 包含新块。
5. **官方基线**：Phase E 前需要首批清单与真实指纹（你们已确认可提供）；Phase C 不需要。
