# AppInfoTool — 项目完整度审计报告

- **日期**：2026-10-16
- **审计对象**：`main` @ `4ecb801`（tag `v2.4.1`，pubspec `2.4.1`）
- **环境**：Flutter 3.47.7 stable / Dart 3.13.5（本机实测）
- **方法**：**实测**。门禁命令全部真跑并记录退出码；规模、测试数、i18n 键数、fixtures 用命令统计；功能声明逐条落到 `文件:行`。
  **凡未实测的一律标注**，不写推测值。
- **未修改任何生产代码**（本报告只读；唯一的写入是本文件）。
- **与既有审计的关系**：2026-10-13 的报告是**安全**审计，本报告是**完整度**审计，并在第九节复核了那份报告 T0/T2 项的现状。

---

## 一、总体结论

**完整度：高。** 这是一个**已经可以正常对外分发**的成品，不是半成品。

三个层面都站得住：

1. **功能面基本没有空洞**。README 声称的能力逐条都能落到代码（第四节），没有发现「写了但没实现」的功能项。2026-10-13 审计提出的两条 T0（Zip-Slip、工具二进制零校验执行）**已真实修复并有测试**，当时指出的「AXML 解析器两份分叉副本」也**已经消除**（第九节）。
2. **工程纪律明显高于同类个人项目**。依赖方向干净（`analysis_model` 运行时零依赖、两个解析器互不依赖）；5 个 lockfile 全部入库；`pubspec.lock` 有 `--enforce-lockfile` 门禁；CI 在 `main` 上就做真实三平台编译而不只是 analyze；1220 个用例全绿。
3. **文档不是摆设**。CHANGELOG 入库、逐版本有实测门禁表、两份过时文档明确标注「已过时（历史证据，保留不改正文）」并给出指向，README 有中英结构不变量测试。

**但有三处实质性缺口**，都是「广度够、深度不够」型，而不是「缺功能」型：

| # | 缺口 | 影响 |
|---|---|---|
| **A** | **日语 / 韩语只翻译了 34%**（279/814 键） | 用户可见：这两个语言的界面上，**全部**安全发现、iOS 字段、版本对比、覆盖维度、诊断文案都是英文 |
| **B** | **两个解析器的包内测试极薄**（apk_parser 5.5%、ipa_parser 5.7%） | 解析不可信输入的核心代码，其回归保护主要寄生在根测试里 |
| **C** | **几处安全/新修模块零测试**：`ToolDownloader`（校验和校验）、`ReportExporter`（v2.4.1 刚修） | 校验和校验是 T0-2 的修复本体，改了没人拦 |

**风险等级：低—中。** 不阻塞分发；但 A 是**用户可见的成品度问题**，B/C 是**未来回归的隐患**。

---

## 二、完整度评分表

评分口径：**已实现且有测试** = 满分；**已实现但缺测试** 或 **有测试但覆盖薄** = 半分；**声明超出实现** = 零分。

| 维度 | 评分 | 依据（详见对应章节） |
|---|---|---|
| 架构与分层 | **A** | 依赖方向可验证；无循环；解析器分叉已消除（§三） |
| Android 解析能力 | **A−** | 能力齐全；包内测试薄，覆盖寄生在根测试（§四、§五） |
| iOS 解析能力 | **A−** | 同上；CgBI / Mach-O / 签名材料有专项夹具 |
| 安全检测引擎 | **A** | 规则表可配置、逐条有测试；覆盖维度与发现项文案本地化（§四） |
| 归档安全（不可信输入） | **A** | `ZipGuard.safeJoin` 9 个用例覆盖越界/盘符/UNC/`~`；预算下沉到 package（§九） |
| 工具链安全 | **B** | 校验和校验**已实现**但**零测试**（§八 C-1） |
| 界面功能 | **A** | 6 Tab / 概览 / 版本对比 / 拖放 / 导出 / 重命名全部核实到代码 |
| 国际化 | **C+** | 4 个语言包完整；**ja / ko 仅 34%**（§六） |
| 测试完整度 | **B** | 1220 用例全绿，但**分布不均**（§五） |
| 质量门禁 | **A−** | 六道门禁全绿；`riverpod_lint` 声明未启用（§八 C-4） |
| CI / 发布 | **A** | main 上真实编译三平台；tag 出四产物 + Release；fork 不污染上游（§七） |
| 文档 | **A−** | 纪律好；1 处文档卫生问题（§八 C-5） |

---

## 三、规模与结构（实测）

```
生产 Dart   44,698 行 / 140 文件
  lib/                 24,859 行 /  73 文件   （应用层，不含生成物）
  packages/            19,839 行 /  67 文件
测试 Dart   24,409 行 /  79 文件
  test/（根）          22,504 行 /  72 文件
  packages/*/test/      1,905 行 /   7 文件
测试 / 生产 ≈ 0.55 : 1（按行）
用例        1,220 通过 / 14 跳过（根 1070 + 包 150）
fixtures      404 KB /  37 个
提交          184 个（自 v2.3.7 起 46 个，自 v2.4.0 起 3 个）
```

统计命令：`git ls-files -co --exclude-standard '*.dart' | xargs wc -l`（`-co` 保证含未 `git add` 的新文件、且**排除**被 gitignore 的 `lib/gen/`、`*.g.dart`、`*.freezed.dart`）。

### 依赖方向（逐条读 `pubspec.yaml` 核实）

| package | 运行时依赖 | 评价 |
|---|---|---|
| `analysis_model` | **无**（只有 dev: `lints` / `test`） | 「零依赖」的声明**成立** |
| `archive_safety` | `archive` | 只依赖归档库 |
| `apk_parser` | `analysis_model` + `archive_safety` + `archive` + `logging` + `xml` | — |
| `ipa_parser` | `analysis_model` + `archive_safety` + `archive` + `xml` | — |

**`apk_parser` 与 `ipa_parser` 互不依赖** —— 两个 `pubspec.yaml` 里都没有对方，声明成立。

### 值得记录的三点

1. **`archive` 是钉在具体 commit 的 git 依赖**（`huanfeng/archive` @ `cb3a07c8`），不是 pub.dev 上的包。
   好处：可复现、可控。代价：这是 **fork 的 fork**，上游安全修复不会自动流过来，升级要人工跟进。属**已知取舍**，不是缺陷，但值得写进风险清单。
2. **5 个 lockfile 全部入库**（根 + 四包），CI 用 `flutter pub get --enforce-lockfile` 卡住 —— 供应链可复现性做得比多数项目好。
3. **`lib/apkparser/` 不是分叉，是应用层**。它现在只放 `adaptive_icon_renderer` / `analysis_builder` / `apk_info`（模型+编排）/ `parse_task`（worker）/ `aapt2_task` / `xapk_info`，解析本体全部 `import 'package:apk_parser/apk_parser.dart'`。
   实测：全仓 `class BinaryXmlParser|AxmlParser|ArscParser|ManifestParser` **各只有一处定义**，全在 `packages/apk_parser/lib/src/`。**2026-10-13 审计的「两份分叉副本」已消除。**

---

## 四、功能完整度：README 声明逐条核对

README（`README.md`）的三张能力表共 20 余项，逐条落到代码：

### 包解析

| 声明 | 证据 | 结论 |
|---|---|---|
| Android：APK / XAPK / APKM / APKS | `lib/utils/package_file_type.dart`、`lib/utils/xapk_installer.dart` | ✅ |
| 应用名（多语言） | `packages/apk_parser/lib/src/apk_reader.dart:326` `localizedLabel = parser.getStringValue(resId, locale: locale)` | ✅ |
| 组件 + **导出状态** | `packages/apk_parser/lib/src/models.dart`（`AndroidComponent`） | ✅ |
| 分包与 OBB | `lib/models/split_type.dart`、`splitApks` / `obbFiles` | ✅ |
| DEX / 原生库 / 顶层目录结构 | `container_structure.dart` + `dex/` + `native/` | ✅ |
| iOS：Bundle ID / 版本 / 最低系统 / 设备族 / 可执行文件 | `packages/ipa_parser/lib/src/ipa_info_plist.dart` | ✅ |
| **嵌套 Bundle 与 Framework** | `lib/utils/ipa_bundle_extractor.dart`（逐条 `ZipGuard.safeJoin`） | ✅ |
| URL Scheme / 设备能力 / Mach-O 架构 | `ipa_info_plist.dart` + `macho.dart` | ✅ |

### 安全检测

| 声明 | 证据 | 结论 |
|---|---|---|
| 权限审计（含 `maxSdkVersion` 等版本条件） | `security/permission_catalog.dart`、`android_security_rules.dart` | ✅ |
| OCR / 敏感数据线索 | `security/dex_clue_scanner.dart` | ✅ |
| **代码级取证：结构 → 方法引用 → 调用点** | `dex/dex_structure.dart` / `dex_method_table.dart` / `dex_method_bodies.dart` / `dex_instruction.dart` | ✅ 三层齐全 |
| 原生库符号（ELF `.dynsym` + Mach-O `LC_SYMTAB`，**精确符号名、只匹配导入**） | `native/elf.dart`、`security/native_symbol_scanner.dart`、`macho_symtab_test.dart` | ✅ |
| 数据回传分析 | `android_security_rules.dart` 的 `network.*` 集合（差异页也消费它） | ✅ |
| 隐私清单（`Info.plist` 用途说明 + `PrivacyInfo.xcprivacy`） | `ipa_info_plist.dart:74-553`、`security/ios_privacy_audit.dart` | ✅ |
| 分析覆盖：逐维度状态 | `analysis_model/lib/src/analysis_coverage.dart`，**15 个维度**（实测 `coverage.dimensions` 键数 = 15） | ✅ |
| 风险分级 P0–P3 / INFO / **UNKNOWN** | `security_finding.dart:36` `enum SecuritySeverity { p0,p1,p2,p3,info,unknown }`，`unknown` 独立档位 | ✅ |

### 界面

| 声明 | 证据 | 结论 |
|---|---|---|
| 概览页一屏 | `lib/ui/overview/overview_page.dart` + `overview_layout_test.dart`（三档尺寸钉住不溢出） | ✅ |
| 详情页**六个 Tab** | `lib/widgets/detail_tab_view.dart:8` `enum DetailTab`（overview/application/permissions/structure/signature/security） | ✅ 6 个 |
| 版本对比（字段级 + 集合级、三态、导出） | `lib/ui/diff/`、`package_diff_adapter.dart`、`diff_report.dart` | ✅ |
| 拖放即用 | `desktop_drop` + `drop_target_ownership_test.dart` | ✅ |
| 导出报告 Markdown / JSON | `export_report_dialog.dart:9` `enum ExportFormat { markdown, json }` | ✅ |
| 导出图标 **PNG / SVG / 原始文件** | `info_page.dart:1923/1930/1934`、`overview_page.dart:1208-1226` | ✅ 3 种 |
| 重命名：**仅应用名 / 名称+版本** | i18n `rename.app_name_only` / `rename.name_with_version` | ✅ 2 种 |
| 明暗主题 | `lib/theme/theme_manager.dart` | ✅ |
| **六种界面语言** | 6 个语言文件存在 —— **但 ja / ko 只完成 34%** | ⚠️ **见第六节** |

**未发现「声明超出实现」的功能项。** 唯一的措辞问题在「六种界面语言」上（第六节）。

---

## 五、质量门禁与测试完整度

### 门禁实测（全部真跑，记录退出码）

| 命令 | 退出码 | 结果 |
|---|---|---|
| `flutter pub get --enforce-lockfile` | **0** | lockfile 一致 |
| `dart run build_runner build --delete-conflicting-outputs` | **0** | 0 outputs（已最新） |
| `dart format --output=none --set-exit-if-changed $(git ls-files -co --exclude-standard '*.dart')` | **0** | 215 文件，0 需改 |
| `flutter analyze --fatal-infos --fatal-warnings` | **0** | 0 issue |
| `flutter test` | **0** | **1070 通过 / 14 跳过** |
| 逐包 `dart analyze` + `dart test` ×4 | **0** ×8 | 58 / 34 / 25 / 33 = **150 通过** |

**合计 1,220 通过、0 失败。**

### 14 个跳过项（逐个核实原因，不是「偷偷跳过」）

- **13 个**需要 `APPINFOTOOL_SAMPLES`（真实样本目录未配置）：`real_samples_test.dart` 2 个 + `real_samples_ui_test.dart` 11 个。跳过时**打印原因**，不静默。
- **1 个**是平台条件：`ios_codesign_step_test.dart`「工具不可用时不解包」只在**非 macOS** 执行（macOS 一定有 `codesign`）。

即：**跳过项都有明确且合理的原因**，没有「因为不稳定所以跳过」。

### 测试密度分布（本报告的主要发现之一）

| 区域 | 生产 LOC | 测试文件 | 测试 LOC | 比值 |
|---|---|---|---|---|
| `lib/`（应用层） | 24,859 | 72（根） | 22,504 | 0.91 |
| `analysis_model` | 1,577 | 3 | 804 | **0.51** |
| `archive_safety` | 343 | 1 | 231 | **0.67** |
| **`apk_parser`** | **8,916** | **2** | **486** | **0.055** |
| **`ipa_parser`** | **6,781** | **1** | **384** | **0.057** |

**两个解析器是「处理不可信输入」的代码，测试密度却最低。**

需要说公道话：**解析器的真实覆盖寄生在根 `test/` 里** —— 42 个根测试文件引用 `package:apk_parser` 或 `package:ipa_parser`，合计 **17,163 行**（含 `android_security_audit_test.dart` 1490 行、`ios_privacy_audit_test.dart` 1430 行、`manifest_parser_test.dart`、`arsc_night_mode_test.dart`、`dex_*_test.dart`、`elf_test.dart`、`macho_symtab_test.dart`…）。所以**解析器并非没测**。

问题在于**结构**：CI 的 `Package-level tests` 那一步对这两个包近乎空转（`dart test` 只跑 34 / 33 个用例），而它们最重的测试住在根测试里。后果是**包的可移植性/独立性是假的** —— 想单独发 `apk_parser`，它自己的测试并不足以说明问题。

### fixtures（37 个 / 404 KB）

含**故意的畸形样本**，这是好信号：`bad-magic.dex`、`truncated.dex`、`method-ids-off-out-of-range.dex`、`header-size-not-standard.dex`、`bad-section-name-index.so`、`section-table-out-of-range.so`、`truncated.so`、`bad-magic.so`、`no-section-headers.so`，以及 `cyclic-color-alias.apk` / `cyclic-color-icon.apk`（资源引用环）。

每个目录都有 `README.md` 记录生成命令 —— 符合项目「夹具用真实产物、期望值用外部工具独立核对」的纪律。

### 零测试的模块（实测：全仓 `test/` 无任何引用）

| 模块 | 性质 | 严重度 |
|---|---|---|
| `lib/utils/tool_downloader.dart` | **校验和校验（T0-2 的修复本体）** | **高** |
| `lib/utils/report_exporter.dart` | v2.4.1 刚修的三态导出 | 中 |
| `lib/utils/xapk_installer.dart` | 原 Zip-Slip 现场（现走 `ZipGuard`，守卫本身有测试） | 中 |
| `lib/utils/vector_to_svg.dart` | 图标 SVG 导出 | 低 |
| `lib/utils/command_tools.dart` / `tool_paths.dart` | 外部命令与路径 | 低 |
| `lib/utils/file_association.dart` / `app_links.dart` / `cancellable_task.dart` | 平台薄封装 | 低 |

对照：`ZipGuard.safeJoin` **有 9 个用例**（`test/utils_test.dart:53-120`），覆盖父目录上跳、绝对路径、盘符、UNC、`~`、空条目名、反斜杠归一化，以及「看着像越界但其实合法」的 `a..b.png`。**这条安全控制守得很好** —— 差距在于它的**调用方**（`tool_downloader` / `xapk_installer`）没有测试。

---

## 六、国际化完整度（缺口 A）

`fallback_strategy: base_locale`、`base_locale: en`（`build.yaml`），所以缺键**回退英文**，不会崩 —— 但会中英混杂。

| 语言包 | 键数 | 相对 en 缺失 | 完成度 |
|---|---|---|---|
| `en.json` | **814** | — | 基准 |
| `zh-CN` / `zh-HK` / `zh-TW` | 813 | 1（`install.please_select_device`） | **99.9%** |
| **`ja.json`** | **279** | **535** | **34%** |
| **`ko.json`** | **279** | **535** | **34%** |

### 缺的正好是「新子系统」（按组统计 ja）

| 组 | en 键数 | ja 键数 | 缺失 |
|---|---|---|---|
| `security` | 243 | 11 | **232** |
| `ios_info` | 88 | **0** | **88** |
| `diff` | 75 | **0** | **75** |
| `coverage` | 52 | **0** | **52** |
| `report` | 49 | 9 | 40 |
| `field_diagnostic` | 15 | **0** | **15** |
| `analysis_diagnostic` | 14 | **0** | **14** |
| `overview` | 46 | 36 | 10 |
| `apk_info` | 41 | 36 | 5 |
| 其余 14 组 | — | — | 0～1 |

也就是说：**日语 / 韩语用户打开一个 IPA，看不到任何 iOS 字段的本地化；打开安全页，看不到任何一条安全发现的本地化；打开版本对比，整个页面是英文。** Android 基础字段（`apk_info` / `overview`）反而是翻译得最好的。

### 两点必须说清

1. **这是「已知且被接受」的，不是疏忽。** `test/i18n_coverage_test.dart` 里明确写「每个维度在**四个维护中的语言包**里都有名字」，只断言 `['en','zh-CN','zh-HK','zh-TW']`；覆盖维度那条测试的中文断言也只对 zh 生效。项目**知道** ja / ko 未维护。
2. **但 README 没有说。** `README.md` 写的是「明暗主题 + **六种界面语言**（简体中文 / 繁體中文 ×2 / English / 日本語 / 한국어）」。文件确实有 6 个，功能也真的能切换 —— 但对 ja / ko 而言，这更接近「界面语言切换」而不是「六种语言支持」。

**建议**（二选一，不要悬着）：
- **补全**：优先 `security` + `ios_info` + `diff` + `coverage`（447 键，占缺失的 84%）。这是纯翻译工作，不影响代码。
- **或如实标注**：README 写成「简体中文 / 繁體中文 ×2 / English 完整；日本語 / 한국어 部分翻译（其余回退英文）」，并在语言选择器里给 ja / ko 加个「部分」标记。

另外 **`install.please_select_device` 是孤儿键**：只在 `en.json:270` 与生成物里出现，`lib/` 下**无任何调用点**，三个中文语言包也都没有它。因为它没被使用，**用户不可见**，影响为零；但它是「en 多一个键」的唯一来源，清掉即可让六个语言包完全对齐。

---

## 七、发布与文档完整度

### CI（`.github/workflows/build.yml`）

| Job | main 推送 | tag `v*` |
|---|---|---|
| `quality`（format / analyze / 根测试 / 包测试 / `flutter build bundle`） | ✅ 跑 | ✅ 跑 |
| `external-samples`（需 `APPINFOTOOL_SAMPLES`） | ✅ 跑（无样本则显式跳过） | ✅ 跑 |
| `build-windows` / `build-macos` / `build-linux` | ✅ **真实编译**（仅「按 tag 改写 pubspec 版本号」那一步是 tag 专属，行 159/247/339） | ✅ 编译 + 打包 |
| `create-release` | ❌ | ✅ 建 Release + 传产物 |
| `publish-scoop` / `publish-homebrew*` | ❌ | 仅 `github.repository == 'huanfeng/ApkInfoTool'` 时跑 |

**评价**：main 上做**真实三平台编译**（不是只 analyze），这一点比多数项目强；把「版本号改写」单独 tag 化，是因为 main 上会把版本写成 `version: main` 而三平台全挂 —— 注释里写明了这个根因。fork 上打 tag 不会污染上游分发渠道，`if` 条件正确。

### 产物（本次实测）

`v2.4.1` 的 tag run **全部 job success**，Release 四个产物齐全：macOS universal dmg 32.4 MB、Windows Setup.exe / zip、Linux AppImage。

并且**把 dmg 拉下来验了内容**（CI 绿只说明「构建成功」，不说明「产物对」）：

```
CFBundleShortVersionString = 2.4.1
com.apple.security.files.user-selected.read-write = true   ← v2.4.1 的修复确实在产物里
com.apple.security.network.client = true
（无 com.apple.security.app-sandbox —— 与「刻意不开沙箱」一致）
```

这是**唯一**能验证平台侧配置的方式（仓库内的 `macos_entitlements_test.dart` 只能守源文件，守不住「构建时被覆盖」）。

### 文档

| 文档 | 状态 |
|---|---|
| `README.md` / `README_en.md` | 现行；有 `readme_consistency_test.dart` 守结构不变量（标题层级 / 代码块数 / 链接集合） |
| `CHANGELOG.md` | 现行；1.0 → 2.4.1 逐版本，含实测门禁表 |
| `docs/plans/V2.4.0_PROGRESS.md` | 3,000 行，**V2.4.0/V2.4.1 的唯一进度载体**，每阶段写验收条件 + 实测结果 |
| `docs/audit/*` | 5 份历史报告，其中 2 份明确标注「已过时（历史证据，保留不改正文）」并给出指向 |
| `docs/delivery/macos-build-and-signing.md` | 现行 |
| `docs/plans/2026-03-03-builtin-apk-parser-{design,plan}.md` | 上游遗留的设计/计划文档（见下） |

**文档纪律是加分项**：过时文档不删、标注后保留；「未实测」一律显式标注；CI 产物验证流程已固化。

---

## 八、缺口清单（按优先级）

### P1 — 建议尽快处理

**P1-1 日语 / 韩语只完成 34%（缺口 A）**
用户可见的成品度问题。README 的「六种界面语言」与现状不匹配。
→ 补 447 个高价值键（`security` / `ios_info` / `diff` / `coverage`），或改 README 措辞 + 语言选择器加「部分」标记。

**P1-2 解析器包内测试与其体量严重不匹配（缺口 B）**
`apk_parser` 8,916 行 → 486 行测试（5.5%）；`ipa_parser` 6,781 行 → 384 行（5.7%）。
→ 不要求搬走根测试（那 17,163 行是有效覆盖），但**至少给两个包补上「自己的入口测试」**：用 `test/fixtures/` 里的夹具把 `ApkReader` / `IpaContainer` 的公开入口各跑通一遍，让 `dart test` 在包内不再是空转。

### P2 — 应当处理

**P2-1 `ToolDownloader` 的校验和校验零测试（缺口 C-1）**
这是 2026-10-13 审计 T0-2 的修复本体，也是最容易被后人「重构掉」的地方。
→ 纯函数可测：`_parseChecksums`（解析 `<checksum type=...>`）、`ArchiveInfo.preferredAlgorithm`（SHA-256 优先、回退 SHA-1）、`_digestFile` 与「校验和不匹配即拒绝」的分支。

**P2-2 `ReportExporter` 零测试（缺口 C-2）**
v2.4.1 刚把它做成三态类型（saved / cancelled / failed），这是**纯逻辑**、**零 IO 依赖之外的分支清晰**，正是最该钉住的形状。
→ 至少断言：面板返回 `null` → `cancelled`（**不是** failed）；`ENTITLEMENT_REQUIRED_WRITE` → 走 `save_error_entitlement` 文案；其它 `PlatformException` → 走 `export_failed`。

**P2-3 `xapk_installer` 零测试**
原 Zip-Slip 现场。守卫（`ZipGuard.safeJoin`）有 9 个用例，但**调用方**（`installer` 是否正确地把每个条目都过了守卫）没有测试 —— 这正是「守卫很强但某条路径忘了调用」的典型风险。

### P3 — 可选 / 卫生

**P3-1 `riverpod_lint` 声明了但一条规则都没开**
`analysis_options.yaml` 末尾的 `plugins: riverpod_lint: ^3.1.0` 只声明了插件；注释明确写「此处暂不开启任何规则」。结果：装了不生效，等于零收益（此前 `analyzer.plugins: [custom_lint]` 的写法已被 Dart 废弃，改对了机制，但没开规则）。
→ 在 `plugins.riverpod_lint.diagnostics` 下逐条开（建议先开 `avoid_manual_providers_as_generated_provider_dependency` 这类不会大面积报错的）。

**P3-2 孤儿 i18n 键 `install.please_select_device`**
只在 `en.json` 存在且**代码未使用**，是「六个语言包键数不一致」的唯一来源。删掉即可完全对齐。

**P3-3 文档卫生：AI 提示词残留在计划文档里**
`docs/plans/2026-03-03-builtin-apk-parser-plan.md:2` 保留了 `> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.`。这是上游遗留，不影响功能，但作为对外仓库的文档不太合适。
→ 删掉那一行（正文是有效设计记录，不要删）。

**P3-4 `docs/plans/2026-03-03-*` 的定位**
这两份是**上游**的设计/计划文档，描述的 `BinaryXmlDecompressor` / `ZipHelper` 等已经不存在（代码已重构进 `packages/apk_parser`）。它们没有被标「已过时」。
→ 与另外两份过时文档同样处理：开头加一行「已过时，现状见 `V2.4.0_PROGRESS.md`」。

---

## 九、历史审计遗留项复核

2026-10-13 的安全审计提出 T0/T1/T2 三档。逐条复核现状：

| 项 | 原问题 | 现状 | 证据 |
|---|---|---|---|
| **T0-1** | Zip-Slip：恶意 XAPK 可向主机任意位置写文件 | ✅ **已修** | `lib/utils/zip_guard.dart:22-49` `safeJoin` 拒绝空名 / `/` / `~` / 盘符 / UNC / 任何 `..` 段，并复核 `path.isWithin`；`extractToDirectory` 越界**抛异常而非静默跳过**。调用方 4 处：`ipa_bundle_extractor.dart:162,176`、`xapk_installer.dart:163`、`tool_downloader.dart:330,354`、`zip_helper.dart:101`。**9 个用例**（`test/utils_test.dart:53-120`） |
| **T0-2** | 工具二进制零校验即执行 + 镜像优先级错误 | ✅ **已修**（但无测试，见 P2-1） | `tool_downloader.dart` `_parseChecksums`(471) / `_digestFile`(544) / `_verifyArchiveChecksum`(562) / `ToolDownloadError.checksumMismatch`(626)；`ArchiveInfo.preferredAlgorithm` 优先 `sha256` → `sha1` → `md5` |
| **T0-3**（质量门禁缺失） | 13,011 行 0 测试、CI 不含 analyze/test | ✅ **已修** | 现 1,220 用例；CI `quality` job 在 main 上就跑 format/analyze/根测试/包测试 |
| **解析器两份分叉副本** | 未加固的那份正被图标链路使用 | ✅ **已消除** | 全仓 `ArscParser` / `ManifestParser` / `BinaryXmlParser` 各**一处定义**，全在 `packages/apk_parser/lib/src/`；`lib/apkparser/*` 改为 `import 'package:apk_parser'` |
| **T2-15** | Windows 声明支持文件关联但实现只在 macOS 分支后 | ✅ **已修** | `file_association.dart:8` `isSupported => Platform.isWindows \|\| Platform.isMacOS`，`openDefaultAppsSettings` 按平台分 URI（`ms-settings:defaultapps` / `x-apple.systempreferences:...`） |

**结论：2026-10-13 审计的高优先级项已全部关闭，且大部分有测试守着。** 这轮完整度审计没有发现新的高严重度安全问题。

---

## 十、建议的下一步

按性价比排序（都不需要动核心解析逻辑）：

1. **i18n 补 447 个键**（P1-1）—— 纯翻译，无代码风险，收益最大（直接消掉最大的成品度缺口）。
2. **给两个解析器各补一个「包内入口测试」**（P1-2）—— 让 `dart test` 在包内不再是空转。
3. **补 3 个测试文件**：`tool_downloader_test.dart`（校验和）、`report_exporter_test.dart`（三态）、`xapk_installer_test.dart`（守卫调用完整性）—— 覆盖三处「安全/新修但零测试」的代码。
4. **清 3 处卫生问题**：孤儿 i18n 键、`riverpod_lint` 开规则、计划文档里那行 AI 提示词 + 给上游遗留文档加过时标注。
5. （可选）**建立「发布后验产物」的固定动作** —— 本次已经做过一次（下载 dmg → `codesign -d --entitlements` → 核对版本号与授权），建议写进 `docs/delivery/`，作为 tag 发布后的收尾步骤。这是唯一能发现「平台侧配置在构建时被覆盖」的手段。

---

## 附：本报告用到的实测命令

```bash
# 规模（排除生成物与 gitignore 的文件）
git ls-files -co --exclude-standard '*.dart' | xargs wc -l

# 门禁（不接管道，避免退出码被 tail 换成 0）
dart format --output=none --set-exit-if-changed $(git ls-files -co --exclude-standard '*.dart')
flutter analyze --fatal-infos --fatal-warnings
flutter test                                     # NO_PROXY=127.0.0.1,localhost,::1
for pkg in packages/*/; do (cd $pkg && dart analyze --fatal-infos --fatal-warnings && dart test); done

# i18n 键数对齐（按组）
python3 -c "…flatten 六个 json，比较键集合…"

# 零测试模块
for m in report_exporter tool_downloader zip_guard …; do grep -rl "$m" test/ | wc -l; done

# 产物实测（tag 发布后）
hdiutil attach -nobrowse -readonly -quiet <dmg>
codesign -d --entitlements :- "/Volumes/AppInfoTool <ver>/AppInfoTool.app"
/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "…/Contents/Info.plist"
hdiutil detach -quiet "/Volumes/AppInfoTool <ver>"
```

---

*本报告只读审计，未修改任何生产代码。*
