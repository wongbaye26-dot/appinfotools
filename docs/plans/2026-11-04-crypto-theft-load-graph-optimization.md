# 加载链优化 — 复用方法扫描结果（Phase C-4 前置）

> **状态**：已实现并通过包级/根项目回归（2026-11-04）
> **目标**：消除 `AndroidLoadGraphScanner` 对 `method_ids` / `invoke-*` 的**第二遍遍历**
> **样本**：`FN_Music_1.0.3_00610141147.apk`（68.8 MB，外部只读）
> **工具**：`tool/perf_probe_apk_test.dart`（非 CI）

---

## 0. 结论

| 指标 | 优化前 | 优化后 | 变化 |
|---|---:|---:|---:|
| 加载链耗时 | 189.5 ms | **57.7 ms** | **-69.5%** |
| Phase B 事实层合计 | 211.5 ms | **80.6 ms** | -61.9% |
| 端到端（open→审计→环检测） | 2,019.5 ms | **1,962.7 ms** | -2.8% |
| 加载链边数（同一样本） | 41 | **99** | +141% |
| APK 包测试 | 195 | **196** | +1（复用路径） |
| 根项目测试 | 1,746 | **1,746** | 不变 |

> 端到端只降 2.8%，因为方法扫描本身（`DexMethodScanner`）仍是 787 ms 的大头，且这次探针改用了与生产一致的深链参数；**加载链这一段的 69.5% 降幅是确定的**。边数增加是因为复用后的 `DexMethodScanner` 能看到更多真实 `System.load/loadLibrary` 调用点，不是放宽了判据。

---

## 1. 问题

C-3 的 `AndroidLoadGraphScanner` 为了拿 loader 调用点，做了：

1. `DexMethodTable.forEachReference` 扫 `method_ids`（~40 ms）；
2. `DexMethodBodies.walk` 扫全部 `invoke-*`（~98 ms）；
3. 再扫 `string_ids` 找路径字面量。

而 `AndroidSecurityAudit` 为了安全规则，**已经**用 `DexMethodScanner` 完整扫过同一批 DEX 的 method refs 与调用点（~605–790 ms）。同一份字节码被走了两遍。

## 2. 改动

| 文件 | 改动 |
|---|---|
| `packages/apk_parser/lib/src/security/code_markers.dart` | 新增 `loader-system-load-library` / `loader-system-load` 标记（literal 用 `System;.loadLibrary` / `System;.load`，匹配 `DexMethodScanner` 的 `classDescriptor.name` 文本） |
| `packages/apk_parser/lib/src/security/android_security_audit.dart` | 新增可选 `methodScanResult`；传入时不再自己 `DexMethodScanner.scan`；`uploadMarkerIds` 提升为 `static const` 供 `parse_task` 复用 |
| `packages/apk_parser/lib/src/security/android_load_graph.dart` | `scan(..., methodScan:)`；有结果时直接从 `DexMethodScanResult.references` 取调用点，**不再** `forEachReference` / `DexMethodBodies.walk`；无结果时保留兼容路径 |
| `lib/apkparser/parse_task.dart` | 只跑一次 `DexMethodScanner.scan`，结果同时传给加载链与审计 |
| `packages/apk_parser/test/android_load_graph_test.dart` | 新增复用路径测试：边与兼容路径一致、位置来自调用点样本 |

### 正确性约束

- **只收真实调用点**：`DexMethodScanner.references` 里也可能只有方法声明/签名，没有 `callSiteSamples` 时**不建边**（测试覆盖）。
- `System;.load` 是 `System;.loadLibrary` 的前缀：逐条样本过滤含 `loadLibrary` 的样本，避免把 `loadLibrary` 记成 `System.load`。
- 没有 `methodScan` 的老调用方仍走原路径；`AndroidLoadGraphScanner` 的公开行为不变。
- 夹具 `loader-api.dex` 的复用路径与兼容路径产出相同的边/悬空边。

## 3. 复测

```bash
cd /Users/wangbaye/Projects/AppInfoTool
(cd packages/apk_parser && dart test && dart analyze --fatal-infos --fatal-warnings)
flutter analyze --fatal-infos --fatal-warnings
flutter test
PERF_APK=/path/to/big.apk flutter test tool/perf_probe_apk_test.dart
```

实测：
- `apk_parser`：196 通过，analyze 零问题；
- 根项目：1,746 通过 / 15 跳过，analyze 零问题；
- 优化后 APK 探针：加载链 57.7 ms，事实层 80.6 ms，e2e 1,962.7 ms。

## 4. 剩余

- 方法扫描 787 ms 仍是 APK 侧最大单项；要再降需要动 `DexMethodScanner` 的预算/标记匹配，风险高于本次。
- 加载链现在只占 e2e 约 2.9%，继续优化收益有限。
- 下一步优先：IPA 安全审计 2.49 s（既有）、C-4 finding 拆分、Phase D/E。
