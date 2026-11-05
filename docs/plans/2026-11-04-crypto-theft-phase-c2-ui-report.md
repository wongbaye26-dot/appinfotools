# 盗 U 检测能力 — Phase C-2 界面 / 报告实现报告

> **状态**：Phase C-2（UI + 报告 + i18n）**已实现并通过根项目回归**（2026-11-04）
> **依赖**：Phase C-1 评估引擎（`SecurityAnalysisResult.cryptoTheft`）
> **范围**：安全 Tab 的五段链卡片、Markdown `## 盗 U 风险`、JSON `security` 对象 + schema v8、i18n
> **未做**：iOS 审计后台化、Phase B 事实接入 `parse_task`/`ipa_parse_task`、10 条新规则 finding、Phase D/E
> **纪律**：未新增依赖；未执行样本；未联网

---

## 0. 结论

现在用户**能看见**盗 U 评估了：

- 安全 Tab 顶部出现「盗 U 风险」五段链卡片（能力/来源/注入/载荷/官方基线 + 缺失环节 + 下一步）；
- Markdown 报告新增 `## 盗 U 风险` 小节，与 JSON 同源；
- JSON 新增顶层 `security` 对象（`cryptoTheft` 有值，其余四个键在 D/E 前为 `null`），`reportSchemaVersion` 升到 **8**；
- 新文案进入 `theft` 分组，四种完整语言（en / zh-CN / zh-TW / zh-HK）齐全；ja/ko 按既有策略回退英文。

| 验证项 | 结果 |
|---|---|
| 根项目 `flutter analyze` | **No issues found** |
| 根项目 `flutter test` | **1,746 通过 / 15 跳过 / 0 失败** |
| 5 个包测试 | 123 / 195 / 221 / 40 / 25 全过 |
| `dart format`（CI 口径） | **371 files，0 changed** |
| 新增依赖 | **0** |

---

## 1. 改动文件

| 文件 | 作用 |
|---|---|
| `lib/widgets/crypto_theft_card.dart`（新） | 五段链卡片：level 徽标、score、五段状态、缺失环节、官方基线、下一步、防误读声明 |
| `lib/pages/info_page.dart` | 安全 Tab 优先渲染 `CryptoTheftCard`；没有 assessment 时退回旧小结 |
| `lib/utils/analysis_report.dart` | Markdown `## 盗 U 风险` 小节；JSON 顶层 `security` 对象；schema 7→8 |
| `assets/i18n/{en,zh-CN,zh-TW,zh-HK}.json` | 新增 `theft` 文案组（29 个键） |
| `lib/gen/strings*.g.dart` | slang 生成物（按 build.yaml 自动生成） |
| `test/analysis_report_test.dart`、`test/security_integration_test.dart`、`test/diff_report_test.dart` | schema 7→8 断言更新 |

---

## 2. 呈现契约

### 2.1 UI 卡片

- 顶部：`盗 U 风险` + `level` 徽标（未发现 / 能力线索 / 疑似 / 强证据 / 无法判断）+ `score`；
- 正文：`This is static evidence, not a malware verdict`（本地化）；
- 五段：`能力 / 来源 / 注入 / 载荷 / 官方基线`，每段显示「已支撑 / 缺失」；
- 缺失环节：按 `MissingLink.whyCode` 本地化；
- 官方基线：Phase C 只显示「无官方基线条目」；Phase E 接入 match/mismatch；
- 下一步：导出地址清单 / 核对签名密封 / 与官方渠道包比对；
- 旧的 `SecurityFindingCard` 仍保留，用来看证据细节；两者不重复判级。

### 2.2 Markdown

新增在安全章节内、发现列表之前：

```
## 盗 U 风险
- 证据链: <level> (<severity>/<confidence>)
- 证据完整度: <score>/100
- 这是静态证据，不是恶意定性。
### 证据链
- 能力: 已支撑 / 缺失
...
### 缺失环节
...
### 官方基线
...
### 下一步
...
```

### 2.3 JSON（schema v8）

```json
{
  "reportSchemaVersion": 8,
  "security": {
    "cryptoTheft": {
      "id": "android.crypto.theft",
      "level": "capabilityOnly",
      "primaryTechnique": "...",
      "chain": [ /* 恰好 5 项 */ ],
      "missing": [ /* stage/whyCode/args */ ],
      "confidence": "independentCapability",
      "severity": "p3",
      "score": 25,
      "scoringVersion": "theft-1.0",
      "baselineEntryId": null
    },
    "artifacts": null,
    "loadGraph": null,
    "seal": null,
    "baseline": null
  }
}
```

- 五个键**始终存在**（D/E 前为 null），消费者可稳定解析；
- `security == null` 表示本次没做安全分析；
- 既有 v7 键名/类型不变；v7 读取器忽略新键即可。

### 2.4 i18n

- 新文案放在**顶层 `theft` 分组**，而不是继续塞进 `security` 分组：`security` 是 `i18n_coverage_test` 里 ja/ko 已迁移分组，新增键会要求 ja/ko 同步翻译；`theft` 是新增界面组，按项目既有策略 ja/ko 回退英文（与 README「日韩部分覆盖」一致）。
- 四种完整语言：en / zh-CN / zh-TW / zh-HK 全部有 29 个键；`dart run build_runner build` 重新生成 slang 文件。

---

## 3. 验证证据

```bash
cd /Users/wangbaye/Projects/AppInfoTool
flutter analyze --fatal-infos --fatal-warnings   # No issues found
flutter test                                     # 1,746 pass / 15 skip / 0 fail
for p in analysis_model apk_parser ipa_parser archive_safety app_icon_extractor; do
  (cd packages/$p && dart test && dart analyze --fatal-infos --fatal-warnings)
done
# 123 / 195 / 221 / 40 / 25；5 个包 analyze 全零
dart format --output=none --set-exit-if-changed $(git ls-files -co --exclude-standard '*.dart')
# 371 files, 0 changed
```

重点回归：

- `analysis_report_test`：schema 8；
- `security_integration_test`：JSON schema 8；
- `diff_report_test`：差异报告 schema 仍为 1，不随单文件报告升版；
- `i18n_coverage_test`：ja/ko 的 `security` 分组未被新增键破坏；
- UI/详情页测试：新卡片不改变旧路径（`cryptoTheft == null` 时仍用旧小结）。

---

## 4. 仍未做（Phase C-3 已完成，见 `2026-11-04-crypto-theft-phase-c3-wiring.md`；D / E 待做）

| 项 | 影响 |
|---|---|
| iOS 安全审计移入后台任务 | 当前仍在 UI 线程跑；新增清单/哈希前必须做 |
| 把 Phase B `artifacts/loadGraph/payloadProbe` 接入 `parse_task` / `ipa_parse_task` | 生产路径目前只用现有字符串/标记信号，悬空边/载荷细节还没进评估 |
| 10 条新规则 finding | 当前只有旧 `ANDROID/IOS-CRYPTO-THEFT-RISK` finding；评估卡已覆盖链，但按技术点拆分的 finding 未产出 |
| 官方基线（Phase E） | `baselineEntryId` 恒 null；卡片显示“无官方基线条目” |
| 密封校验（Phase D） | JSON `seal` 恒 null；强证据只能来自引擎链 |

---

## 5. 下一步建议

1. 把 Phase B 事实接入两个 `parse_task`（低风险，参数已就绪）；
2. iOS 审计后台化（前置性能改造）；
3. 按契约把 10 条 MVP 规则拆成 finding（需要补 ruleId 文案与 UI 分组）；
4. Phase D 密封校验、Phase E 官方基线（需要你们提供首批指纹）。
