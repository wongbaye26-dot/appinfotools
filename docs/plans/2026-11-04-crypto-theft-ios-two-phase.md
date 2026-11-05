# IPA 两阶段返回 — 静态结果先到、安全审计后到

> **状态**：已实现并通过根项目回归（2026-11-04）
> **样本**：`sun_signed.ipa`（40.5 MB，仓库根，只读）
> **问题**：安全审计 1.52 s 把“打开 IPA”的关键路径拖到 1.79 s
> **方案**：worker 先发静态结果，再发安全结果；UI 先渲染包内容，安全 Tab 后刷新

---

## 0. 结论

| 指标 | 两阶段前 | 两阶段后 |
|---|---:|---:|
| 用户看到静态结果 | 1,793 ms | **295 ms** |
| 安全结果到达 | 1,793 ms | 1,816 ms |
| 安全审计增量（后台） | 1,530 ms | 1,530 ms（不变） |
| 首屏收益 | —— | **-83.5%**（1,793 → 295 ms） |

安全审计总成本没有消失（约 1.53 s），但**不再阻塞静态信息展示**。用户先看到包名、版本、权限、组件、图标等，安全 Tab 随后更新。

---

## 1. 事件流

```
IpaStageReached(...)
  → IpaParseSucceeded(analysis, securityPending: true)   // ~295 ms
  → IpaSecurityReady(security)                          // ~1,816 ms
  → stream done
```

- `IpaParseSucceeded.analysis.security` 在 `securityPending: true` 时为 `null`；最终安全结果只在 `IpaSecurityReady` 里。
- `securityAudit: false` 时没有 `IpaSecurityReady`，`IpaParseSucceeded` 仍是最后一个事件（`securityPending: false`）。
- 安全审计抛异常时：静态解析已成功，worker 发 `IpaSecurityReady(null)`，不把整次解析判失败。
- `cancel()` 在两阶段之间仍有效；会终止 worker，只收到 `IpaParseCancelled`。

## 2. 实现

| 文件 | 改动 |
|---|---|
| `lib/ipaparser/ipa_analysis.dart` | `analyze(..., onParsed: ...)`：先构造 `security == null` 的 `IpaAnalysis` 并回调，再跑安全审计；`IpaAnalysis.copyWithSecurity` 补结果 |
| `lib/ipaparser/ipa_parse_task.dart` | 新增 `IpaSecurityReady`；`IpaParseSucceeded.securityPending`；`_handle` 在 pending 时不关流，等安全事件再收尾；worker 通过 `onParsed` 提前发成功，审计后发安全结果 |
| `lib/pages/info_page.dart` | `IpaParseSucceeded` 立即写入 `ipaAnalysis`、结束 loading、记录最近文件；`IpaSecurityReady` 只更新 `securityResult`；签名验证仍在解析完成后进行 |
| `test/ipa_analysis_test.dart` | 两阶段顺序测试（静态先到、安全后到、analysis.security 为 null）；关闭审计时成功事件仍最后 |

## 3. 验证

```bash
cd /Users/wangbaye/Projects/AppInfoTool
flutter analyze --fatal-infos --fatal-warnings
flutter test
flutter test tool/perf_probe_test.dart
```

实测：
- 根项目 **1,747 通过 / 15 跳过 / 0 失败**，analyze 零问题；
- 两阶段首屏 **295 ms**，安全结果 **1,816 ms**；
- `ipa_parser` 221 条测试通过。

## 4. 兼容性说明（重要）

`IpaParseSucceeded` 不再总是“最后一个事件”。直接消费事件流的调用方必须：

1. 在 `IpaParseSucceeded` 时使用 `analysis`（此时 `security == null`）；
2. 监听 `IpaSecurityReady` 获取安全结果，或显式 `securityAudit: false`；
3. 不要用 `events.last is IpaParseSucceeded` 判断成功。

本仓库的测试与 UI 已按新语义更新；`real_samples_*` 等只取 `whereType<IpaParseSucceeded>().first` 的调用方不受影响。

## 5. 剩余

- 1.53 s 安全审计仍在 worker 跑；如果还要压，需优化 `AsciiStrings.extract` 的逐串分配或并行扫描。
- 签名验证仍在安全结果之后开始；如果产品希望更早，可把它也提前到静态结果之后并行。
- C-4 finding 拆分、Phase D Android v1/v2、Phase E 仍未做；iOS CodeResources 校验已完成（见 `2026-11-04-crypto-theft-phase-d-ios-seal.md`）。
