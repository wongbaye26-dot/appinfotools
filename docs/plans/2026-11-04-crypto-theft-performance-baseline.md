# 盗 U 检测 — Phase C-3 性能基线（APK / IPA）

> **日期**：2026-11-04｜**环境**：macOS arm64，Flutter 3.47.7 stable
> **样本**：APK 68.8 MB（外部只读样本）、IPA 40.5 MB（仓库根 `sun_signed.ipa`）
> **工具**：`tool/perf_probe_apk_test.dart`、`tool/perf_probe_test.dart`（均**不在** CI 门禁）
> **性质**：单次测量的基线，不是统计基准；不同机器/样本会波动

---

## 0. 结论

> **2026-11-04 追加**：加载链已优化（复用 `DexMethodScanner` 调用点），见
> `docs/plans/2026-11-04-crypto-theft-load-graph-optimization.md`。
> 同一样本加载链 **189.5 → 57.7 ms（-69.5%）**，事实层 **211.5 → 80.6 ms**，
> e2e **2,019.5 → 1,962.7 ms**（-2.8%，方法扫描仍是耗时大头）。
>
> **2026-11-04 追加 2**：IPA 安全审计字符串扫描已预筛，见
> `docs/plans/2026-11-04-crypto-theft-ios-audit-optimization.md`。
> 完整解析 **2,760.8 → 1,791.1 ms（-35.1%）**，安全审计增量
> **2,490.3 → 1,521.2 ms（-38.9%）**；Phase B 事实层仍约 5 ms。
>
> **2026-11-04 追加 3**：APK v2 内容摘要已接入，见
> `docs/plans/2026-11-04-crypto-theft-phase-d-android-v2-seal.md`。
> 68.8 MB 样本 v2 校验 **461 ms**、57.8 MB **397 ms**；这是完整性校验的固有成本，
> APK 端到端约 +0.4–0.46 s（worker 内，UI 不冻结）。

| 指标 | 结果 | 契约目标 | 判定 |
|---|---:|---:|---|
| APK Phase B 事实层增量（清单+加载链+载荷） | **211.5 ms**（e2e 2,019.5 ms 的 **10.5%**） | ≤ +15% | ✅ 达标 |
| IPA Phase B 事实层增量 | **4.8 ms**（解析 270.4 ms 的 **1.8%**） | ≤ +10% | ✅ 达标 |
| APK 安全审计（既有） | 1,714.1 ms | —— | 既有成本 |
| IPA 安全审计（既有） | **2,490.3 ms**（`securityAudit:false` 270.4 ms → true 2,760.8 ms） | —— | **既有成本，现移入 worker** |

**关键结论**：

1. C-3 新增的事实层开销在契约目标内（APK 10.5% / IPA 1.8%）。
2. APK 新增开销的 **89.6% 是加载链**（189.5 ms）；其余清单/载荷合计约 22 ms。
3. IPA 的 2.49 s 是**既有安全审计**（主可执行 + 嵌套 ASCII 字符串扫描），不是 C-3 新增；C-3 只是把它从 UI 线程移到 worker，因此 **UI 不再被它冻住**，但总解析时间仍是 2.76 s。
4. 若下一步要压 IPA 的 2.49 s，需要优化既有字符串扫描/预算，而不是 Phase B 事实层。

---

## 1. APK（68.8 MB，`FN_Music_1.0.3_00610141147.apk`）

```
1. 打开归档                         36.4 ms
2. parse（manifest + arsc）         45.4 ms
3. 资源表遍历（5,088 项）            11.9 ms
4a. 列出 DEX（2 个）                 0.8 ms
4b. 读取全部 DEX 字节                45.0 ms
5a. 挑选原生库（18 个）               3.9 ms
5b. 读取原生库字节                  168.0 ms
6. 加固线索                         15.0 ms
6a. 条目事实（1,135 条）             0.8 ms
6b. 制品清单（238 条）               2.1 ms
6c. 加载链（41 边）                189.5 ms  ← 新增里最大
6d. 载荷探测（64 条）               19.1 ms
7. 容器结构                          1.4 ms
8a. DEX 字符串扫描                 682.8 ms
8b. DEX 结构（2 个）                16.0 ms
8c. 方法引用与调用点遍历            605.8 ms
8c-1. 仅 method_ids（98,076 条）    40.0 ms
8c-2. 仅调用点（311,629 个）        97.8 ms
8d. 原生符号                         14.3 ms
8. 安全审计（含 Phase B 事实）     1,714.1 ms
9. 资源环检测                        0.7 ms
★ 端到端（open → 审计 → 环检测）   2,019.5 ms
```

- **新增事实层合计**：0.8 + 2.1 + 189.5 + 19.1 = **211.5 ms**（10.5%）。
- **加载链 189.5 ms 的构成**：`DexStructure.read` + `method_ids` 遍历 + `DexMethodBodies.walk` 找 loader 调用点 + 字符串表路径字面量。当前实现为了找 loader 调用点**又走了一遍字节码**，而现有 `DexMethodScanner` 已经走过一遍——这是下一步最明确的优化点。
- **载荷探测 19.1 ms**：64 条 × 4 KiB 头部，符合预算预期。
- **清单 2.1 ms**：只读中央目录，符合设计。

## 2. IPA（40.5 MB，`sun_signed.ipa`）

```
1. 打开归档                          18.7 ms
2. 枚举 bundle                        4.0 ms
3. Info.plist                         8.8 ms
4. 图标定位                         128.7 ms
5a. 主可执行文件读取                  82.4 ms
5b. 主可执行文件 Mach-O 解析          10.0 ms
6a. 嵌套 bundle 读取（27 个）        105.5 ms
6b. 嵌套 bundle Mach-O 解析           18.7 ms
7. 签名材料                          39.4 ms
★ 完整解析（含安全审计）            2,760.8 ms
★ 完整解析（securityAudit:false）     270.4 ms
   安全审计增量                     2,490.3 ms  ← 既有成本
6e. 条目事实（326 条）                 0.2 ms
6f. 制品清单（121 条）                 0.8 ms
6g. 加载链（43 边）                    0.5 ms
6h. 载荷探测（34 条）                  3.3 ms
   Phase B 事实层合计                 4.8 ms
8. 三种哈希（独立 isolate）           305.2 ms
9a. 解包主 .app                      347.0 ms
9b. 解包 + codesign                  390.8 ms
```

- **新增事实层合计 4.8 ms**（1.8%），可忽略。
- **2.49 s 安全审计** = 既有 `IosPrivacyAudit.audit`：主可执行（≤64 MiB）+ 27 个嵌套可执行（≤32 MiB）的 ASCII 字符串扫描、隐私/引用/签名规则。C-3 把它移到 worker，**UI 响应性改善**，但总解析时间不变。
- 当前 C-3 后 UI 在 worker 完成全部（含安全审计）才拿到结果，所以 **打开 IPA 的等待仍是 ~2.76 s**；如果产品要“先出静态解析、安全稍后到”，需要把 `IpaParseSucceeded` 拆成两阶段事件。

---

## 3. 与契约目标对账

| 契约目标 | 实测 | 结论 |
|---|---|---|
| APK 新增耗时 ≤ +15% | +10.5% | ✅ |
| IPA 新增耗时 ≤ +10% | +1.8% | ✅ |
| 峰值内存 | **未测**（需要 ΔRSS 探针） | ❓ 未验证 |
| 大包取消/响应 | worker 可取消；UI 不阻塞 | ✅（未见卡顿；未做交互压测） |

> 注意：上述百分比是「Phase B 事实层新增 / 总解析」；IPA 的安全审计是**既有**成本，不计入 C-3 目标，但它是当前最大的单项耗时。

---

## 4. 建议

1. **优化 Android 加载链**（189.5 ms，新增开销的 89.6%）：
   - 复用 `DexMethodScanner` 已经走过的调用点，避免第二遍 `DexMethodBodies.walk`；
   - 先收集路径字面量，若为空直接跳过调用点遍历；
   - 缓存 `DexStructure`/`DexTables`，避免同一 DEX 重复解析。
   预期：加载链降到 ~20–40 ms，APK 新增开销从 10.5% 降到 ~2–3%。
2. **IPA 安全审计 2.49 s**（既有）：
   - 这是“打开 IPA 要等 2.76 s”的主因；
   - 可考虑两阶段返回（解析先出、安全后到）或缩小字符串扫描预算/并行化；
   - 不要在未审计的情况下直接砍预算。
3. **补 ΔRSS 探针**：当前没有内存数据，不能声称峰值内存达标。
4. **把性能数字写进发布检查清单**：`tool/perf_probe_*` 不在 CI，靠人工跑；建议每次涉及解析/安全的大改后跑一次并记录样本/版本/机器。

---

## 5. 复现

```bash
cd /Users/wangbaye/Projects/AppInfoTool
export PATH="$HOME/development/flutter/bin:$PATH"

# APK（样本自备，只读）
PERF_APK=/path/to/big.apk flutter test tool/perf_probe_apk_test.dart

# IPA（仓库根 sun_signed.ipa）
flutter test tool/perf_probe_test.dart
```

本次样本：
- APK：`FN_Music_1.0.3_00610141147.apk`（68.8 MB，外部只读样本，不入库）
- IPA：`sun_signed.ipa`（40.5 MB，仓库根，`gitignore`）
