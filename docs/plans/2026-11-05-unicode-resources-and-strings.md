# Unicode 覆盖边界：Android resources/assets + iOS .strings

> **日期**：2026-11-05｜**状态**：已实现，门禁全绿
> **性质**：只补扫描范围，不改变“话术只是线索、不是判决”的口径

---

## 1. Android：resources.arsc + 文本 assets

新增 `packages/apk_parser/lib/src/security/resource_unicode_phrases.dart`：

- 复用 `unicodePhraseMarkers` 与 `shouldReport` 密度门槛；
- 从 `resources.arsc` 全局字符串池 + 文本型 `assets/**` 收集字符串；
- 产出独立元发现项 `ANDROID-RESOURCE-UNICODE-PHRASE`（`info` + `isMeta`）；
- 证据来源标 `other`，location 写 `resources.arsc` / assets 路径；
- 文案 code：`android.resource_unicode_phrase` / `.review` / `.limitation`。

接线：

- `AndroidSecurityAudit.audit` 新增 `resourceStrings`；
- `parse_task` 从 `arscParser.globalStringPool.strings` 读取；
- assets 只读文本型扩展名、单文件 ≤2 MiB、最多 64 个、总字符 ≤2M；
- 二进制资源/原生库/运行时文案仍明确不在范围内。

## 2. iOS：.strings / 本地化文件

新增 `packages/ipa_parser/lib/src/security/ios_strings_unicode.dart`：

- 输入 `IosStringsFile(path, bytes)`；
- UTF-8 + UTF-16 LE/BE × 偶/奇对齐解码，只保留含 CJK 的候选；
- 复用同一张话术表与密度门槛；
- 产出 `IOS-STRINGS-UNICODE-PHRASE`（`info` + `isMeta`）；
- 文案 code：`ios.strings_unicode_phrase` / `.review` / `.limitation`。

接线：

- `IosPrivacyAudit.audit` 新增 `stringsFiles`；
- `IpaAnalysisReader` 从归档读取 `.strings`：单文件 ≤1 MiB、最多 64 个、总量 ≤8 MiB；
- Swift 小字符串、二进制 plist、运行时文案仍不在范围内。

## 3. i18n

新增 6 个语言包键（en / zh-CN / zh-HK / zh-TW / ja / ko），
`analysis_report.dart` 增加 message / recommendation / limitation 三分支。

## 4. 门禁

| 项 | 结果 |
|---|---|
| 根项目 `flutter test` | **1,769 通过 / 15 跳过 / 0 失败** |
| 根项目 `flutter analyze` | No issues found |
| `analysis_model` | 141 通过 |
| `apk_parser` | 216 通过 |
| `ipa_parser` | 239 通过 |
| `archive_safety` / `app_icon_extractor` | 40 / 25 通过 |
| `dart format` | 403 files，0 changed |

新增测试：

- `packages/apk_parser/test/resource_unicode_phrases_test.dart`
- `packages/ipa_parser/test/ios_strings_unicode_test.dart`

## 5. 仍未覆盖

- Android：二进制 assets、原生库、加固壳层、运行时下发/拼接文案；
- iOS：Swift 小字符串、二进制 plist、运行时下发/拼接文案、dyld 共享缓存；
- 两种扫描都只产出 info 元线索，不改变盗 U 五段链判级。
