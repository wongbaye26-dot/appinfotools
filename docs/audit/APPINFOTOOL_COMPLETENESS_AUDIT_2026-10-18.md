# AppInfoTool 全项目完成度审计报告

| 项 | 值 |
|---|---|
| **审计时间** | 2026-10-18 18:28 – 19:0x（GMT+7） |
| **审计对象** | `main` @ `10c85d0f937775890121cec5f81f69914f468e2d`（短 SHA `10c85d0`，tag `v2.4.10`） |
| **版本** | `pubspec.yaml` = `2.4.10` |
| **性质** | 只读、证据驱动、可复现。**本轮未修改任何业务代码、测试、版本号、lockfile、tag 或远端。** |
| **工具链** | Flutter 3.47.7 (stable, revision abaf9c5237) / Dart 3.13.5 / macOS arm64 |
| **报告路径** | `docs/audit/APPINFOTOOL_COMPLETENESS_AUDIT_2026-10-18.md`（新建，未覆盖任何历史文档） |

---

## 一、审计摘要

**结论：这是一个工程纪律明显高于同类个人项目的代码库，但存在一个可实测复现的安全边界缺陷。**

三句话概括：

1. **架构干净、门禁全绿、发布链路可靠。** 依赖方向无环（`analysis_model` 零运行时依赖）、六道门禁本地实测全部 `EXIT=0`、1400 个用例全绿、tag ↔ HEAD ↔ Release 产物三方一致。
2. **V2.4.10 移除压缩比规则的判断是对的，但安全论证不完整。** 我复核了它的理由（`archive` 包的 deflate 对纯零只有 229:1，与真实加固包的 205:1 无法区分），结论成立；但**同时暴露了一个更根本的问题**：`ZipBudget` 只读归档中央目录的**声明值**，而实际解压没有任何字节上限。我用一个把 CD 声明改成 1024 字节的样本实测：`open` 通过、`readFile` 返回 **104,857,600 字节**、RSS 增长 **201 MiB**。
3. **国际化从 34% 提到 89%，但 ja/ko 仍缺 87 键；`analysis_diagnostic` 只有 14 个键，大多数诊断 code 仍然回退英文。**

**完成度加权得分：82.5 / 100**（见 §十一）。**其中「不可信输入安全边界」单项只有 9/15，是唯一被实测缺陷显著拉低的维度。**

---

## 二、当前基线（实测）

```text
$ date
2026-10-18 18:28:36 +07

$ git status --short
（空 —— 工作区干净）

$ git branch --show-current
main

$ git branch -vv
* main 10c85d0 [origin/main] fix(archive): 2.4.10 —— 安全解压预算误伤了被零填充的加固包

$ git rev-parse HEAD
10c85d0f937775890121cec5f81f69914f468e2d

$ git log -1 --decorate --oneline
10c85d0 (HEAD -> main, tag: v2.4.10, origin/main, origin/HEAD) fix(archive): 2.4.10 —— …

$ grep '^version:' pubspec.yaml
version: 2.4.10

$ git tag --sort=-creatordate | head -4
v2.4.10 / v2.4.9 / v2.4.8 / v2.4.7
```

| 核对项 | 结果 |
|---|---|
| 当前分支 | `main` |
| HEAD | `10c85d0f937775890121cec5f81f69914f468e2d` |
| 当前版本 | `2.4.10` |
| 最新 tag | `v2.4.10` |
| **HEAD 与 `v2.4.10` 是否一致** | **是**（`git rev-list -n1 v2.4.10` = `10c85d0f`） |
| 工作区是否干净 | **干净**（`git status --short` 无输出） |
| 未提交修改 / 未跟踪文件 | 无 |
| 本地与远端差异 | 无（`[origin/main]` 无 ahead/behind 标记） |
| Flutter / Dart | 3.47.7 / 3.13.5 |

**参考值即实际基线**：本次审计对象就是 V2.4.10 本身，无需单独记录「相对 V2.4.10 的增量」。

> 说明：`git fetch --tags` 未执行 —— 远端为 SSH（`git@github.com:wongbaye26-dot/appinfotools.git`），
> `git branch -vv` 已显示与 `origin/main` 同步，无必要触发网络操作。

---

## 三、代码与模块架构（实测）

### 3.1 规模

| 位置 | 文件 | 行数 |
|---|---:|---:|
| `lib/`（应用层） | 81 | 26,435 |
| `test/`（根测试） | 83 | 25,095 |
| `packages/analysis_model` | 11 lib / 3 test | 1,577 / 804 |
| `packages/archive_safety` | 4 lib / 1 test | 386 / 231 |
| `packages/apk_parser` | 27 lib / 4 test | **9,165 / 886** |
| `packages/ipa_parser` | 17 lib / 2 test | **6,787 / 744** |

**测试总量：1,400 个用例**（根 `flutter test` 1,195 通过 / 14 跳过；四个包 58 + 25 + 68 + 54 = 205）。

### 3.2 依赖方向（逐条读 `pubspec.yaml` 核实）

| 包 | 运行时依赖 | 判定 |
|---|---|---|
| `analysis_model` | **无**（只有 `dev_dependencies: lints / test`） | ✅ **平台中立**，符合审计假设 |
| `archive_safety` | `archive` | ✅ 只依赖 ZIP 库 |
| `apk_parser` | `analysis_model` + `archive` + `archive_safety` + `logging` + `xml` | ✅ |
| `ipa_parser` | `analysis_model` + `archive` + `archive_safety` + `xml` | ✅ |

**`apk_parser` 与 `ipa_parser` 之间没有依赖**（两者的 pubspec 均未引用对方）—— 审计任务书里「是否存在不应有的循环依赖」一项：**不存在循环**。

### 3.3 UI 是否承担二进制解析职责

抽查结论：**没有**。UI 侧只通过 `FileState.analysis`（`PackageAnalysisResult`）读取结果：

- `lib/pages/info_page.dart:602` `final result = fileState.analysis;`
- `lib/pages/info_page.dart:1386` `DetailRenderer.analysisNotes(fileState.analysis, t)`

二进制解析全部落在 `packages/apk_parser` / `packages/ipa_parser`；应用层只有编排（`lib/apkparser/parse_task.dart`、`lib/ipaparser/ipa_parse_task.dart`）。

### 3.4 重复实现

| 候选 | 结论 |
|---|---|
| Manifest / ARSC 解析 | 只有 `packages/apk_parser` 一份 |
| Plist / Mach-O | 只有 `packages/ipa_parser` 一份 |
| ZIP 预算判定 | **已下沉为唯一实现** `ZipBudget`（`zip_guard.dart:9-11` 明确记录历史上曾有两份） |
| 平台标签 / 架构徽章 | V2.4.6/V2.4.8 已抽成 `platform_tag.dart` / `arch_badge.dart` / `package_icon_metrics.dart` |
| 标题样式 | V2.4.8 已抽成 `detailTitleStyle()`，设置页预览与真实卡片共用 |

### 3.5 值得记录的架构优点

1. **`FieldValue<T>`（值 + 状态 + 来源 + 诊断）是贯穿全项目的主线** —— 界面、Markdown、JSON、版本对比四处读同一份模型，「没读到」与「文件里没有」不会混。
2. **`AnalysisNote` / `AnalysisDiagnostic` 用「稳定 code + 英文回退」**，界面按 code 查本地化模板，查不到才回退 —— 这让「报告可被程序读、界面可被翻译」两件事不冲突。
3. **`ZipBudget` 的下沉**（`zip_guard.dart` 只留路径防护）消除了历史上「两处阈值不同步」的隐患。

---

## 四、功能完成度矩阵

状态口径：**已实现且验证通过** / 已实现但测试不足 / 部分实现 / 未实现 / 未验证。

### 4.1 包解析

| 能力 | 状态 | 证据 |
|---|---|---|
| APK 容器读取 | 已实现且验证通过 | `packages/apk_parser/lib/src/apk_reader.dart:74` `open()`；`test/archive_open_test.dart` 17 用例 |
| AXML / Manifest | 已实现且验证通过 | `binary_xml.dart`；`packages/apk_parser/test/apk_parser_test.dart` 用**真实加固清单**夹具验证 `attributeStart/attributeSize` 非标准布局仍能解出 40 权限 / 22 组件 |
| 权限与 `maxSdkVersion` 条件 | 已实现且验证通过 | `models.dart:44` `ApkMeta`；`apk_parser_test.dart` 断言「未声明 maxSdkVersion 是 null，不默认成某个值」 |
| 组件（含 exported） | 已实现且验证通过 | `AndroidComponent`（`models.dart:223`）；`apk_parser_test.dart` 22 组件 |
| `resources.arsc` | 已实现且验证通过 | `arsc_parser.dart`；`test/arsc_night_mode_test.dart`、`test/container_structure_test.dart` |
| 多语言应用名 | 已实现且验证通过 | `ArscParser.getLocales()`；`test/arsc_*` |
| 图标（含自适应 / CgBI） | 已实现且验证通过 | `AdaptiveIconRenderer`；`test/cgbi_png_test.dart`、`test/ipa_icon_test.dart` |
| DEX 结构 | 已实现且验证通过 | `DexStructure`；`test/dex_structure_test.dart` 210 行 |
| 方法引用 + 调用点 | 已实现且验证通过 | 见 §五 |
| ELF 原生库与符号 | 已实现且验证通过 | `elf.dart`；`test/elf_test.dart` 575 行 |
| 分包与 OBB | 已实现且验证通过 | `ApkMeta.splitApks/obbFiles`；`test/xapk_installer_test.dart` |
| XAPK / APKM / APKS | 已实现且验证通过 | `lib/utils/xapk_installer.dart`；`test/xapk_security_audit_test.dart` |
| 签名材料与外部工具 | 已实现且验证通过 | `SignatureVerdict` 四态（`package_analysis_result.dart:29`）；`test/signature_*` |
| 加固包线索 | 已实现且验证通过 | `hardening.dart`；V2.4.10 的样本实测产出 100 个诱饵条目 |
| 异常/部分解析结果 | 已实现且验证通过 | `manifestFailure` / `arscParseFailure` 字段；`ArchiveOpenResult` 五态 |
| **ICP 备案号** | 已实现且验证通过 | `icp_filing.dart`；`packages/apk_parser/test/icp_filing_test.dart` 15 用例；实测 `抖音` → `京ICP备16016397号-49A`，`飞牛` → 空 |

### 4.2 iOS / IPA

| 能力 | 状态 | 证据 |
|---|---|---|
| IPA 容器 / bundle 枚举 | 已实现且验证通过 | `ipa_container.dart`；`test/ipa_container_test.dart` |
| XML 与二进制 Plist | 已实现且验证通过 | `test/ipa_info_plist_test.dart` |
| Bundle ID / 版本 / MinimumOS | 已实现且验证通过 | `IosPackageInfo`（`package_analysis_result.dart:157`） |
| URL Schemes | 已实现且验证通过 | `urlSchemes` / `queriesSchemes` |
| 嵌套 bundle / Extension / Framework | 已实现且验证通过 | `test/ipa_bundle_extractor_test.dart` |
| Mach-O 架构与 Load Commands | 已实现且验证通过 | `test/ipa_macho_test.dart` 316 行（真实 clang 产物夹具） |
| `PrivacyInfo.xcprivacy` | 已实现且验证通过 | `test/ios_privacy_audit_test.dart` |
| 用途说明 / Entitlements | 已实现且验证通过 | 同上 |
| Provisioning / `_CodeSignature` / CMS | 已实现且验证通过 | `IosSignatureMaterials` |
| `codesign` **实际验证** | 已实现且验证通过 | `ios_codesign_step.dart:36` `findCodesignPath` + 真实调用；工具缺失时返回「不可用」而非「无效」 |
| 文件预算与扫描截断 | 已实现且验证通过 | `_Budget.maxBytes`；`ios.executable.over_budget` 有本地化文案 |

**签名五态的区分**：`SignatureVerdict { verified, rejected, inconclusive, notChecked }`（`package_analysis_result.dart:29-49`）。「材料存在」由 `IosSignatureMaterials` 单独建模，「工具验证成功/失败/未验证」由 verdict 表达 —— **符合审计要求，静态 CMS 材料不会被转述成「签名有效」**。

---

## 五、APK / IPA 解析能力（重点核实）

### 5.1 DEX 三层取证是否真实可用

README 声明「结构 → 方法引用 → 调用点」，审计任务书要求确认**测试是否真实验证调用索引、调用方和指令偏移**。

**结论：真实。** 证据：

| 断言 | 位置 |
|---|---|
| 调用点计数 | `test/dex_method_scanner_test.dart:131` `expect(http.callSiteCount, 2)` |
| **调用方**（在哪个方法里） | `test/dex_method_scanner_test.dart:136` `reason: '证据要能回答「在哪个方法里」'` |
| **指令偏移** | `test/dex_method_scanner_test.dart:139` `any((s) => s.contains('+0x10'))` |
| 同现调用者 | `:195-196` `occurrence.callerDisplayName contains('Pipeline') / contains('run')` |
| 偏移精确值 | `test/dex_instruction_test.dart:316-332` 逐条断言 `instructionOffset` |

即：测试不是「有对应类名就算过」，而是钉住了「方法名 + 调用方 + 十六进制偏移」。

### 5.2 V2.4.7 的性能优化没有削弱证据

`invoke-*` 的操作数就是 `method_idx`，因此调用点改为**按索引查表**（`dex_method_scanner.dart` 的 `matchedByIndex`）。这不是「跳过分析」，而是「不重复做已经做过的事」——`method_ids` 那一遍仍然全量扫描，调用点那一遍只是不再重新跑字符串匹配。测试（`+0x10` 偏移断言）在优化后仍然通过。

### 5.3 覆盖缺口（真实存在）

- **DEX 字符串扫描仍是「原始字节 + 预算」**：`DexClueScanner.maxBytesPerDex = 8 MiB`、`maxTotalBytes = 48 MiB`（`dex_clue_scanner.dart:104/107`）。实测 343 MB 的包只覆盖 7/55 个 DEX。更优解是读 `string_ids` 字符串池（见 §十四）。
- 这是**已声明的限制**：扫描摘要与预算说明都会进「覆盖不足」面板，并已本地化（V2.4.9）。

---

## 六、V2.4.10 归档安全预算专项审计

### 6.1 实现位置

| 环节 | 文件:行 |
|---|---|
| 预算判定 | `packages/archive_safety/lib/src/zip_budget.dart:50` `check()` |
| 打开路径（APK） | `packages/apk_parser/lib/src/apk_reader.dart:88`（流式）/ `:124`（内存） |
| 打开路径（IPA/通用） | `lib/utils/zip_helper.dart:44` |
| 解包路径 | `lib/utils/tool_downloader.dart:348/362`（`ensureWithin`）；`lib/utils/xapk_installer.dart:177`（`ZipGuard.safeJoin`） |
| 路径防护 | `lib/utils/zip_guard.dart:22` `safeJoin` |

### 6.2 预算依据：**只读声明值**

`ZipBudget.check` 遍历 `archive.files`，累加 `file.size`（`ArchiveFile.size` = 中央目录声明的 `uncompressedSize`）。**没有任何一处校验实际解压出来的字节数。**

### 6.3 关键实测：声明值可以撒谎，预算不会触发

构造样本：100 MiB 全零条目 → 用 `ZipEncoder` 正常编码 → **只把中央目录里的 `uncompressedSize` 改成 1024**（deflate 流不动）。

```text
样本 457,681 字节（压缩后），CD 声明解压 1024 字节
open = ok                                  ← 预算通过（声明 1 KiB）
readFile 返回 104,857,600 字节，耗时 40ms   ← 实际解压 100 MiB
RSS 增量 201 MiB
```

**结论：`ZipBudget` 的防护建立在「攻击者如实申报尺寸」这个前提上，而该前提不成立。**

为什么能绕过：`archive` 包在 IO 平台走 native zlib，**不使用声明的解压尺寸**：

- `~/.pub-cache/.../archive-3.6.1/lib/src/zip/zip_file.dart:163-167`
  ```dart
  if (_rawContent is InputStream || (useNativeZLib() && _rawContent.length < oneGB)) {
    _content = inflateBuffer(_rawContent.toUint8List());   // 无上限
  } else {
    _content = Inflate.buffer(_rawContent, uncompressedSize).getBytes();
  }
  ```
- `_inflate_buffer_io.dart`：`ZLibDecoder(raw: true).convert(data)` —— 输出按实际流增长。

### 6.4 影响面

| 调用点 | 后果 |
|---|---|
| `ApkReader.readFile(name)`（`apk_reader.dart:287-290`）→ `file.content` | 内存耗尽（无上限） |
| `ZipHelper.extractFile`（`zip_helper.dart:104`）`File(out).writeAsBytes(file.content)` | **磁盘**耗尽（无上限） |

攻击面：一个几 MB 的 APK，把 `classes.dex` 的 CD 声明写成 1 KiB、实际流展开到 8 GiB。工具会在「解析 DEX」那一步吃掉 8 GiB 内存。

### 6.5 其余检查项逐条结论

| 检查项 | 结论 |
|---|---|
| 1. `ZipBudget` 真实实现 | 已读（§6.1） |
| 2. `ZipGuard` / 执行位置 | 已读（§6.1） |
| 3. 用声明值 / 局部头 / 实际字节 | **仅中央目录声明值** |
| 4. 读取过程是否持续限制真实字节 | **否**（§6.3） |
| 5. 归档库是否在预算检查前分配内存 | **是**：`ZipFile` 构造函数 `zip_file.dart:78` `_rawContent = input.readBytes(header!.compressedSize!)` —— **每个条目的压缩字节在 `decodeStream` 阶段就被读入**，早于 `ZipBudget.isExceeded`。量级等于「文件本身的压缩后大小」，由用户选中的文件决定 |
| 6. 嵌套归档预算是否共享 | **`ZipBudgetTracker` 已实现但生产代码未接线**（全仓仅 `packages/archive_safety/test/archive_safety_test.dart` 引用） |
| 7. 重复名 / 异常路径 / 溢出 / 负值 / 超大声明 / 截断 | 负值 → `check` 拒绝；超大声明 → 拒绝；路径 → `ZipGuard.safeJoin`（`..`/绝对/盘符/UNC/`~`/isWithin 五重）；重复名 → `findFile` 取首个；截断 → `looksStructurallyBroken`（`archive_open.dart:91`，只覆盖「0 条目但文件不小」一种形态） |
| 8. 移除压缩比的安全测试与威胁模型 | 有测试（§6.6），**威胁模型未写**：`zip_budget.dart:21-34` 只论证了「压缩比无法区分填充与炸弹」，没有论证「去掉之后靠什么兜住」 |
| 9. 是否存在易绕过的解压调用路径 | **是**（§6.3） |
| 10. 超限时能否指出条目 | 能：`ZipBudgetViolation{entry, reason}`，异常消息带条目名 |
| 11. 超大合法填充 Manifest 能否解析 | **能**：实测 `49af6cnn-1018.apk`（72.3 MiB 清单）226ms 解析完成 |
| 12. 超单条目/总量/条目数是否拒绝 | 能：`test/archive_open_test.dart` 三条用例分别断言并定位条目 |

### 6.6 测试覆盖（`test/archive_open_test.dart` + `packages/archive_safety/test/archive_safety_test.dart`）

| 场景 | 断言 |
|---|---|
| 17 MiB 零填充条目 | **打开成功且真能读出 17,825,792 字节**（V2.4.10 起不再按压缩比拒绝） |
| 单条目 300 MiB | 拒绝，`violation.entry == 'classes.dex'`，`reason` 含 `per-entry limit` |
| 5 × 250 MiB（总量 1.25 GiB） | 拒绝，`reason` 含 `cumulative` |
| 100,001 条目 | 拒绝，`reason` 含 `entry count` |
| 72 MiB 清单 + 20 MiB arsc | **不误报** |
| 随机输入 40 次 | 永不抛异常，结果始终是合法枚举 |
| `ensureWithin` | 抛 `ZipBombException` 并带 source |
| **声明值撒谎** | **无测试** ← 与 §6.3 的缺陷对应 |

### 6.7 专项结论

> **判定：存在绕过 / 资源耗尽风险。**

V2.4.10 的改动本身是**正确的**（压缩比确实无法区分填充与炸弹，实测 229:1 vs 205:1），绝对上限也确实一条没动。但这次复核暴露了一个**比压缩比更根本的问题**：预算读的是不可信输入自报的数字。修复方向见 §十三 `P1-1`。

---

## 七、安全检测引擎审计

### 7.1 证据分层是否成立

| 层 | 载体 | 是否与下一层独立 |
|---|---|---|
| 字符串线索 | DEX 原始字节中的可打印 ASCII | 独立 |
| 方法引用 | `method_ids` 结构化遍历 | 独立（不是字符串匹配） |
| 调用点 | `code_item` 里的 `invoke-*` 指令 | 独立（含调用方 + 偏移） |
| 原生符号 | ELF `.dynsym` | 独立 |

**「未发现线索 ≠ 安全」这条是否落实**：是。`SecurityAnalysisResult.limitations` 与 `AnalysisCoverage` 是**一等字段**，面板会显示「覆盖不足」；`hasGaps` 由 `CoverageEntry.isGap` 聚合（`analysis_coverage.dart:140`）。

### 7.2 风险等级与置信

- 等级：`P0/P1/P2/P3 + INFO`（`SecuritySeverity`），另有 `SecurityConfidence`。
- **`UNKNOWN` 不与低风险合并**：`SignatureVerdict.inconclusive` 与 `rejected` 分开（`package_analysis_result.dart:38-44` 有明确注释：「把没装 Android SDK 显示成签名无效，会把正常开发机误报成恶意应用」）。
- 规则版本：`SecurityAnalysisResult.rulesVersion` / `engineVersion` 独立存在。

### 7.3 网络回传的五级区分

README 与代码均区分「字符串里提到 / 有 API 能力 / 多个关联证据」。**没有动态分析**，因此「运行时观察」一级永远为「无」——`android.offline_static_analysis` 与 `ios.offline_static_analysis` 两条文案明确写出（V2.4.9 已修掉其中漏出的代码标识符）。

### 7.4 已知缺口

| 缺口 | 位置 | 状态 |
|---|---|---|
| 加固证据正文仍是英文 | `hardening.dart:203`（诱饵条目）、`binary_xml.dart:120-150`（4 条 AXML 异常） | **仍存在**（V2.4.9 §3 已记录，需改三处模型） |
| `analysis_diagnostic` 只有 14 键 | `lib/utils/analysis_diagnostic_text.dart:60-110` 的 switch | **仍存在**：绝大多数诊断 code 回退英文 |

---

## 八、UI、国际化与报告导出

### 8.1 输出同源

- Markdown：`AnalysisReport.render`（`analysis_report.dart:37`）
- JSON：`AnalysisReport.renderJson`（`:1534`）
- UI：`fileState.analysis`（`info_page.dart:602`）

三者都从 `PackageAnalysisResult` 出发，**没有第二套数据源**。JSON 出口刻意保留 `code` / 英文回退给程序读（与「界面显示本地化」不冲突）。

### 8.2 版本对比的状态机

`DiffKind { added, removed, changed, same, unknown }`（`package_diff.dart:24-42`）。

**`unknown` 单独存在**：任一侧是 `failed`/`unsupported`/`wrongType` 时不给 `added`/`removed` —— 注释明确写「这不是『没有差异』，是『这次说不清』」。审计要求区分「无法比较 / 源数据缺失 / 覆盖不足」，**已落实**。

### 8.3 国际化（重新统计，不采用旧数字）

| 语言 | 键数 | 相对 en | 占位符不匹配 |
|---|---:|---:|---:|
| en | **817** | 基准 | — |
| zh-CN | **817** | 缺 0 | 0 |
| zh-HK | **817** | 缺 0 | 0 |
| zh-TW | **817** | 缺 0 | 0 |
| ja | **730** | **缺 87** | 0 |
| ko | **730** | **缺 87** | 0 |

ja / ko 缺的 87 键分布：`report` 40、`field_diagnostic` 15、`analysis_diagnostic` 14、`overview` 10、`apk_info` 5、`signature` 1、`settings` 1、`home` 1。

> **与旧数字对比**：上轮审计记录 ja/ko 为 34%（约 279/814），本轮为 **89.4%（730/817）** —— 提升显著，但仍有 87 键回退英文。`report` 组 40 键缺失意味着**日语/韩语界面的导出的 Markdown 报告仍是英文标题**。

### 8.4 系统缩略图（审计任务书 §8.1）

**核实结果：未实现。**

| 检查项 | 结果 |
|---|---|
| Windows `IThumbnailProvider` / Shell 扩展 | **无**（`windows/` 下无 CLSID / ThumbnailProvider / 注册表写入） |
| macOS Quick Look Thumbnail Extension | **无**（无 `.appex` / `.qlextension` 目标） |
| UTI / 文件类型配置 | **有，但只是文件关联**：`macos/Runner/Info.plist:33` `CFBundleDocumentTypes` + `:60` `UTImportedTypeDeclarations` |
| 纳入安装包 / 签名 / 卸载 | 不适用（无扩展） |
| 真实 Explorer / Finder 验证 | 不适用 |

**按审计规则，这属于规划项，不计入 V2.4.10 的缺陷。** 但顺带发现一个**文件关联的缺口**：`macos/Runner/Info.plist` 的文档类型只列了 `apk/xapk/apkm/apks`（`:38-41`、`:77-80`），**没有 `ipa`** —— 双击 IPA 不会用本应用打开。

---

## 九、测试与 CI/CD 实测

### 9.1 根项目门禁（全部真跑）

| 命令 | 退出码 | 结果 |
|---|---:|---|
| `flutter pub get --enforce-lockfile` | **0** | 依赖锁定生效 |
| `dart run build_runner build --delete-conflicting-outputs` | **0** | 生成后 `git status --short` **仍为空**（生成物未入库、未污染工作区） |
| `dart format --output=none --set-exit-if-changed $(git ls-files -co --exclude-standard '*.dart')` | **0** | 237 文件，0 changed |
| `flutter analyze --fatal-infos --fatal-warnings` | **0** | No issues found |
| `flutter test`（`NO_PROXY=127.0.0.1,localhost,::1`） | **0** | **1,195 通过 / 14 跳过** |
| `flutter build bundle` | **0** | 整包编译通过（不需要平台工具链） |

### 9.2 四个包（逐包独立子 shell，未切错目录）

| 包 | `dart analyze` | `dart test` |
|---|---:|---:|
| `analysis_model` | **0** | **0**（58 用例） |
| `archive_safety` | **0** | **0**（25 用例） |
| `apk_parser` | **0** | **0**（68 用例） |
| `ipa_parser` | **0** | **0**（54 用例） |

### 9.3 14 个跳过项（逐个核实，非「偷偷跳过」）

| 原因 | 数量 |
|---|---:|
| 未设置 `APPINFOTOOL_SAMPLES`，外部真实样本测试未执行 | 13 |
| 「该用例只在非 macOS 上执行（macOS 一定有 codesign）」 | 1 |

**含义**：13 条依赖**用户本地真实 APK/IPA 样本**的端到端测试在 CI 与本次审计中都没有跑。这不等于功能有问题，但意味着「真实大包端到端」这条路径**只有人工验证**（V2.4.7 的 343 MB 性能数据就是人工跑的）。

### 9.4 CI 工作流（`.github/workflows/build.yml`，814 行）

| Job | 依赖 | 说明 |
|---|---|---|
| `quality` | — | format / analyze / `flutter test` / `flutter build bundle` / 四包 analyze + test（**与本地门禁一致**） |
| `external-samples` | `quality` | 外部样本（需 secret） |
| `build-windows` | **`quality`** | ✅ 质量红则构建不跑 |
| `build-macos` | **`quality`** | ✅ |
| `build-linux` | **`quality`** | ✅ |
| `create-release` | `[build-windows, build-macos, build-linux]` | `if` 只要求 windows+macos 成功（注释说明：Linux 依赖 linuxdeploy 外部下载，不宜作为硬门） |
| `publish-scoop` / `publish-homebrew*` | `[create-release]` | `if: github.repository == 'huanfeng/ApkInfoTool'` → **在本 fork 恒跳过**（不污染上游） |

**「quality 失败会不会仍然发版」**：不会 —— 三个 build job 都 `needs: quality`。

### 9.5 发布产物一致性

| 项 | 结果 |
|---|---|
| tag `v2.4.10` → 提交 | `10c85d0f` = HEAD ✅ |
| Release 名称 / 状态 | `Release v2.4.10`，**非 draft**，published `2026-10-18T11:13:04Z` |
| 产物 | macOS DMG 32.6 MB、Windows Setup 11.1 MB、Windows zip 12.2 MB、Linux AppImage 11.1 MB —— **四个都在** |
| 与源码 tag 对应 | `target_commitish: main`，tag 指向 `10c85d0` ✅ |

### 9.6 未能在本机验证的构建

`flutter build macos` / `windows` / `linux` 在本机**无法完成**（macOS 的 SPM 步骤被沙箱拒；另两个只支持各自宿主）。本轮**未尝试**，因此三平台产物只能以 CI 记录为准（§9.5 的产物时间戳与 tag 一致，可作旁证）。

---

## 十、主要问题清单

> 编号规则：`P<等级>-<序号>`。每条含取证命令、代码位置、影响、建议与验收标准。

### P1-1 解压预算只看声明值，可被「CD 撒谎」绕过（**本轮最重要发现**）

| 项 | 内容 |
|---|---|
| **等级** | **P1**（关键安全路径缺乏实际验证；可导致内存/磁盘耗尽） |
| **状态** | 当前仍存在 |
| **取证** | 见 §6.3：CD 声明 1024 字节 → `open=ok` → `readFile` 返回 104,857,600 字节，RSS +201 MiB |
| **代码位置** | `packages/archive_safety/lib/src/zip_budget.dart:50-85`（只读 `file.size`）；`packages/apk_parser/lib/src/apk_reader.dart:287-290`（`file.content` 无上限）；`lib/utils/zip_helper.dart:104`（落盘同样无上限）；根因在 `archive-3.6.1/lib/src/zip/zip_file.dart:163-167`（native zlib 忽略声明尺寸） |
| **影响** | 一个几 MB 的恶意包可让应用吃掉数 GiB 内存或写满磁盘；现有「1 GiB 总量 / 256 MiB 单条目」在这条路径上**完全无效** |
| **原因** | 预算设计成「打开时按中央目录声明值快速判定」，没有在实际解压路径上二次约束 |
| **建议** | 二选一或并用：①在 `ApkReader.readFile` / `ZipHelper.extractFile` 解压后校验 `bytes.length <= maxSingleEntryUncompressed`（只能止损，不能防峰值）；②**根本解**：改用有上限的流式解压（`Inflate.stream` + 计数到上限即中止，或 `ZLibDecoder` 接一个超限即抛的 `Sink`），把上限下沉到解压本身 |
| **工作量** | ②约 0.5–1 天（新增 `boundedInflate()` + 替换两个读取点 + 测试） |
| **验收** | 新增用例：CD 声明 1 KiB / 实际 100 MiB 的样本 → **被拒绝或解压到上限即中止**，且异常指出条目名；`test/archive_open_test.dart` 现有 17 条仍全绿 |
| **依赖** | 无。与 §十四 的 `string_ids` 改造互不影响 |

### P1-2 加固证据正文仍是英文，中文界面混排

| 项 | 内容 |
|---|---|
| **等级** | P1（用户可见的重大质量问题；已两次被用户点名） |
| **状态** | 当前仍存在（V2.4.9 明确记为下一轮） |
| **取证** | `grep -n "entries use a file entry as a directory prefix" packages/apk_parser/lib/src/hardening.dart` → `:203`；实测输出「容器/解析异常可能影响覆盖完整性：159 entries use a file entry as a directory prefix…」 |
| **代码位置** | `hardening.dart:203`；`binary_xml.dart:120-150`（4 条 AXML 异常）；汇聚点 `android_security_audit.dart` 的 `containerAnomalies` |
| **影响** | 加固包（本工具的核心样本）的覆盖说明一半中文一半英文 |
| **建议** | 把 `HardeningObservation.evidence` / `ManifestLayoutAnomalies.evidence()` 改成 `code + args`，由 `AnalysisReport.limitationNoteText` 查表 |
| **工作量** | 1–1.5 天（三处模型 + 6 语言包 + 测试） |
| **验收** | `test/limitation_notes_test.dart` 的「所有语言包里的每一条」守卫扩展到 `android.container.anomaly` 的实参不得含英文句子 |

### P2-1 `analysis_diagnostic` 只有 14 个键

- **状态**：仍存在。`lib/utils/analysis_diagnostic_text.dart:60-110` 的 switch 只覆盖 14 个 code；`assets/i18n/en.json` 的 `analysis_diagnostic` 组也只有 14 键。
- **影响**：解析诊断卡片上大多数条目显示英文。
- **建议**：按 `packages/apk_parser` 实际产出的 code 清单补齐（本轮实测 `android_security_audit.dart` 有 60+ 个 code）。
- **验收**：新增一条「审计产出的每个 code 都能取到非英文文案」的守卫。

### P2-2 ja / ko 仍缺 87 键

- **状态**：仍存在（730/817 = 89.4%）。
- **影响**：日语/韩语界面的**导出报告标题**、`field_diagnostic`、`analysis_diagnostic`、`overview` 等仍为英文。
- **建议**：优先补 `report` 组 40 键（导出报告是交付物）。
- **验收**：`i18n_coverage_test.dart` 把 ja/ko 纳入断言范围。

### P2-3 DEX 字符串扫描仍按原始字节 + 8/48 MiB 预算

- **状态**：仍存在（V2.4.9 已论证「提高上限不划算」，但没做更优解）。
- **代码位置**：`packages/apk_parser/lib/src/security/dex_clue_scanner.dart:104/107/163`
- **影响**：343 MB 的包只覆盖 7/55 个 DEX 的字符串。
- **建议**：改扫 `string_ids` 字符串池（100% 覆盖 + 读的字节更少）。
- **验收**：同一 343 MB 样本的「覆盖的 DEX 数」从 7 提到 55，且字符串扫描耗时不超过现状 2 倍。

### P2-4 `vector_to_svg.dart` 零测试

- **取证**：`grep -rl vector_to_svg test/` → 0 个文件。
- **影响**：自适应图标导出 SVG 这条路径没有任何安全网。
- **验收**：至少一条「给定 `AdaptiveIconSvgData` → 产出合法 SVG」的用例。

### P2-5 解析器包内测试与其体量不匹配

- `apk_parser`：9,165 行 lib / 886 行 test（68 用例）
- `ipa_parser`：6,787 行 lib / 744 行 test（54 用例）
- **缓解**：真实覆盖寄生在根 `test/`（83 个文件 / 25,095 行），CI 的包级 `dart test` 对这两个包接近空转。
- **建议**：把根测试里与解析器强相关的用例迁一部分进包内，让 `dart test` 有实际拦截力。

### P3-1 macOS 文件关联缺 `.ipa`

- **位置**：`macos/Runner/Info.plist:38-41`、`:77-80`
- **影响**：双击 `.ipa` 不会用本应用打开（Windows 侧未见关联配置，可能由安装器处理，**未验证**）。

### P3-2 `looksStructurallyBroken` 只覆盖「0 条目」一种形态

- **位置**：`packages/archive_safety/lib/src/archive_open.dart:91-94`
- **影响**：截断/半损坏归档大多落到「解析出部分结果」而不是「明确判损坏」。

### P3-3 `ZipBudgetTracker`（跨层累计预算）未接线

- **取证**：全仓仅 `packages/archive_safety/test/archive_safety_test.dart` 引用。
- **影响**：嵌套归档（APK 里套 ZIP）的累计预算在生产路径上不生效。当前嵌套场景主要走 `ApkReader.openBytes`，单层预算仍生效，因此风险有限。

### INFO-1 系统缩略图（Windows Shell / macOS Quick Look）

- **状态**：未实现（§8.4）。按审计规则列为**规划项**，不计入当前版本缺陷。

---

## 十一、完成度评分

口径：每项给出得分 / 权重 / 证据 / 扣分原因 / 可信度。**未验证项不给满分。**

| 维度 | 权重 | 得分 | 依据 | 扣分原因 | 可信度 |
|---|---:|---:|---|---|---|
| **APK / IPA 核心解析能力** | 20 | **18.0** | 18 项能力逐条核实到代码与测试（§4）；DEX 三层证据有偏移/调用方断言（§5.1）；ICP 备案号有 15 条测试 + 真实样本实测 | 解析器包内测试偏薄（P2-5）；字符串扫描覆盖受限（P2-3） | 高（全部实测） |
| **安全检测与证据可信度** | 20 | **17.0** | 四层证据独立；`UNKNOWN`/`inconclusive` 与低风险分开；覆盖维度一等建模；无动态分析时明确声明（§7） | 加固证据英文（P1-2）；`analysis_diagnostic` 覆盖不足（P2-1） | 高 |
| **不可信输入安全边界与稳定性** | 15 | **9.0** | `ZipGuard.safeJoin` 五重路径防护；负值/超大/条目数均拒绝并能定位条目；随机输入 40 次不抛异常（§6） | **预算可被 CD 撒谎绕过（P1-1，实测）**；`ZipBudgetTracker` 未接线（P3-3）；结构检查只覆盖一种形态（P3-2） | 高（缺陷已复现） |
| **测试体系与 CI 质量门禁** | 15 | **12.0** | 1,400 用例全绿；六道门禁本地实测 6/6 `EXIT=0`；CI 四平台 + Release；build job 均 `needs: quality`（§9） | 分布不均（P2-5）；`vector_to_svg` 零测试（P2-4）；13 条外部样本测试长期跳过 | 高 |
| **UI / 交互完整度** | 10 | **9.0** | 4 页 + 6 Tab + 拖放 + 取消 + 重命名 + 图标 + 版本对比；V2.4.8/2.4.9 的标题折断、图标尺寸、丢图标已修并有测试 | **本机无法构建，未做目视验收**（§9.6） | 中（代码与测试可证，观感未证） |
| **分析报告与版本对比** | 10 | **9.0** | Markdown/JSON/UI 同源；`DiffKind` 含 `unknown`；导出三态有测试 | ja/ko 的 `report` 组 40 键缺失（P2-2） | 高 |
| **国际化与文档** | 5 | **4.0** | 4 语言包 817/817 全等；占位符零不匹配；CHANGELOG 与代码同步；进度文档纪律好 | ja/ko 89.4%（P2-2）；`analysis_diagnostic` 仅 14 键（P2-1） | 高（已重新统计） |
| **构建、安装、发布成熟度** | 5 | **4.5** | tag↔HEAD↔产物三方一致；四产物齐全；CI 结构清晰且有注释说明取舍 | macOS 文件关联缺 `.ipa`（P3-1）；三平台构建未能本机复现 | 中高 |
| **合计** | **100** | **82.5** | | | |

**评分说明（必须与数字一起读）**：

1. **82.5 不是「82.5% 完成」**，而是「按 8 个维度加权后的工程成熟度」。功能本身接近完整。
2. **唯一被实测缺陷显著拉低的是「不可信输入安全边界」（9/15）**。如果 P1-1 修好，该维度可回到 13–14，总分升到 86–87。
3. 未验证项（三平台构建、界面观感）**没有给满分**，但也没有按「未实现」扣分 —— 它们有 CI/代码证据。
4. **测试全绿不等于没有安全风险**：P1-1 就在 1,400 个全绿用例之下。

---

## 十二、已知限制（合理取舍，不计为发布阻断）

| 限制 | 原因 | 是否有意 |
|---|---|---|
| 无动态分析 | 只做离线静态分析，不安装/不运行/不抓包 | 有意（规范要求不得声称已做行为确认） |
| DEX 字符串只扫可打印 ASCII | 非 ASCII 字面量、加固壳内代码不在覆盖 | 有意（已在覆盖面板声明） |
| DEX 扫描有 8/48 MiB 预算 | 控制大包耗时（V2.4.7 实测提高上限收益极低） | 有意 |
| 原生代码不反汇编 | 只读 ELF `.dynsym` | 有意 |
| 系统缩略图未实现 | 属 V2.5.0 规划 | 有意 |
| 加固包可能读不出真实逻辑 | 壳内代码加密 | 有意（如实标注覆盖不足） |
| 三平台产物不在本机构建 | 沙箱/宿主限制 | 有意（走 CI） |

---

## 十三、未验证事项

| 项 | 原因 | 影响 |
|---|---|---|
| `flutter build macos` / `windows` / `linux` | 本机 macOS 的 SPM 步骤被沙箱拒；另两平台只支持各自宿主 | 三平台产物只能信 CI 记录（§9.5 有时间戳旁证） |
| 界面实际观感 | 同上（无法产出可运行包） | 标题宽度 96px、图标 92px 等视觉参数未目视确认 |
| 13 条外部真实样本测试 | 需 `APPINFOTOOL_SAMPLES` | 真实大包端到端只有人工验证 |
| Windows 安装器的文件关联 | 安装器在 CI 生成，本机无产物 | 未知是否关联 `.apk` |
| iOS `codesign` 在真实 IPA 上的行为 | 需真实签名样本 | 只验证了「工具缺失时的降级」与代码路径 |
| 缩略图扩展 | 未实现 | 不适用 |

---

## 十四、下一阶段路线图

### 14.1 必须马上处理（发布阻断级）

**P1-1 解压预算绕过** —— 理由：它是本轮唯一「已实测复现」的安全缺陷，且现有 1 GiB / 256 MiB 上限在这条路径上完全无效。**放行条件**：新增「CD 撒谎」用例并让它变绿；`archive_open_test.dart` 17 条不回归。

### 14.2 下一次功能迭代应完成

1. **P1-2 加固证据结构化**（1–1.5 天）—— 用户已两次点名「看不懂」。
2. **P2-1 补齐 `analysis_diagnostic`**（0.5–1 天）—— 与 P1-2 同一类问题，可合并做。
3. **P2-2 补 ja/ko 的 `report` 组 40 键**（0.5 天）—— 导出报告是交付物。
4. **P2-4 `vector_to_svg` 测试**（0.5 天）—— 零测试的模块只剩这一个。

### 14.3 值得投入的新功能

| 功能 | 价值 | 依赖 |
|---|---|---|
| **`string_ids` 字符串池扫描**（P2-3） | 100% 覆盖 + 更少字节，同时解决「大包只扫 7/55 DEX」 | 需要 `DexTables` 已有的能力，改动集中在一个扫描器 |
| **系统缩略图（V2.5.0 已规划）** | Windows Explorer / macOS Finder 直接看图标，是产品级差异点 | 需要平台原生扩展 + 安装器改造 |
| **把「高压缩比」升级为加固线索** | V2.4.10 去掉的是「拒绝」，但这条信号本身有价值 | 可挂在 `HardeningSignal` 上，成本低 |

### 14.4 暂不建议投入

| 项 | 理由 |
|---|---|
| 按 DEX 并行扫描 | 与 `Isolate.immediate` 的取消语义冲突（杀 worker 不杀子 isolate），风险大于收益 |
| 恢复压缩比拒绝规则 | 实测无法区分填充与炸弹（229:1 vs 205:1） |
| 提高 DEX 扫描预算 | V2.4.9 实测：加固包 +0 线索，抖音 +3 线索 / +8 秒 |

### 14.5 推荐顺序与放行条件

```
P1-1（预算绕过）
  └─ 放行：CD 撒谎用例绿 + 现有 17 条不回归
       └─ P1-2 + P2-1（加固证据 + 诊断文案，合并做）
            └─ 放行：limitation_notes 全语言守卫扩展到 container.anomaly
                 └─ P2-2（ja/ko report 组）
                      └─ 放行：i18n_coverage_test 纳入 ja/ko
                           └─ P2-3（string_ids 扫描，独立分支）
```

---

## 十五、审计证据索引

### 15.1 取证命令与退出码

| 命令 | 退出码 | 日志 |
|---|---:|---|
| `flutter pub get --enforce-lockfile` | 0 | `/tmp/aud_pubget.log` |
| `dart run build_runner build --delete-conflicting-outputs` | 0 | `/tmp/aud_br.log`；之后 `git status --short` 为空 |
| `dart format --output=none --set-exit-if-changed $(git ls-files -co --exclude-standard '*.dart')` | 0 | 237 文件 / 0 changed |
| `flutter analyze --fatal-infos --fatal-warnings` | 0 | No issues |
| `flutter test`（`NO_PROXY=127.0.0.1,localhost,::1`） | 0 | 1,195 通过 / 14 跳过 |
| `flutter build bundle` | 0 | — |
| `packages/{analysis_model,archive_safety,apk_parser,ipa_parser}` 的 `dart analyze` + `dart test` | 各 0 | 58 / 25 / 68 / 54 用例 |

### 15.2 关键代码位置

| 主题 | 文件:行 |
|---|---|
| 预算判定 | `packages/archive_safety/lib/src/zip_budget.dart:50` |
| 预算常量 | 同上 `:16`（1 GiB）、`:19`（10 万条目）、`:41`（256 MiB） |
| 打开时校验 | `packages/apk_parser/lib/src/apk_reader.dart:88`、`:124` |
| 读取（无上限） | `packages/apk_parser/lib/src/apk_reader.dart:287-290` |
| 落盘（无上限） | `lib/utils/zip_helper.dart:104` |
| 路径防护 | `lib/utils/zip_guard.dart:22-49` |
| 结构检查 | `packages/archive_safety/lib/src/archive_open.dart:91` |
| 归档库根因 | `archive-3.6.1/lib/src/zip/zip_file.dart:78`、`:163-167` |
| 加固证据（英文） | `packages/apk_parser/lib/src/hardening.dart:203`；`binary_xml.dart:120-150` |
| 诊断本地化 switch | `lib/utils/analysis_diagnostic_text.dart:60-110` |
| 差异状态机 | `packages/analysis_model/lib/src/package_diff.dart:24-42` |
| 覆盖模型 | `packages/analysis_model/lib/src/analysis_coverage.dart:132-145` |
| 签名四态 | `lib/models/analysis/package_analysis_result.dart:29-49` |
| macOS 文件关联 | `macos/Runner/Info.plist:33-80` |
| CI | `.github/workflows/build.yml:15`（quality）、`:450`（create-release） |

### 15.3 本轮产生的临时产物

| 文件 | 处理 |
|---|---|
| `tool/zz_audit_probe_test.dart`（用于 §6.3 的 CD 撒谎实验） | **已删除**，`git status --short` 为空 |
| `/tmp/aud_*.log`（门禁日志） | 保留在 /tmp，不入库 |

**本轮未修改任何业务代码、测试、版本号、lockfile、tag、分支或远端。**

---

## 附：与上一轮审计（2026-10-16）的对照

| 上轮问题 | 本轮状态 |
|---|---|
| P1-1 ja/ko 仅 34% | **部分修复**：730/817 = 89.4%，仍缺 87 键 |
| P1-2 解析器包内测试与体量不匹配 | **部分修复**：apk_parser 34→68、ipa_parser 33→54，仍偏薄 |
| P2-1 `ToolDownloader` 校验和零测试 | **已修复且有测试**：`test/tool_downloader_test.dart` 存在，`verifyArchiveChecksum` 在 `tool_downloader.dart:76/93` 被调用 |
| P2-2 `ReportExporter` 零测试 | **已修复且有测试**：`test/report_exporter_test.dart`；三态 `isSaved/isCancelled/failure` 已实现（`report_exporter.dart:24-37`） |
| P2-3 `xapk_installer` 零测试 | **已修复且有测试**：`test/xapk_installer_test.dart` + `test/xapk_security_audit_test.dart` |
| （上轮未列）解压预算只看声明值 | **新发现**，见 P1-1 |
