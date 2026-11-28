# AppInfoTool 2.10.7 — Stage D 验收报告（真实样本 E2E）

## 1. 范围与结论

- 阶段：D（P1-2 真实样本 E2E）。
- 起点 commit：`5c4db5a`（v2.10.6，工作区带 Stage A/B/C 未提交改动）。
- 本阶段结论：**样本选择、通用冒烟、发布门禁三件事已完成**；原有 2 条真实样本 UI 失败已消除。
- 但发布门禁当前**不满足**：本机语料只有 4 个 IPA、0 个 APK，真实 Android E2E 未执行；按新门禁，缺 APK 时发布 tag 会被阻断。这是有意为之，不是静默跳过。
- 未提交、未移动 tag、未发布。

## 2. P1-2 对照

| 要求 | 实现 |
| --- | --- |
| 修复样本选择器脆弱问题 | `test/real_samples_ui_test.dart` 不再用 `_firstSample` 给特性断言选样。IPA 组在 `setUpAll` 中解析目录内**全部** IPA，再用 `findByState` 按**已观察到的能力**选择：codesign 可执行、图标候选、未解析图标、`ios.nested.truncated` 诊断。 |
| 禁止依赖文件名排序选特殊样本 | 特性样本选择只依据解析结果的能力，不依赖 `list.first` 或路径排序；`_firstSample` 仅保留给「任意样本都能做」的通用字段断言。 |
| 能力缺失时不得静默通过 | 某项能力在语料中不存在时，用 `markTestSkipped('...该分支未验证')` 显式跳过并打印原因，不把空白断言当成通过。 |
| 增加通用真实样本解析/报告渲染冒烟 | 新增 `test/real_samples_smoke_test.dart`：逐样本解析，生成 Markdown 与 JSON 报告，`jsonDecode` 后检查 `reportSchemaVersion` 和 `inputArtifact`；不依赖样本特有字段。 |
| 真实样本纳入发布依赖 | `.github/workflows/build.yml` 的 `create-release` 新增 `needs: external-samples`，条件要求 `needs.external-samples.result == 'success'`。 |
| 无样本必须阻断或显式豁免 | 新增 `真实样本发布门禁` 测试：`APPINFOTOOL_REQUIRE_SAMPLES=1` 时缺样本直接失败；CI 在发布 tag 未配置样本且未设 `APPINFOTOOL_ALLOW_NO_SAMPLES=1` 时直接 fail。普通 PR/main 允许显式警告后跳过。 |

## 3. 修改文件

修改：

- `test/real_samples_ui_test.dart`：能力型选样、显式 skip 原因、codesign 平台缺失时跳过而不是硬失败。
- `.github/workflows/build.yml`：`external-samples` 增加 `APPINFOTOOL_SAMPLES`/`APPINFOTOOL_ALLOW_NO_SAMPLES`；新增样本门禁步骤；测试列表加入 smoke；`create-release` 依赖并检查 `external-samples`。
- `README.md`、`README_en.md`：补充真实样本门禁说明。

新增：

- `test/real_samples_smoke_test.dart`：通用解析 + Markdown/JSON 报告冒烟；含“要求样本时不得静默跳过”的门禁测试。

未修改生产解析/安全代码。

## 4. 实际命令与结果

语料：`/Users/wangbaye/Projects/ipa`，25 个文件，**4 IPA / 0 APK**。

### 4.1 真实样本测试（配置样本）

命令：

```sh
APPINFOTOOL_SAMPLES=/Users/wangbaye/Projects/ipa \
  flutter test test/real_samples_test.dart \
    test/real_samples_ui_test.dart \
    test/real_samples_smoke_test.dart
```

结果：**10 pass / 10 skip / 0 fail**。

- 修复前同一语料上的 UI 结果是 8 pass / 7 skip / **2 fail**（两条都因按文件名选到 `95-v1.8.7.ipa`）。
- 现在：
  - iOS 能力测试通过：嵌套截断样本按能力选中并渲染诊断；
  - 「未解析图标」分支因语料中没有含未解析图标的 IPA，显式 skip；
  - 所有 4 个 IPA 都完成解析，通用 Markdown/JSON 报告能生成并解码；
  - Android 组因 0 个 APK 显式 skip，并给出具体原因。

### 4.2 门禁行为验证

```sh
# 无样本 + 要求样本 → 必须失败
APPINFOTOOL_REQUIRE_SAMPLES=1 flutter test test/real_samples_smoke_test.dart
# 结果：失败，reason 为「样本目录不可用」/「缺少 Android 样本」

# IPA-only + 要求样本 → 必须失败，不能当成真实样本门禁通过
APPINFOTOOL_SAMPLES=/Users/wangbaye/Projects/ipa APPINFOTOOL_REQUIRE_SAMPLES=1 \
  flutter test test/real_samples_smoke_test.dart
# 结果：失败，缺少 Android（.apk / .xapk / .apkm / .apks）样本

# 不要求样本 → 显式 skip，不是通过
flutter test test/real_samples_smoke_test.dart
# 结果：3 skipped，原因明示本地显式豁免
```

### 4.3 全量回归

| 检查 | 结果 |
| --- | --- |
| `flutter test`（无外部样本） | **1,865 pass / 19 skip / 0 fail** |
| 五个 package 测试 | **142 + 226 + 250 + 40 + 25 = 683 pass** |
| `flutter analyze --fatal-infos --fatal-warnings` | No issues found |
| `dart format --output=none --set-exit-if-changed .` | 451 files, 0 changed |
| `flutter build bundle` | exit 0 |

root skip 从 16 增至 19，增量是新增 smoke 的 Android、iOS 与门禁三条显式 skip。

## 5. 未执行项与遗留

1. **真实 Android E2E 未执行**：语料里没有 APK/XAPK/APKM/APKS。新增门禁在要求样本时会把这件事变成失败；本阶段无法提供 Android 真实样本证据。
2. **「未解析图标」真实分支未执行**：4 个 IPA 的图标都被解析，未解析列表为空；该分支用显式 skip 记录，未伪造通过。
3. **CI 样本来源未配置**：GitHub-hosted runner 上没有 `APPINFOTOOL_SAMPLES` 目录。需要仓库变量指向 runner 可读目录（例如自托管 runner），或在下一次发布前设置 `APPINFOTOOL_ALLOW_NO_SAMPLES=1` 做显式豁免；当前状态是**发布被阻断**。
4. 三平台安装/运行验收未执行（Stage E 范围）。
5. 未提交、未打 tag、未发布。

## 6. 验收判定

- P1-2 的工程整改：**完成**（能力选样、通用冒烟、发布依赖、显式阻断/豁免）。
- 真实样本门禁：**当前未通过**——缺 Android 样本，且 CI 尚无样本来源。因此本阶段**不能**声称“真实样本 E2E 已绿”，发布结论仍为 **NO-GO**。
- 下一阶段：E（三平台运行验收与 CI 门禁），需人工确认本报告后开始。

## 7. Stage G 后续补充（本地临时混合语料）

Stage D 时样本目录只有 4 个 IPA、0 个 APK；Stage G 收尾时补用本机 2 个 APK 组成临时混合语料，重新执行了真实样本套件。本节是补充证据，不改变 Stage D “CI 样本源未配置”的结论。

- 临时语料：`/tmp/appinfotool-samples`，4 个 IPA + 2 个 APK，共 6 个文件。APK 来自本机 Downloads，未加入仓库。
- 首次运行：**16 passed / 1 skipped / 3 failed**。3 个失败均在 Android 版本对比组，原因是测试夹具硬编码了旧样本的规模/文件名，不是解析器崩溃：
  - 断言 `android.permissions` 至少 30 条，实际样本只有 10 条；
  - 差异页断言文件名 `hardened.apk` / `hardened-v1.apk`，实际样本名是 `217_0919155004.apk` / `狐...apk`。
- 修复方式：按样本实际的权限集合数量比较；按真实样本 basename 与一个合成对比名生成路径；不降低“空集合不能算通过”的要求。修复后：
  - `APPINFOTOOL_SAMPLES=/tmp/appinfotool-samples APPINFOTOOL_REQUIRE_SAMPLES=1 flutter test test/real_samples_test.dart test/real_samples_ui_test.dart test/real_samples_smoke_test.dart`
  - **19 passed / 1 skipped / 0 failed**（skip 为“图标存在但未解析”真实分支，当前 4 个 IPA 均无该特征）。
- 这证明了 Android 真实解析/详情/差异/报告路径可跑通；但仍**不是**发布门禁闭环：语料在 `/tmp`、不在仓库，CI 未配置样本源，且真实 Android 仅 2 个样本。Stage D 的发布阻断结论仍然有效。
