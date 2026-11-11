# AppInfoTool 安全检测项目完成度与可信度审计报告

> **审计对象**：AppInfoTool **2.9.0 正式版**（commit `4dff1c8`，tag `v2.9.0`，2026-11-06 发布）
> **审计日期**：2026-11-09
> **审计性质**：**只读审计**。除本报告与一个随即删除的临时探针外，未修改任何生产代码、测试、配置或语言包。
> **范围**：两个安全引擎（`packages/apk_parser`、`packages/ipa_parser`）+ 平台中立模型（`analysis_model`）+ 呈现层（`lib/utils/analysis_report.dart` 等）+ 语料/守卫/发布链路。不含安装、界面版式、图标解析等非安全板块。
> **方法**：静态取证（脚本比对引擎产出 code 与呈现层 switch / i18n 键）+ 运行时探针（6 语言实测回退）+ 实跑完整质量门禁 + 匿名 GitHub API 核对 CI/Release + 外部工具（`aapt2` / `codesign`）交叉验证 + 逐份复核设计/计划/评审文档。

---

## 0. 结论摘要

**一句话**：安全检测的**设计范围基本做完了，工程验证也是全绿的**；但「门禁绿」不等于「结论可信」——本次实测发现 **4 个会直接误导用户的呈现/口径缺陷**，其中最重要的是：Android DEX Unicode 覆盖维度在界面上显示机器 id、四条覆盖说明在中文界面直接显示英文，以及 `ANDROID-RULE-F` 在 DEX 只扫了一部分时仍用 `confirmed` 说「未发现上传特征」。

### 0.1 三个分数（主观加权，仅用于排序优先级）

| 视角 | 分数 | 主要依据 |
|---|---:|---|
| **完成度** | **90 / 100** | 设计路线图 Phase A–D 全部落地，E 只差数据；§8.6 两个平台的 Unicode 盲区都补上；Split/XAPK 已从 base-only 扩展到分包 DEX/资源/.so/密封；C-4 按既定口径实现。扣分在 iOS 缺调用点层、运行时/网络证据缺失、家族 IoC 延期、官方基线只有 2 条 Android。 |
| **可信度** | **79 / 100** | 证据分级、覆盖诚实性守卫、外部工具独立核对、误报基线都成立；扣分在否定结论过强、5 个 code 未本地化（含一条关键的「运行时 DEX 未覆盖」警告）、真实样本 E2E 在 CI 结构性跳过、加固包沉默易被读成「干净」。 |
| **验证与交付** | **88 / 100** | 2,455 条测试实跑全绿、CI 三平台发布 + 5 个产物、DMG 已挂载实测；扣分在语料基线不参与 CI、性能/ΔRSS 无回归基线、README 测试数字过期、fork 上分发渠道 job 跳过。 |
| **综合（参考）** | **85 / 100** | 完成度 0.4 + 可信度 0.4 + 验证交付 0.2 |

> 分数是**审计员按权重打的主观分**，不是质量认证；与 `docs/audit/2026-11-04-module-completeness-audit.md`（2.8.7，全项目口径：功能 94 / 工程 78 / 综合 90）**口径不同，不能直接比较**。本次只审安全检测子系统，且把「结论可信度」单独计权。

### 0.2 与上次审计（2.8.7）相比

- **已闭环**：批量重命名、iOS 分发类型、APKS `toc.pb`、安装失败码映射、权限目录补齐、分包审计纳入 split DEX/资源/.so/密封、关联默认值不再覆盖用户选择 —— 都在 `CHANGELOG.md` 2.9.0 或代码中找到实现证据。
- **仍未闭环**：真实样本 E2E 在 CI 跳过且不阻塞发布（`create-release.needs` 只含三个 build job）；README 测试数字仍写 1,780 + 667，实测 1,786 + 669；诊断本地化仍只迁移 14 条（`analysis_diagnostic_text.dart` 自述 43 条未迁）；13 个 APK 夹具全 0 DEX 的组合仍无门禁。
- **本次新发现**：下面 §3.2 的 8 条缺陷，其中 4 条是**运行时实测**出来的，不是静态推断。

---

## 1. 审计范围、方法与可复核证据

### 1.1 实跑门禁（本机，2026-11-09，HEAD `4dff1c8`，工作区干净）

| 步骤 | 结果 |
|---|---|
| `flutter pub get --enforce-lockfile` | 通过 |
| `dart run build_runner build --delete-conflicting-outputs` | 通过 |
| `dart format --output=none --set-exit-if-changed` | **416 files，0 changed** |
| `flutter analyze --fatal-infos --fatal-warnings` | **No issues found** |
| 根 `flutter test`（`NO_PROXY=127.0.0.1,localhost,::1`） | **1,786 通过 / 16 跳过 / 0 失败** |
| `analysis_model` / `apk_parser` / `ipa_parser` / `archive_safety` / `app_icon_extractor` | 141 / 218 / 245 / 40 / 25 通过；五个包 `dart analyze` 全绿 |
| 合计 | **2,455 条通过**（根 1,786 + 包 669） |
| 四类关键守卫定向复跑 | `security_finding_code_registration_test`、`audit_coverage_honesty_test`、`i18n_coverage_test`、`i18n_placeholder_usage_test` 共 **33 条全绿** |

### 1.2 静态取证（脚本，可复跑）

- 引擎实际产出 **23 个覆盖维度 id**（Android 13 / iOS 10）；`coverageDimensionLabel` 只注册 **22** 个；`assets/i18n/*.json` 的 `coverage.dimensions` 也是 **22** 键。
- 两个审计文件产出 **75 个稳定 note code**：34 个在 `coverageNote`、44 个在 `limitationNoteText`（36 个是只有局限说明才用的 `AnalysisNote`）、**5 个两个 switch 都没注册**。
- 引擎内 `ruleId:` 静态字面量共 **69** 个（Android 39 / iOS 30）；Android 组合规则表 **22** 条，iOS 无规则表、全部内联产出。
- 共享中文话术表 `analysis_model/unicode_phrases.dart` **29 条**（seed 6 / social 15 / transfer 8），有互不嵌套/全非 ASCII 的漂移守卫。
- 测试文件 **200 个**（根 149 + 五包 51）。

### 1.3 运行时探针（6 语言，已删除临时文件 `tool/_audit_probe_test.dart`）

对 23 个维度 id、5 个可疑 code 逐一调用 `coverageDimensionLabel` / `coverageNote` / `limitationNoteText`：

```
en / zh-CN / zh-HK / zh-TW / ja / ko 六个语言全部一致：
  dim  rawIds=[android.dex.unicodeStrings]                 ← 回退机器 id
  note android.dex.unicode_strings.{scope,truncated,untrusted,no_content} → FALLBACK（英文原文）
  note ios.unicode_strings.scope                            → localized（对照组）
  limitation android.dex.dynamic_loading                    → FALLBACK（英文原文）
```

### 1.4 外部独立核对

- `aapt2 dump badging`（build-tools 36.1.0）用于验证加固 APK 的清单解析结果：`3.8.7.0` / `178649800` / minSdk 24 / targetSdk 36 / **31 条权限逐条一致**（见 `docs/plans/2026-11-06-hardened-axml-prefix-chunks.md`）。
- 匿名 GitHub API：tag run `42188746059` **completed success**（Quality / build-linux / build-windows / build-macos / External samples / create-release 全 success；三个 `publish-*` 在 fork 上按预期 skipped）；main run `42188712154` success；Release `v2.9.0` `prerelease=false`、`draft=false`、**5 个产物**。
- Release DMG 实测：`CFBundleShortVersionString`/`CFBundleVersion` 均为 2.9.0，`codesign --verify --strict` 退出 0、无 `app-sandbox`、文件关联覆盖 apk/xapk/apkm/apks/ipa（详见 11-06 计划文档）。

---

## 2. 完成度

### 2.1 设计路线图兑现（`docs/plans/2026-11-04-crypto-theft-detection-design.md` §12）

| 阶段 | 目标 | 状态 | 证据 |
|---|---|---|---|
| A 契约 | 冻结模型 + schema v8 | ✅ 已实现 | `docs/contracts/*.schema.json`、`analysis_model` 的 `SecurityFinding`/`CoverageEntry`/`CryptoTheftAssessment` |
| B 事实层 | 清单/探测/加载链 | ✅ 已实现 | `apk_seal_check`、`payload_probe`、`android_load_graph` / `ios_load_graph`、`artifact_inventory_scanner` |
| C 判定层（MVP） | 五段链 + 规则 + UI/报告 | ✅ 已实现 | `CryptoTheftAssessor` 五段 `capability→source→injection→payload→family`，`ruleIds` 挂在 `chain[]` |
| D 密封校验 | APK v1/v2/v3 摘要、IPA CodeResources | ✅ 已实现 | `apk_seal_check.dart`、`ios_code_resources_check.dart`、`package_seal.dart` |
| E 基线库 | 官方指纹维护/匹配；家族 IoC 延期 | 🟡 **部分** | 加载/匹配/接线完成，`official_baseline_v1.json` 只有 **2 条、全 Android、iOS 0 条**；首条自述「未独立对照 Google Play 验证」；家族 IoC 按 D1 显式延期 |
| §8.6 Unicode | DEX MUTF-8 + iOS UTF-8/UTF-16；中文词只作线索 | ✅ 已实现且**超出** | Android 三条通路（DEX `string_ids`、`resources.arsc` + 文本 assets）、iOS 两条（Mach-O UTF-8/UTF-16、`.strings`/本地化）；29 条共享词表 |
| Split / XAPK | 分包 DEX/资源/原生库纳入审计 | ✅ 已实现 | `docs/plans/2026-11-05-split-apk-audit.md`，最多 50 个 split，名称加 `split:<basename>/` 前缀 |
| C-4 | 是否拆 10 张重复 finding | ✅ 按决策实现 | `docs/plans/2026-11-04-crypto-theft-c4-rule-mapping.md`：不拆，`ruleIds` 落 `chain[]` |

**§1 的 5 条验收标准**：可解释 / 可区分 / 可复核 / 可回归（2,193 → 本次实测 2,455 全绿、analyze 零问题、format 干净）/ 无语料不承诺量化 —— 逐条成立。

### 2.2 能力盘点（精确数字）

| 项 | 数量 | 备注 |
|---|---:|---|
| Android 组合规则表 | 22 | `android_security_rules.dart:305`，顺序被 `android_security_rules_test.dart:107-137` 钉住 |
| 两侧 `ruleId:` 静态字面量 | 69 | Android 39 / iOS 30；另有 `ANDROID-PERMISSION-${rule.name}`、`*-RULE-D-ESCALATED` 等动态 id |
| 覆盖维度 | 23 | Android 13 / iOS 10；**22 个有本地化名**（见 P1-1） |
| 中文话术表 | 29 | seed 6 / social 15 / transfer 8；互不嵌套守卫 |
| 五段链判级阈值 | P1×2 / P2×3 / P3×2 / unknown×1 | `crypto_theft.dart:448-519`；权重 10/20/30/25/35 = 120 |
| 官方基线 | 2 条（Android 2 / iOS 0） | `assets/baseline/official_baseline_v1.json`，dbVersion 2026.11.0 |
| 真实语料基线 | 12 个 IPA / 167 条 `ruleId:severity` | `test/fixtures/security_baseline.json`；`APPINFOTOOL_SAMPLES` 未设时整组用例跳过 |
| 测试 | 2,455 条通过 / 200 个测试文件 | 见 §1.1 |

### 2.3 明确未完成 / 部分完成

1. **iOS 缺调用点层**：`__objc_selrefs` 只能说明「选择子被引用」，拿不到「在哪个函数、哪个偏移被调用」（没有反汇编）。同一条 `suspected/P1`，Android 侧有 `code_item` 调用点，iOS 侧底牌软一档 —— `docs/notes/security-confidence-review.md:91-95` 已定性为「两平台最大可信度差距」。
2. **运行时 / 网络证据完全缺失**：所有结论都是静态的；`signatureVerified` 恒 `false`（只做内容摘要，不做密码学验签）。
3. **家族 IoC / 已知木马家族判定**（设计 Q3）按 D1 延期，接口保留。
4. **官方基线数据太薄**：2 条 Android、0 条 iOS，来源 `caller-provided` + `official-site-url`，不足以支撑「是不是官方包」的强结论。
5. **真实样本 E2E 在 CI 结构性跳过**：`external-samples` job 不在 `create-release.needs`（`build.yml:798-802`），无样本只 warning；12 个 IPA 的基线只是快照，新增 `ANDROID-*UNICODE-PHRASE` / `IOS-*UNICODE-PHRASE` 后未重生成。
6. **诊断本地化 14 / 57**：`analysis_diagnostic_text.dart` 自述只迁 14 条，43 条退回英文原文；`test/analysis_diagnostic_text_test.dart` 明确把它列为「还没做而不是做错了」。
7. **ja / ko 语言包不完整**：各缺 **149 个键**，其中 `theft` 组 47 个全缺（五段证据链卡片在日/韩界面回退英文）、`analysis_diagnostic` 14 个、`field_diagnostic` 15 个。`test/i18n_coverage_test.dart:370` 明确不断言六语言键集全等。**不应宣传「六种完整界面语言」。**
8. **性能/ΔRSS 回归基线未建立**：`CHANGELOG.md` 仍写「IPA 峰值约 526–546 MB；真实大包性能未压测」；`tool/perf_probe*` 不进门禁。

---

## 3. 可信度

### 3.1 做得对、可以信的部分（正面证据）

- **证据分级自洽**：`confirmed` / `suspected` / `independentCapability` / `unknown` 四态分开；`isMeta` 把「否定结论」与「元信息」排除在能力视图之外，不会把「没发现上传」显示成「数据外发 1 条」。
- **覆盖诚实性有专门守卫**：`test/audit_coverage_honesty_test.dart` 9 条，钉住 `android.nativeSymbols.limit` 是全包唯一库数、`selectLibraries` 跳过的库必须进 limitations、`android.dex.strings.limit` 是 DEX 总字节。
- **`SecurityFinding` code 守卫**：`test/security_finding_code_registration_test.dart` 扫 220 个文件、216 个 code，要求四个 switch 全覆盖，**缺失 0**；并有「>100 个」防假绿断言。
- **误报基线带反假绿**：`test/crypto_false_positive_baseline_test.dart` 用 18 个真实二进制夹具断言加密资产零命中，同时断言其它标记确实命中 —— 扫描器哪天读不到字节会立刻变红。
- **签名验证口径正确**：`signature_analyzer.dart` / `ios_codesign_analyzer.dart` 明确「工具不可用 ≠ 签名无效」，只认受信任工具（`apksigner` / `codesign`）的明确结论；`codesign -d` 只作描述性信息。
- **中文话术不单独判级**：四条 Unicode 通路统一 `info + isMeta + confirmed`、密度门槛（social 命中或 ≥3 条）、命中原文进证据，只折 `seedInput` 不折 `walletContext`/`keyMaterial`/`networkSink`，不推 P2。
- **外部工具独立核对**：期望值来自 `aapt2 dump badging`、`codesign`、`assetutil` 等，不取自本项目解析器；本轮发布还做了 DMG 挂载实测。
- **门禁与发布可验证**：2,455 条测试全绿、CI 三平台 success、Release 5 个产物、标签与版本号一致。

### 3.2 会误导用户的缺陷（按严重度，均为本次取证结果）

| 编号 | 严重度 | 缺陷 | 证据 |
|---|---|---|---|
| **P1-1** | 高 | `android.dex.unicodeStrings` 维度**没有本地化名**：UI 与 Markdown 显示机器 id，6 语言全部复现。 | `android_security_audit.dart:1499` 产出；`analysis_report.dart:928-955` switch 无此 case；`assets/i18n/*.json` 无 `android_dex_unicodeStrings` 键；运行时探针 `rawIds=[android.dex.unicodeStrings]` |
| **P1-2** | 高 | Android DEX Unicode 的 **4 条覆盖说明在中文界面显示英文原文**；iOS 同名 3 条已注册，属于两平台不对称漏接。 | 4 个 code 在 `android_security_audit.dart:1514-1533`；既不在 `coverageNote`（34 case）也不在 `limitationNoteText`（66 case）；运行时探针 6 语言全 `FALLBACK` |
| **P1-3** | 高 | `android.dex.dynamic_loading` —— **「运行时加载的 DEX 不在本次分析范围」这条最关键的覆盖警告**——6 语言全部英文回退。 | `android_security_audit.dart:862` 产出；两个 note switch 都无此 case；运行时探针全 `FALLBACK` |
| **P1-4** | 高 | 否定结论过强：`_matchesRuleF` 只判 `uploadClues.isEmpty`（`:1901`），**不看 DEX 预算截断**；`_buildRuleF` 只要读到 DEX 就给 `confidence: confirmed`，正文只说「current analysis scope」，不带「扫了 X/Y 字节」。加固包只扫前 8 MiB 时仍会说「未发现上传特征」。`docs/notes/report-quality-review.md:190-192` 早在 10-22 就点名，至今未闭环。 | 代码 + 评审文档 |
| **P2-1** | 中 | **守卫盲区**：`test/i18n_coverage_test.dart:113-130` 与 `test/analysis_coverage_test.dart:483-500` 各写死 16 个维度 id，实际 23 个 —— 缺的 7 个恰含 P1-1。守卫全绿却没发现新增维度漏文案。 | 三处写死清单 vs 引擎 23 个 id |
| **P2-2** | 中 | ja / ko 各缺 149 键，`theft` 组 47 个全缺 → 五段证据链卡片在日/韩界面回退英文。 | 语言包键集比对；`i18n_coverage_test.dart:370` 自述不断言六语言全等 |
| **P2-3** | 中 | 文档/代码漂移：`apk_info.dart:698` 注释仍写「仅限 base」，但 `2026-11-05-split-apk-audit.md` 已把 split DEX/资源/.so/密封纳入；`android.split_apk.base_only` 只残留在 i18n 与测试里，生产已不再产出。 | 代码注释 vs 计划文档 |
| **P2-4** | 中 | Phase E 基线数据不足以支撑「官方性」判断：2 条 Android / 0 条 iOS，来源自述未独立核验；CHANGELOG 已列为已知限制。 | `official_baseline_v1.json` |

**其余已知限制（非缺陷，但影响读法）**：加固/加壳包上字符串层集体沉默，只剩 `ANDROID-PACKER` 一条 info，「没报」极易被读成「没问题」（`security-confidence-review.md:72-75`）；`signatureVerified` 恒 false；`ANDROID-RULE-F` 的否定结论；iOS 调用点层缺失。

### 3.3 结论能信到什么程度

| 结论类型 | 可信任度 | 理由 |
|---|---|---|
| 清单/config 类硬事实（debuggable、exported、allowBackup、v1-only、原生可执行栈） | **高** | 声明即可判定，不依赖推断，`confirmed` 名副其实 |
| 密封摘要不一致 / 基线不一致 → P1 `confirmed` | **高（但只说明「不一致」）** | 内容摘要逐条可复核；不等价于密码学验签，也不证明恶意 |
| 五段链 `strongEvidence / suspicious / capabilityOnly` | **中** | 组合判级有阈值、有证据，但全部是静态线索，没有运行时数据流；`suspected` 之后没有可执行验证路径 |
| 中文话术命中、SDK 盘点、网络端点清单 | **中（线索级）** | `info + isMeta`，明确不作判决；端点有 50 条上限，资源/运行时文案不在范围 |
| 否定结论（`ANDROID-RULE-F`「未发现上传」、加固包「没报」） | **低** | 见 P1-4；「没扫到」与「没有」在界面上区分不够 |
| 「是不是官方包」「是不是已知木马家族」 | **不可据此下结论** | 基线 2 条且 iOS 为 0；家族 IoC 按 D1 延期 |
| 检出率 / 精确率 / 召回率 | **项目自己声明不承诺** | 设计 §1 验收第 5 条；无官方语料，不声称量化 |

### 3.4 一句总评

> 这套引擎的**证据纪律**（分级、覆盖率自述、外部工具核对、误报基线）在同类静态工具里属于上游；它最容易被高估的地方，是**在覆盖不完整时仍给出 `confirmed` 的否定结论**，以及**中文界面里突然冒出英文/机器 id**——后者会降低用户对整份报告的信任，前者会让人真的做出错误判断。

---

## 4. 修复优先级（建议，本次不改代码）

| 顺序 | 做什么 | 为什么先做 | 附带守卫 |
|---|---|---|---|
| 1 | 补 `android.dex.unicodeStrings` 的维度名（switch + 6 语言包），并注册 4 条 `android.dex.unicode_strings.*` 覆盖说明 | P1-1/P1-2：6 语言实测可见，改动小、收益直接 | 把三处写死维度清单从 16 改成 **从引擎产出动态读取/或补齐 23**，否则下次还会漏 |
| 2 | 注册 `android.dex.dynamic_loading` 的本地化说明 | P1-3：这是唯一明说「运行时代码不在覆盖内」的警告，不该是英文 | 加一条「所有 limitations 的 code 必须能被本地化」的守卫（类似 finding code 守卫） |
| 3 | 修 `ANDROID-RULE-F`：截断时把 `scannedBytes/totalBytes` 写进正文，`confidence` 降为 `unknown` 或 `independentCapability`，`_matchesRuleF` 读 `scan.skippedForBudget` | P1-4：会让人误判「没有上传行为」，是真实的可信度风险 | 加一条「DEX 部分扫描时不产出 confirmed 否定结论」的测试 |
| 4 | 让 `external-samples` 进 `create-release.needs`，或至少在 Release body 明示「真实样本 E2E 未跑」 | 让「CI 绿」不再被读成「端到端已验证」 | CI 配置 + 发布说明模板 |
| 5 | 补 ja / ko 的 `theft`（47）与 `analysis_diagnostic`（14）组 | P2-2：五段链是 2.9.0 的主功能，日/韩界面却是英文 | 扩 `i18n_coverage_test` 的键集断言范围 |
| 6 | 修 `apk_info.dart:698` 注释与清理 `android.split_apk.base_only` 残留 | P2-3：文档与实现矛盾会让后续维护者做出错误判断 | 文档一致性检查 |
| 7 | 拿到官方样本后扩充基线并重生成 `security_baseline.json` | P2-4 + 语料基线已过期（新增了 4 个 Unicode 元发现项） | `APPINFOTOOL_SAMPLES` + `REGEN_SECURITY_BASELINE=1` 逐条解释变化 |
| 8 | 建立 ΔRSS / 大包性能回归基线；更新 README 的 1,780+667 | 已知限制与文档漂移 | `tool/perf_probe*` 定期记录 |

---

## 5. 本次审计自身的限制（必须说明）

1. **只读**：没有修改任何生产代码；报告中 8 条缺陷是**发现**，不是**修复**。
2. **平台**：门禁只在 macOS 上实跑；Windows C++/Inno、Linux AppImage 未在本地构建或运行（本机按项目既有结论不出平台产物）。远端 CI 与 Release 产物已通过匿名 API 与 DMG 挂载实测核对，但未重新下载 Windows/Linux 产物执行。
3. **语料**：`APPINFOTOOL_SAMPLES` / `APPINFOTOOL_HARDENED_APK` 均未设置，15 条真实样本用例与可选加固样本用例跳过；12 个 IPA 的基线是 11-04 的快照，**没有在本次实跑**。
4. **动态行为**：完全没有运行任何样本的运行时/网络行为观察，本审计只评价静态分析的可信度，不评价恶意代码检出效果。
5. **性能**：没有运行 `tool/perf_probe*` 与 ΔRSS 探针，性能相关结论引用的是既有文档数字。
6. **分数性质**：三个分数是按权重打的主观分，用途是排优先级；功能类数字（23 维度、69 ruleId、2,455 测试等）才是可复核的硬事实。
7. **静态取证脚本**是按正则提取 code，可能漏掉由 helper 间接返回的 code；`security_finding_code_registration_test.dart` 自述也有同样的盲区。因此「5 个 code 未注册」是**下限**。

---

## 6. 附录：关键取证路径

| 结论 | 路径 |
|---|---|
| 23 个覆盖维度 / 漏 1 个标签 | `packages/apk_parser/lib/src/security/android_security_audit.dart:1416-1815`、`packages/ipa_parser/lib/src/security/ios_privacy_audit.dart:1998-2237`、`lib/utils/analysis_report.dart:928-955` |
| 5 个 code 未注册 | `lib/utils/analysis_report.dart:1960`（limitationNoteText 66 case）、`:2256`（coverageNote 34 case） |
| `ANDROID-RULE-F` 口径 | `packages/apk_parser/lib/src/security/android_security_rules.dart:1901`、`:2288-2335` |
| 五段链阈值 | `packages/analysis_model/lib/src/crypto_theft.dart:334`、`:448-519`、`:172` |
| 共享话术表 / 密度门槛 | `packages/analysis_model/lib/src/unicode_phrases.dart:59-108`、`packages/ipa_parser/lib/src/security/ios_unicode_phrases.dart` |
| 官方基线 / 语料基线 | `assets/baseline/official_baseline_v1.json`、`test/fixtures/security_baseline.json` |
| 签名工具口径 | `lib/utils/signature_analyzer.dart:113`、`lib/utils/ios_codesign_analyzer.dart:116`、`packages/analysis_model/lib/src/package_seal.dart:70` |
| 既有可信度/报告质量评审 | `docs/notes/security-confidence-review.md`、`docs/notes/report-quality-review.md` |
| 上次完成度审计 | `docs/audit/2026-11-04-module-completeness-audit.md` |
| 本轮加固包修复与发布实测 | `docs/plans/2026-11-06-hardened-axml-prefix-chunks.md` |
