# AppInfoTool 2.10.7 — Stage A（iOS FairPlay 加密识别）阶段验收报告

- 阶段：A（仅 Stage A；B–G 未开始）
- 基线版本：2.10.6
- 起点 commit：`5c4db5a chore(release): 2.10.6`
- 起点 tag：`v2.10.6`
- 当前工作区：Stage A 修改尚未提交（无新 commit、无新 tag）
- 任务来源：`docs/audit/2026-11-27-module-completeness-audit.md` P1-1；用户 2.10.7 任务书
- 验收状态：**本阶段实现完成，等待人工验收后进入 Stage B**

## 1. 本阶段解决的问题

审计 P1：App Store 下发的 IPA 常见 `LC_ENCRYPTION_INFO(_64)` 且 `cryptid == 1`，主可执行文件 `__TEXT` 是密文。旧实现只按「可执行字节存在」判断，`IOS-RULE-F` 可能给出 `confirmed` 的「未发现上传特征」，覆盖率也仍说“每个可执行文件都覆盖”，会让读者把“密文里看不到”误读成“没有”。

本阶段把 FairPlay 加密变成**正式可见的分析范围**：

- 解析两种 `LC_ENCRYPTION_INFO` 命令，保留 `cryptoff/cryptsize/cryptid`；
- 在 Mach-O / IPA 分析模型中暴露加密状态；`null` 明确表示“没有可读命令”，不是“确认未加密”；
- `cryptid == 1` 时降级相关静态否定结论（`IOS-RULE-F` 及 crypto-theft 证据链的覆盖完整性）；
- 新增结构化覆盖维度 `ios.encryption`；
- 报告与 UI 同步展示“看到的是密文”的范围说明；
- 用合成 Mach-O 测试固定行为。

## 2. 修改文件清单

### 生产代码

| 文件 | 改动 |
| --- | --- |
| `packages/ipa_parser/lib/src/macho.dart` | 新增 `MachOEncryptionInfo`；`MachOImage.encryption`；解析 `_lcEncryptionInfo = 0x21` / `_lcEncryptionInfo64 = 0x2C` |
| `lib/ipaparser/ipa_analysis.dart` | 新增 `mainEncryption` / `isMainEncrypted` / `encryptedExecutablePaths` / `hasEncryptedExecutable` |
| `packages/ipa_parser/lib/src/security/ios_privacy_audit.dart` | 扫描时收集 cryptid；新增 `IOS-ENCRYPTED-BINARY`；`IOS-RULE-F` 加密降级；`IOS-SCAN-COVERAGE` 加密措辞；新增 `ios.encryption` 覆盖维度；crypto chain 传入 `encryptedBinary` |
| `packages/ipa_parser/lib/src/security/ios_crypto_theft_chain.dart` | `assess` 新增 `encryptedBinary`，计入 `coverageIncomplete` 与 `blindSpots` |
| `lib/utils/analysis_report.dart` | 新 code 的 finding / limitation / recommendation / 覆盖维度 / 覆盖说明本地化分发 |
| `lib/widgets/security_notice_banner.dart` | 新增信息性范围提示组件（非错误色） |
| `lib/pages/info_page.dart` | iOS 详情页在平台行后展示 FairPlay 范围提示 |
| `assets/i18n/{en,zh-CN,zh-TW,zh-HK,ja,ko}.json` | 新增加密相关文案（6 种语言均实际翻译） |

### 测试

| 文件 | 改动 |
| --- | --- |
| `packages/ipa_parser/test/macho_encryption_test.dart` | 新增 5 个合成 Mach-O 解析测试 |
| `test/ios_privacy_audit_test.dart` | 新增 4 个 FairPlay 审计/本地化测试 |
| `test/ios_detail_page_test.dart` | 新增 2 个 UI 提示测试 |
| `test/analysis_report_test.dart` | 新增 1 个 JSON/Markdown 序列化测试 |
| `test/analysis_coverage_test.dart` | 覆盖说明参数超集补 `cryptid` |
| `test/coverage_note_registration_test.dart` | 覆盖说明参数超集补 `cryptid` |

### 生成物

- `dart run build_runner build --delete-conflicting-outputs` 重新生成 `lib/gen/strings*.g.dart`。该目录在 `.gitignore` 中，不进入提交；CI/本地构建时会重新生成。

## 3. P1-1 对照

| 任务书要求 | 实现与证据 | 状态 |
| --- | --- | --- |
| 解析 `LC_ENCRYPTION_INFO` / `_64` | `macho.dart` 两种命令均解析，5 个合成测试覆盖 `_64`、32 位命令号、`cryptid=0`、无命令、`cmdsize` 过短 | 完成 |
| 将 cryptid 纳入正式分析模型 | 解析层 `MachOEncryptionInfo` / `MachOImage.encryption`；IPA 层 `IpaAnalysis.mainEncryption` 等；审计结果以结构化 finding（`IOS-ENCRYPTED-BINARY`，args 含 cryptid/count/path）+ `ios.encryption` coverage 输出，并经报告 JSON 序列化 | 完成（见 §6 设计说明） |
| `cryptid=1` 时相关静态否定结论降级 | `IOS-RULE-F` → `unknown` + `ios.rule_f_encrypted`；`IOS-SCAN-COVERAGE` 不再说“每个都覆盖”；crypto-theft `coverageIncomplete=true`、blind spot `encryptedBinary` | 完成 |
| 覆盖模型正确表达加密内容不可完整分析 | 新维度 `ios.encryption`：主应用加密 `notCovered`、仅嵌套加密 `partial`、`cryptid=0` `covered`、无命令 `notApplicable`；`hasActualGaps=true` | 完成 |
| UI 与报告同步展示 | 报告有 finding/coverage/本地化文本；iOS 详情页有 `SecurityNoticeBanner`（主/嵌套加密均提示，显示数量） | 完成 |
| 增加合成测试 | 见 §2；真实 FairPlay IPA 不在 CI 中，未伪称已用真实样本验证 | 完成（合成） |

## 4. 实际执行命令与结果

### 4.1 针对性测试

```text
~/development/flutter/bin/flutter test packages/ipa_parser/test/macho_encryption_test.dart
→ 5 passed

~/development/flutter/bin/flutter test \
  test/ios_privacy_audit_test.dart \
  test/ios_detail_page_test.dart \
  test/analysis_report_test.dart \
  test/security_finding_code_registration_test.dart \
  test/coverage_note_registration_test.dart
→ 121 passed
```

其中：`ios_privacy_audit_test.dart` 58、`ios_detail_page_test.dart` 14、`analysis_report_test.dart` 41、两个注册守卫 8。

### 4.2 全量回归

```text
~/development/flutter/bin/flutter test
→ 1850 passed / 16 skipped / 0 failed（exit 0）
```

基线为 1,843 / 16；本阶段净增 7 个测试，无删测、无新增 skip。

```text
(cd packages/analysis_model && flutter test)        → 141 passed
(cd packages/apk_parser && flutter test)            → 226 passed
(cd packages/ipa_parser && flutter test)            → 250 passed（含新增 5）
(cd packages/archive_safety && flutter test)        → 40 passed
(cd packages/app_icon_extractor && flutter test)    → 25 passed
→ 包测试合计 682 passed
```

### 4.3 静态检查与构建

```text
~/development/flutter/bin/flutter analyze --fatal-infos --fatal-warnings
→ No issues found!

~/development/flutter/bin/dart format --output=none --set-exit-if-changed .
→ 445 files, 0 changed

~/development/flutter/bin/flutter build bundle
→ exit 0
```

### 4.4 未执行项

- **真实 FairPlay IPA 样本**：本机默认样本目录没有 FairPlay 加密 IPA；本阶段只做了合成 Mach-O/合成审计测试。真实样本 E2E 属于 Stage D，未伪称通过。
- **三平台安装/运行验收**：属于 Stage E，未执行。
- **外部真实样本门禁**：属于 Stage D，未执行。

## 5. 关键行为证据

1. `cryptid=1` 主可执行：
   - `IOS-RULE-F` confidence = `unknown`，messageCode = `ios.rule_f_encrypted`，limitation = `ios.rule_f.limitation_encrypted`；
   - `IOS-ENCRYPTED-BINARY` 为 info / confirmed / isMeta；
   - `ios.encryption` = `notCovered`，noteCode = `ios.encryption.encrypted`；
   - `hasActualGaps = true`；
   - crypto-theft `missing` 带 `coverageIncomplete == true`。
2. `cryptid=0`：仍按明文扫描，`ios.encryption = covered`，不产生加密 finding，不制造缺口。
3. 仅嵌套可执行文件加密：`ios.encryption = partial`，`IOS-RULE-F` 仍降级，提示数量。
4. 报告：`reportSchemaVersion` 仍为 8；JSON 含 `IOS-ENCRYPTED-BINARY` 与 `"id": "ios.encryption"`；Markdown 使用本地化文案。
5. 中文界面：finding 与 coverage note 均中文，无未替换占位符。

## 6. 设计说明与边界

- **不新增 `SecurityAnalysisResult` 顶字段 / 不升 schema**：FairPlay 信息通过（a）`MachOImage.encryption` 正式解析模型、（b）结构化 meta finding `IOS-ENCRYPTED-BINARY`（`messageArgs` 含 cryptid/count/path）、（c）`ios.encryption` 覆盖维度进入报告。这样旧报告与 v8 消费方仍兼容。
  - 若验收要求新增强类型顶字段（如 `security.encryption`），需要 schema v9 与旧报告迁移；当前未做。
- `MachOEncryptionInfo` 的 `null` 只表示“没有可读命令”，不是“确认未加密”；`cryptid == 0` 才是明确已解密。
- 当前按 `cryptid == 1` 认定 FairPlay 加密；Apple 当前语义为 0/1，其他值保留未分类。若未来出现其他值，需要按“未知/不可当明文”扩展。
- 被预算截断、根本没打开的嵌套可执行文件仍由 `ios.executables` 覆盖表达；本阶段未改变其语义。

## 7. 遗留问题

1. 真实 FairPlay IPA 的端到端验证未执行（Stage D 处理）。
2. `IOS-SCAN-COVERAGE` 新增 `ios.scan_coverage_encrypted`，已注册报告分发；但真实样本中同一 IPA 同时存在“加密 + 截断”的组合形态尚未有真实样本验证（合成测试覆盖了单因）。
3. `SecurityAnalysisResult` 未加强类型 encryption 字段；如产品要求“正式模型必须强类型字段”，需另立 schema 变更任务。
4. 无 commit、无 tag、未发布；Stage B–G 未开始。

## 8. 阶段结论

- **Stage A：PASS（待人工确认）**。P1-1 的解析、降级、结构化覆盖、报告/UI 展示与合成测试均有实际证据；全量回归、静态检查、格式检查、bundle 构建均通过。
- **发布建议：NO-GO**。2.10.7 的 P1-2 至 P1-7 尚未实施；真实样本门禁与三平台运行验收尚未执行。按任务书，不得在本轮自动发布或移动 tag。
- 请确认是否接受 Stage A；接受后再进入 Stage B（Android Artifact/LoadGraph 与覆盖模型）。
