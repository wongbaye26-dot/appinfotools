# 盗 U 检测能力 — Phase C-3 生产接线报告

> **状态**：Phase C-3（Phase B 事实接入 + iOS 审计后台化）**已实现并通过根项目回归**（2026-11-04）
> **范围**：Android `parse_task` 接入清单/加载链/载荷；iOS worker 内完成安全审计；UI 改为消费 worker 结果
> **未做**：10 条技术点 finding、Phase D 密封、Phase E 官方基线
> **纪律**：未新增依赖；未执行样本；未联网

---

## 0. 结论

C-3 把"实现了但没接线"的两块接通了：

1. **Android**：`parse_task` 在 worker 内一次生成条目事实 → 制品清单 → 加载链 → 载荷探测，作为 `artifacts/loadGraph/payloadProbe` 传给 `AndroidSecurityAudit.audit`。评估链现在真的能用到悬空边、载荷、清单来源。
2. **iOS**：安全审计从 `info_page` 主 isolate **移入 `IpaAnalysisReader.analyze`（worker）**；`IpaAnalysis.security` 随解析结果跨 isolate 返回；UI 只消费结果。`IpaParseTask.start(..., securityAudit: bool)` 尊重设置页开关，关闭时不跑审计。

| 验证项 | 结果 |
|---|---|
| 根项目 `flutter analyze` | **No issues found** |
| 根项目 `flutter test` | **1,746 通过 / 15 跳过 / 0 失败** |
| `dart format`（CI 口径） | **371 files，0 changed** |
| 包级测试 | 123 / 195 / 221 / 40 / 25（均未受影响） |
| 新增依赖 | **0** |

---

## 1. 改动

| 文件 | 改动 |
|---|---|
| `lib/apkparser/parse_task.dart` | worker 内构建 `entryFacts` → `AndroidArtifactInventoryScanner` → `AndroidLoadGraphScanner` → `_probePayloads`（assets/非标准 DEX，≤64 条、单条 ≤8 MiB、只读 4 KiB 头部）；传给 `AndroidSecurityAudit.audit` |
| `lib/ipaparser/ipa_analysis.dart` | `IpaAnalysis` 新增 `security`；`analyze(..., securityAudit: bool)` 内构建条目事实/制品清单/加载链/载荷探测并调用 `IosPrivacyAudit.audit` |
| `lib/ipaparser/ipa_parse_task.dart` | `start(..., securityAudit)`，请求对象携带开关，worker 传给 `analyze` |
| `lib/pages/info_page.dart` | 删除主 isolate 的 `IosPrivacyAudit.audit` 调用，改为 `parsed.security`；任务启动时传 `securityAudit: enableSecurityAudit` |

---

## 2. 生产链路（现在）

### Android

```
ApkParseTask worker
  reader.open + parse
  → entryFacts()（一次遍历）
  → AndroidArtifactInventoryScanner.scan
  → AndroidLoadGraphScanner.scan(dexEntries, inventory)
  → _probePayloads(reader, inventory)（有界头部）
  → AndroidSecurityAudit.audit(
       artifacts, loadGraph, payloadProbe, ...
     )
  → SecurityAnalysisResult.cryptoTheft
```

### iOS

```
IpaParseTask worker
  ZipHelper.open → Archive
  → IpaAnalysisReader.analyze(
       securityAudit: request.securityAudit
     )
       → Info.plist / 图标 / Mach-O / 嵌套 / 签名 / 布局（既有）
       → IosArtifactInventoryScanner
       → IosLoadGraphScanner
       → IosPayloadProbe（readEntryPrefix ≤4 KiB）
       → IosPrivacyAudit.audit(..., artifacts/loadGraph/payloadProbe)
       → IpaAnalysis.security
  → IpaParseSucceeded(analysis)
主 isolate：UI 只读 parsed.security，不再跑扫描
```

---

## 3. 需要知道的边界

- **Android 载荷探测**只覆盖 `assets/` 与非标准位置 DEX；`lib/*.so` 不在载荷探测里（它们由原生符号/加固扫描负责）。读取上限 64 条 × 8 MiB 声明大小，只取前 4 KiB。
- **iOS 载荷探测**同理，只覆盖清单里的代码类/资源载荷，单条 ≤8 MiB，读前缀 4 KiB。
- **性能未实测**：清单/加载链/载荷探测已进 worker，但大包（343 MB APK / 41 MB IPA）上的增量还没 benchmark；Phase D 前需要用 `tool/perf_probe_apk_test.dart` 量。
- **`securityAudit: false` 时**：iOS 不跑审计，`IpaAnalysis.security == null`；UI 安全 Tab 显示"未执行安全检测"。Android 既有路径未加开关。
- **两阶段**：iOS 静态结果先返回（约 295 ms），安全结果由 `IpaSecurityReady` 后到（约 1.8 s）；见 `2026-11-04-crypto-theft-ios-two-phase.md`。
- **10 条技术点 finding 仍未产出**：当前 UI 的评估卡来自 `cryptoTheft`，旧 `ANDROID/IOS-CRYPTO-THEFT-RISK` finding 仍在；按规则拆分的 finding 需要 Phase C-4（含 ruleId 文案与 UI 分组）。
- **官方基线/密封**：仍为 Phase D/E；JSON 的 `security.artifacts/loadGraph/seal/baseline` 仍是 `null`。

---

## 4. 复现命令

```bash
cd /Users/wangbaye/Projects/AppInfoTool
flutter analyze --fatal-infos --fatal-warnings   # No issues found
flutter test                                     # 1,746 pass / 15 skip / 0 fail
dart format --output=none --set-exit-if-changed $(git ls-files -co --exclude-standard '*.dart')
# 371 files, 0 changed
```

---

## 5. 性能基线

实测见 `docs/plans/2026-11-04-crypto-theft-performance-baseline.md`：
- APK 68.8 MB：Phase B 事实层新增 **211.5 ms**（e2e 2,019.5 ms 的 10.5%），其中加载链 189.5 ms；
- IPA 40.5 MB：Phase B 事实层新增 **4.8 ms**（1.8%）；既有安全审计 2,490.3 ms，是总耗时主因。

## 6. 加载链优化

复用 `DexMethodScanner` 调用点后，同一样本加载链 **189.5 → 57.7 ms（-69.5%）**，事实层 **211.5 → 80.6 ms**；见 `2026-11-04-crypto-theft-load-graph-optimization.md`。

## 7. 下一步

1. **C-4**：把 10 条 MVP 规则拆成 finding（ruleId/文案/UI 分组），并补“评估卡 vs finding”去重；
2. **性能基准**：大包 APK/IPA 的增量耗时/内存；
3. **Phase D**：APK v1/v2 摘要 + IPA CodeResources 校验 + `ContentDigestFn`；
4. **Phase E**：官方基线库（首批指纹由你们提供）+ `baselineUnavailable` 降级。
