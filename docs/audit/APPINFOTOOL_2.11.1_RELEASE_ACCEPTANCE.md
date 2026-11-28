# AppInfoTool 2.11.1 发布验收（GO / NO-GO）

日期：2026-11-28
代码基线：`main` @ `273490e`（此后仅追加文档与 `tool/verify`，不改产品代码）
任务书：`docs/audit/APPINFOTOOL_2.11.1_REMEDIATION_BASELINE.md` 所述五阶段整改

## 1. 门禁逐条判定

| # | 任务书要求 | 证据 | 判定 |
| --- | --- | --- | --- |
| 1 | `main` 含全部整改 | `f996a71` 合并 + `9012032` / `9ec88c3`…`273490e`；`origin/main` 与本地一致 | **PASS** |
| 2 | 真实样本在 CI 里**真实执行** | `samples/` 为空；`external-samples` job 通过原因是「显式跳过」；20 个真实样本测试 skip | **FAIL** |
| 3 | 无长期豁免（文件/变量） | `.github/allow-no-samples` 已删除；本地复现 tag 门禁 → `BLOCKED: tag without samples`（exit 1） | **PASS** |
| 4 | Windows / Linux 实机验收 | 无实机；CI 只做构建 + 冒烟；迁移档案无人工验收记录 | **FAIL** |
| 5 | ja / ko 缺键清零 | 146 键补齐；`i18n_coverage_test` 全量键集一致、无英文复制、占位符一致 | **PASS** |
| 6 | 报告 schema 与界面一致 | schema v11：权限分级、库识别、包内证书字段均落盘；契约 `analysis-report-v11.schema.json` | **PASS** |
| 7 | `v2.11.0` tag 不动 | `v2.11.0^{commit}` = `cfcbaa5`，tag 对象未改 | **PASS** |
| 8 | 测试不跳、不 mock | 根 2011 passed / 20 skipped（skip 全部为真实样本，原因列出）；包 310 + 777 passed | **FAIL（第 2 条同因）** |
| 9 | CI 绿 | `a9a04b9` 运行 `46145043813` success；`273490e` 运行 `46146363896` 作业全部 success | **PASS** |
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
| 真实样本从未在 CI 执行 | 解析正确性只由合成夹具保证；加固/畸形包行为未知 | `samples/` 为空；需放入真实样本后删跳过逻辑 |
| Windows / Linux 未实机验收 | 缩略图、文件关联、安装器注册、AppImage 在真实桌面环境的行为未确认 | 无实机；CI 只构建 + 冒烟 |
| iOS 真机安装未 E2E | `.ipa` 安装链路只有单测与注入替身 | 本机无 `ideviceinstaller`、无设备 |
| 历史「重开」不读快照 | 历史条目无法原样复现上次结论，只能重新解析 | 见第五阶段文档「历史重开」 |
| Network Clues 噪声 | 混淆 DEX 上出现 `:C:` 这类伪线索，信噪比差 | 线索扫描缺最小长度/字符集约束 |
| macOS ad-hoc 签名 | 用户首次打开需手动放行，分发体验差 | 无 Developer ID 证书 |
| AOT 内存未测 | 第四阶段 RSS 只代表 flutter_tester | 需交互式采样发布包 |

## 4. 最终判定

**NO-GO（不可作为 2.11.1 正式发布）。**

理由：门禁 2、4、8 未通过 —— 真实样本从未在 CI 执行、Windows/Linux 无实机验收、
因此「不跳测试」这条也未满足。代码质量与功能本身达到可交付水平（阶段一至三、五
均 PASS，阶段四本地部分无回退），但按任务书自己的标准，现在发版就是把 2.11.0
的豁免问题换个形式重演。

### 转为 GO 所需的最小动作

1. 放入至少 1 份真实 APK + 1 份真实 IPA 到 `samples/`（或在 CI 里从制品下载），
   确认 `real_samples_test.dart` 不再 skip；
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
