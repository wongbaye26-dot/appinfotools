# AppInfoTool 2.11.1 发布验收（GO / NO-GO）

日期：2026-11-28
代码基线：`main` @ `222bbbb`（产品代码止于 `273490e`；此后为样本门禁与 CI 修复）
任务书：`docs/audit/APPINFOTOOL_2.11.1_REMEDIATION_BASELINE.md` 所述五阶段整改

## 1. 门禁逐条判定

| # | 任务书要求 | 证据 | 判定 |
| --- | --- | --- | --- |
| 1 | `main` 含全部整改 | `f996a71` 合并 + `9012032` / `9ec88c3`…`273490e`；`origin/main` 与本地一致 | **PASS** |
| 2 | 真实样本在 CI 里**真实执行** | `test/samples/manifest.json` 固定两个可再分发的 F-Droid 真实 APK（url + sha256）；`external-samples` 自动下载校验后真实执行（CI 运行 `46148768077` success）；**iOS 无公开 `.ipa`，门禁按平台收窄为 `android` 并打印 warning** | **PARTIAL（Android PASS / iOS 未覆盖）** |
| 3 | 无长期豁免（文件/变量） | `.github/allow-no-samples` 已删除；本地复现 tag 门禁 → `BLOCKED: tag without samples`（exit 1） | **PASS** |
| 4 | Windows / Linux 实机验收 | 无实机；CI 只做构建 + 冒烟；迁移档案无人工验收记录 | **FAIL** |
| 5 | ja / ko 缺键清零 | 146 键补齐；`i18n_coverage_test` 全量键集一致、无英文复制、占位符一致 | **PASS** |
| 6 | 报告 schema 与界面一致 | schema v11：权限分级、库识别、包内证书字段均落盘；契约 `analysis-report-v11.schema.json` | **PASS** |
| 7 | `v2.11.0` tag 不动 | `v2.11.0^{commit}` = `cfcbaa5`，tag 对象未改 | **PASS** |
| 8 | 测试不跳、不 mock | 根 2011 passed / 20 skipped；样本门禁改为「按平台要求」后 Android 侧真实执行，iOS 侧仍显式标注未覆盖；包 310 + 777 passed | **PARTIAL（iOS 侧仍缺样本）** |
| 9 | CI 绿 | `a9a04b9` 运行 `46145043813` success；`273490e` 运行 `46146363896` 作业全部 success；`222bbbb` 运行 `46148768077` success（样本门禁真实执行） | **PASS** |
| 10 | 核心分析能力可复现 | 第五阶段真实 APK 端到端核验：Finding/Evidence/Coverage/Artifact/Graph/Network/权限/库/证书全部落盘 | **PASS（两项已知限制）** |

## 2. 各阶段结论

| 阶段 | 内容 | 结论 | 证据 |
| --- | --- | --- | --- |
| 一 | 只读审计 12 项 | PASS | `APPINFOTOOL_2.11.1_REMEDIATION_BASELINE.md` |
| 二 | 发布流程整改 | PASS | 合并 `f996a71`、门禁恢复 `9012032`、验收档案第 9 节 |
| 三 | 功能补齐 A/B/C/D | PASS | `9ec88c3` / `2b3d76a` / `d8a59f3` / `a8cbdc3`；2011 + 310 tests |
| 四 | 验证与性能（本地部分） | **PARTIAL** | `APPINFOTOOL_2.11.1_PHASE4_VERIFICATION.md`：耗时/内存在噪声内无回退；真机项未验证 |
| 五 | 核心能力专项核验 | PASS（带限制） | `APPINFOTOOL_2.11.1_PHASE5_CORE_CAPABILITIES.md` |

## 3. 未解决风险

| 风险 | 影响 | 触发条件 / 现状 |
| --- | --- | --- |
| iOS 真实样本未在 CI 执行 | Android 侧已由两个固定 SHA-256 的公开 APK 覆盖（运行 `46148768077`）；iOS 端到端仍只有单测 | 无公开可再分发的 `.ipa`；门禁按平台收窄为 `android` 并 warning |
| Windows / Linux 未实机验收 | 缩略图、文件关联、安装器注册、AppImage 在真实桌面环境的行为未确认 | 无实机；CI 只构建 + 冒烟 |
| iOS 真机安装未 E2E | `.ipa` 安装链路只有单测与注入替身 | 本机无 `ideviceinstaller`、无设备 |
| 历史「重开」不读快照 | 历史条目无法原样复现上次结论，只能重新解析 | 见第五阶段文档「历史重开」 |
| Network Clues 噪声 | 混淆 DEX 上出现 `:C:` 这类伪线索，信噪比差 | 线索扫描缺最小长度/字符集约束 |
| macOS ad-hoc 签名 | 用户首次打开需手动放行，分发体验差 | 无 Developer ID 证书 |
| AOT 内存未测 | 第四阶段 RSS 只代表 flutter_tester | 需交互式采样发布包 |

## 4. 最终判定

**NO-GO（不可作为 2.11.1 正式发布）。**

理由：门禁 4 未通过（Windows/Linux 无实机验收），门禁 2、8 只完成 Android 半边
—— CI 现在会用两个固定 SHA-256 的公开真实 APK 真实执行样本测试，但 iOS 侧没有
可再分发的真实 `.ipa`，`APPINFOTOOL_REQUIRED_SAMPLE_PLATFORMS` 因此收窄为
`android` 并在日志里 warning。代码质量与功能本身达到可交付水平（阶段一至三、五
均 PASS，阶段四本地部分无回退），但按任务书自己的标准，iOS 端到端未验证就发版，
仍然是把「没验证」当成「通过」。

### 转为 GO 所需的最小动作

1. ~~Android 真实样本进 CI~~ 已完成：`test/samples/manifest.json` + 自动下载校验，
   `real_samples_*` 与 `sample_regression_test` 在 CI 真实执行（运行 `46148768077` success）；剩余 iOS 侧需
   至少 1 份可再分发的真实 `.ipa`，并把 `APPINFOTOOL_REQUIRED_SAMPLE_PLATFORMS`
   改回 `android,ios`；
2. 在 Windows 11 与 Ubuntu 24.04 实机各跑一遍安装、打开、导出、安装到设备
   （Android；iOS 可标注未验证），把结果写回本文件的「实机验收」小节；
3. 重跑全量测试，确认 skipped 只剩「本机确实无法执行」的项；
4. 用新 commit 打 `v2.11.1` tag，确认 `external-samples` 真实执行且 `create-release` 成功。

以上 1–3 完成后，本文件改为 **GO**，并附 CI 运行号与实机记录。

## 5. 本次整改已确认的改进（相对 2.11.0）

- `main` 与发布内容一致，不再出现「发布在分支、主干落后 38 提交」。
- 豁免不再是文件式长期开关：删掉文件后，无样本的 tag 会直接失败。
- 验收档案与实际发布记录对齐（2.11.0 标为 CONDITIONAL GO 并写明条件）。
- ja/ko 由「整组回退英文」变为全量键集一致，且有测试防回归。
- AAB 从「只有包名版本」变为权限/特性/组件/compileSdk 可用。
- 报告 v11 把权限分级、库识别、包内证书字段纳入可复现导出。
