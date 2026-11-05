# 2026-11-05 — iOS UTF-8 / UTF-16 中文话术扫描

> **状态**：已实现，完整质量门禁通过（见 §6）
> **范围**：iOS 侧；Android 的 DEX MUTF-8 中文仍按设计 §8.6 留到下一轮
> **为什么选这一项**：C-4 的口径在 `2026-11-04-crypto-theft-c4-rule-mapping.md`
> 已有明确结论（不拆 10 张重复 finding，规则 id 挂在 `chain[].ruleIds` 上），
> 且产品已接受；没有官方样本，Phase E 基线无法推进。剩下能做且最影响检出率
> 的就是中文话术盲区。

---

## 1. 改之前的真实状态

不是「完全没有 Unicode 扫描」，而是**只扫不认**：

| 层 | 改之前 | 后果 |
|---|---|---|
| `AsciiStrings.extract` | 只认 0x20–0x7E，遇到第一个 ≥0x80 就断开 | `__TEXT,__cstring` 里的 UTF-8 中文被切碎，一个词也捞不出来 |
| `Utf16Strings.extract` | 已在 `IosPrivacyAudit` 里跑一遍，但只有**小端 + 偶对齐 + minLength 4** | 三字话术（「助记词」）、大端/奇对齐的 `__ustring` 漏掉 |
| 下游 `consume()` | 只跑 ASCII 标记表 / 端点 / 钱包标记 / 地址；开头一个 `_markerPattern.hasMatch()` 早退 | 即使捞到中文串，也一条都匹配不上，等于白扫 |
| 文案 | 6 个语言包里 3 处写「仅提取可打印 ASCII」 | 与实现漂移（代码其实已经扫 UTF-16LE），现在更不准了 |

设计依据：`docs/plans/2026-11-04-crypto-theft-detection-design.md` §2.4、§8.6。

---

## 2. 实现

### 2.1 `analysis_model`：两个平台中立的提取器

- **新增 `utf8_strings.dart` / `Utf8Strings.extract`**：逐序列严格解 UTF-8
  （拒绝超长编码、代理区、> U+10FFFF、非法后续字节），只产出**含非 ASCII**
  的串，超长串只留头尾。纯 ASCII 串由 `AsciiStrings` 负责，不重复产出。
  - `minCjkChars` 门槛：中文话术扫描传 2。随机二进制凑出两个合法 CJK 码点的
    概率极低，这是把噪声压下去的关键（实测数字见 §5）。
  - CJK 模式下从**第一个中文码点**开始收，纯 ASCII 前缀不进 List；头尾两个
    List 复用而不是每次断开都新建。
- **`utf16_strings.dart` 扩展**：`extract()` 增加 `bigEndian` 参数；
  新增 `extractAll()` 一次扫「小端/大端 × 偶/奇对齐」四种组合并去重
  （去重集合有 4096 上限，不会随输入大小膨胀）。`extractAll` 只用于
  `__ustring` 节，绝不对几十 MiB 的主二进制跑四遍。

### 2.2 `ipa_parser`：话术表与元发现项

新增 `ios_unicode_phrases.dart`：

- **29 条中文话术**，分三组：`seed`（助记词/私钥/导入钱包…）、
  `social`（解冻/资金冻结/人工客服/刷单返利/领取空投…）、
  `transfer`（收款地址/资金归集/能量租赁/无限授权…）。
  不收「验证」「授权」「转账」这种几乎每个 App 都有的通用词。
- 表本身有漂移守卫：全部非 ASCII、长度 ≥2、id/字面量不重复、
  **任意两条互不嵌套**（嵌套会让同一句原文一次命中多个 id）；
  并逐条用 UTF-8 / UTF-16 LE / UTF-16 BE 三个提取器驱动，捞出不来就红。
- `IosUnicodePhraseSignals`：记录命中原文与所在可执行文件，样本/命中数有上限；
  `unicodeStrings` 只统计 Unicode 候选串；`truncated` 记预算截断。
- `buildIosUnicodePhraseFindings` → 一条 `IOS-UNICODE-PHRASE`：
  `info` + `isMeta` + `confirmed`（「字符串确实存在」是事实，「它在骗人」不是），
  命中原文进 `SecurityEvidence`。

### 2.3 口径：中文词不单独判级

这是本轮最重要的取舍，与 §8.6「中文词只作为能力/话术线索」一致：

1. **密度门槛**：只有一两条正规钱包用语（助记词 / 收款地址）不挂卡片；
   命中任一 `social` 话术，或累计 ≥3 条不同话术才产出发现项。
2. **不碰判级**：`IosCryptoTheftChain.assess` 只把话术折成
   `CryptoTheftFacts.seedInput`（支撑 `source` 段）与 source 段证据；
   **不**折算 `walletContext` / `keyMaterial` / `networkSink`，
   因此不会出现「一句中文把等级推到 P2」。测试钉住这一条。
3. **照实列边界**：局限说明写明 Swift 小字符串常量、`.strings` / 本地化资源、
   运行时下发文案、dyld 共享缓存都不在范围内。

### 2.4 审计接入与覆盖维度

`IosPrivacyAudit.audit` 在原有 ASCII 遍历之后追加：

| 遍历 | 范围 | 门槛 | 去向 |
|---|---|---|---|
| 小端 UTF-16（原有） | 整文件偶对齐 | minLength 4 | 全套 `consume()` |
| UTF-8（新增） | 真实 Mach-O 的 `__TEXT,__cstring` 节 | minLength 2 / `minCjkChars 2` | **只**给话术收集器 |
| UTF-16 四组合（新增） | `__TEXT,__ustring` 节 | minLength 2 | 话术 + crypto 信号 |

- 节内扫描有单独 8 MiB 上限（`_Budget.maxUstringBytes`），超出记 `truncated`。
- 端点/钱包/地址标记全是 ASCII，中文串走那几个正则没有收益 —— 所以两条新
  遍历只喂话术收集器，省掉几万次无谓匹配。
- 没有 Mach-O 的合成输入（测试/降级）才退回整文件扫描；真实 IPA 不再全文件扫 Unicode。
  这会把「散落在非 `__cstring`/`__ustring` 区域的宽字符」排除在覆盖外，已写进局限。
- **`ios.unicodeStrings` 覆盖维度**：`covered`/`limit` 与 `status` 回答同一个
  问题（这些字节里扫了多少），共用 `ios.macho.strings` 的字节预算；
  命中了多少条话术是发现项的事，不拿来当覆盖率分子。
  三种 note code：`scope`（照实列边界）/ `truncated` / `no_content`。
  「没找到」时维度仍是 `covered`，不显示成「没查」。

### 2.5 呈现层与 i18n

- `AnalysisReport` 注册 `ios.unicode_phrase` / `.review` / `.limitation`
  到 `findingText` / `recommendationText` / `limitationText` 三个 switch；
  `coverageNote` 注册三种 note code；`coverageDimensionLabel` 注册新维度。
  守卫 `test/security_finding_code_registration_test.dart` 全绿。
- 6 个语言包各补 7 个键（维度名 ×1、覆盖说明 ×3、发现项文案 ×3），
  并**修正 3 处过期文案**：`ios_scan_coverage_limitation`、
  `ios_rule_f_limitation`、`ios_macho_scan_summary` 原来都写「只扫 ASCII」，
  现在改成「ASCII + UTF-8 Unicode + UTF-16（LE/BE）」并列出新边界。
  语言包仍用 `json.loads → dict → json.dumps(indent=2)` 往返，逐字节一致。
- 两处写死的覆盖维度清单（`analysis_coverage_test.dart` 的
  `allDimensionIds`、`i18n_coverage_test.dart` 的 `ids`）同步加上
  `ios.unicodeStrings`。

---

## 3. 测试

| 层 | 新增用例 |
|---|---|
| `packages/analysis_model/test/utf8_strings_test.dart` | 中文串、中英混排、坏 UTF-8 重同步、minLength、超长裁剪、limit、CJK 降噪、UTF-16LE 不误产 |
| `packages/analysis_model/test/utf16_strings_test.dart` | 大端、奇对齐、`extractAll` 四组合去重、minLength 降到 3 |
| `packages/ipa_parser/test/ios_unicode_phrases_test.dart` | 表漂移守卫、逐条驱动 UTF-8/LE/BE、样本上限、密度门槛、发现项形状与四个 code、截断说明、盗 U 链只支撑 source |
| `test/ios_unicode_phrase_scan_test.dart` | 端到端：UTF-8 `__cstring` 形态、散落小端 UTF-16、`__ustring` 大端、`__ustring` 奇对齐、纯 ASCII 不产出但覆盖仍 covered、预算截断 partial、无内容 notCovered、中英双语本地化渲染 |

`__ustring` 的端到端用例手搭了一个**最小 Mach-O 结构容器**（头 + 一个
`LC_SEGMENT_64` + 一个 `section_64`），因为仓库里的真实 clang dylib 夹具没有
这个节；它不是「真实 App 样本」，期望值只是「放进去的原文能被捞出来」。
真实 IPA 上的行为仍要靠 `APPINFOTOOL_SAMPLES` 语料基线（见 §7）。

---

## 4. 性能实测（`sun_signed.ipa`，主可执行文件 34.3 MiB，JIT 测试进程）

| 遍历 | 产出串数 | 耗时 |
|---|---|---|
| `AsciiStrings`（原有） | 76,749 | 97 ms |
| `Utf16Strings` 小端偶对齐（原有） | 729,397 | 247 ms |
| `Utf8Strings` 无 CJK 门槛 | 124,083 | 412 ms |
| **`Utf8Strings` 生产口径 `minCjkChars: 2`** | **98** | **262 ms** |

- CJK 门槛把噪声从 12.4 万条压到 98 条；下游收集器因此只处理 98 条，
  而不是 12.4 万条。生产 AOT 会比这里的 JIT 数字快得多。
- 官方探针 `tool/perf_probe_test.dart`：完整静态解析 5,641 ms、
  `securityAudit:false` 243 ms、**安全审计增量 5,398 ms**
  （加入 ASCII 码元预筛前是 5,551 ms）。新增的 UTF-8 遍历约占审计的 5%。
- **ΔRSS / 大包性能回归基线仍是待办**：这里只有单点计时，没有做内存峰值
  与不同包体的回归曲线；`tool/` 里的探针不进门禁。

---

## 5. 全量质量门禁

| 项 | 结果 |
|---|---|
| `flutter pub get --enforce-lockfile` | 通过 |
| `dart run build_runner build --delete-conflicting-outputs` | 通过 |
| `dart format --output=none --set-exit-if-changed` | **391 files，0 changed** |
| 根 `flutter analyze --fatal-infos --fatal-warnings` | No issues found |
| 根 `flutter test` | **1,765 通过 / 15 跳过 / 0 失败** |
| `analysis_model` analyze / test | No issues / **140 通过** |
| `apk_parser` analyze / test | No issues / **213 通过** |
| `app_icon_extractor` analyze / test | No issues / 25 通过 |
| `archive_safety` analyze / test | No issues / 40 通过 |
| `ipa_parser` analyze / test | No issues / **236 通过** |

> 顺带修了 `test/security_integration_test.dart` 里断言旧英文局限文案的一处
> 硬编码：文案更新后它仍钉住「只扫 ASCII 和 UTF-16LE」。断言现在只钉住
> 「走的是本地化文案而不是引擎里的旧中文原文」，不再绑死具体措辞。

---

## 6. 已知局限 / 下一轮

1. **Android DEX MUTF-8 中文已实现**（`packages/apk_parser/lib/src/security/dex_unicode_phrases.dart` + `test/dex_unicode_phrases_test.dart`）；resources/、assets/、原生库、加固壳层仍未覆盖。
2. `.strings` / 本地化资源、Swift 小字符串常量、运行时下发文案、dyld 共享
   缓存里的符号都看不到 —— 已写进发现项局限与 `ios.unicodeStrings` 覆盖说明。
3. **真实语料基线未重生成**：本轮新增一条 `info` 级元发现项，含中文话术的
   真实 IPA 在 `test/fixtures/security_baseline.json` 里会多一行
   `IOS-UNICODE-PHRASE:info`。样本目录不在本机（`APPINFOTOOL_SAMPLES` 未设，
   基线用例因此跳过）。拿到样本后须
   `APPINFOTOOL_SAMPLES=… REGEN_SECURITY_BASELINE=1 flutter test test/security_baseline_test.dart`
   并逐条解释变化，**不能**直接把旧基线覆盖过去。
4. 官方基线（Phase E）仍被「没有官方样本」卡住；重签名样本不适合当官方指纹
   （见 `2026-11-04-crypto-theft-ios-samples.md`）。
5. C-4 的「是否拆 10 张 finding」维持既有结论：不拆。若产品改口径，
   `chain[].ruleIds` 已经足够生成 finding，不需要重新推导事实。

---

## 7. 改动文件

**新增**
`packages/analysis_model/lib/src/utf8_strings.dart`、
`packages/analysis_model/test/utf8_strings_test.dart`、
`packages/ipa_parser/lib/src/security/ios_unicode_phrases.dart`、
`packages/ipa_parser/test/ios_unicode_phrases_test.dart`、
`test/ios_unicode_phrase_scan_test.dart`、
`docs/plans/2026-11-05-ios-unicode-phrase-scan.md`

**修改**
`packages/analysis_model/lib/analysis_model.dart`、
`packages/analysis_model/lib/src/utf16_strings.dart`、
`packages/analysis_model/test/utf16_strings_test.dart`、
`packages/ipa_parser/lib/ipa_parser.dart`、
`packages/ipa_parser/lib/src/security/ios_privacy_audit.dart`、
`packages/ipa_parser/lib/src/security/ios_crypto_theft_chain.dart`、
`lib/utils/analysis_report.dart`、
`assets/i18n/{en,zh-CN,zh-HK,zh-TW,ja,ko}.json`、
`test/analysis_coverage_test.dart`、`test/i18n_coverage_test.dart`、
`test/security_integration_test.dart`
