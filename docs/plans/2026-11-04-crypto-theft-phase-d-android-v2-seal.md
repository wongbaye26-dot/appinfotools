# Phase D（Android v2 切片）— APK v2 内容摘要校验

> **状态**：APK v2 内容摘要校验已实现并通过包级/根项目回归（2026-11-04）
> **范围**：`ApkSealCheck.checkV2` + `ApkSigningSchemes` 暴露 v2 值/偏移 + `parse_task` 优先 v2、回退 v1
> **未做**：签名验证（`signatureVerified` 恒 false）、官方基线（Phase E）、C-4 finding 拆分
> **纪律**：parser 包不新增 `crypto` 依赖；摘要函数由应用层注入

---

## 0. 结论

Android 现在能验证 **APK Signature Scheme v2 内容摘要**了：去掉 APK Signing Block，按 AOSP 规则重算 1 MiB 分块摘要，与 v2 signed data 里记录的摘要比对。

| 验证项 | 结果 |
|---|---|
| `analysis_model` | 123 通过 |
| `apk_parser` | **203 通过**（+2 v2 摘要测试） |
| `ipa_parser` | 226 通过 |
| 根项目 `flutter analyze` | **No issues found** |
| 根项目 `flutter test` | **1,747 通过 / 15 跳过 / 0 失败** |
| `dart format` | **377 files，0 changed** |
| 新增依赖 | 0 |

### 真实 APK 验证（外部只读样本）

| 样本 | 大小 | v2 结果 | 校验耗时 |
|---|---:|---|---:|
| `FN_Music_1.0.3_00610141147.apk` | 68.8 MB | **verified** | 461 ms |
| `DH166.apk` | 57.8 MB | **verified** | 397 ms |
| `澳門娛樂集團-v6.9.18.apk` | 57.8 MB | **verified** | 未单独计时 |

三个样本的 `expected` 与 `actual` 摘要前缀完全一致（例如 FN_Music：`1963a5911d675729`）。

---

## 1. 算法（AOSP `ApkSigningBlockUtils`）

1. **三段输入**：
   - 签名块之前的文件内容；
   - 中央目录（`centralDirOffset..eocdOffset`）；
   - **改写过的 EOCD**：把 EOCD 里的中央目录偏移改成 **签名块起点**（`signingBlockOffset`）。
2. 每段按 1 MiB 分块（段之间不跨块）。
3. 每块摘要输入 = `0xa5 + uint32(块长度) + 块内容`。
4. 输出 = `sha256(0x5a + uint32(总块数) + 各块摘要)`。
5. 与 v2 signed data 的 digest 记录比对；优先 SHA-256，回退 SHA-512。

> EOCD 偏移改写和 `0xa5 + 长度` 前缀是最容易漏的两处；漏任一处都会在真实包上稳定 mismatch。

## 2. 实现

| 文件 | 改动 |
|---|---|
| `packages/apk_parser/lib/src/apk_signing_block.dart` | `ApkSigningSchemes` 增加 `v2Value`、`signingBlockOffset`、`centralDirOffset`、`eocdOffset` |
| `packages/apk_parser/lib/src/security/apk_seal_check.dart` | `checkV2`：解析 signed data 的 digest、分段/分块、EOCD 改写、比对；`scheme='apk.v2.content'` |
| `lib/apkparser/parse_task.dart` | 有 v2 时优先 v2；读失败/无 v2 回退 v1 `apk.v1.manifest` |
| `packages/apk_parser/test/apk_seal_check_test.dart` | 合成 v2 signed data：一致 → verified、不一致 → mismatch |

### 边界

- **只证明“内容与签名块记录的摘要一致/不一致”，不验签**；`signatureVerified` 恒 false。
- 重签名工具会重算 v2 摘要；v2 通过 ≠ 未被重签；冒充/重签的强证据要靠官方基线（Phase E）。
- v3-only 包（没有 v2）目前回退 v1；v3 内容摘要未单列。
- 读取/摘要失败 → `notChecked`，不冒充 `verified`。

## 3. 性能

| 指标 | 数值 |
|---|---:|
| v2 摘要校验（68.8 MB） | **461 ms** |
| v2 摘要校验（57.8 MB） | **397 ms** |
| 对 APK 端到端的影响 | 约 +0.4–0.46 s（worker 内，UI 不冻结） |

v2 要完整读一遍 APK（去掉签名块），成本与包大小线性相关；这是完整性校验的固有成本。若后续要压，可考虑并行分块 / 硬件 SHA，但不能为了速度跳过。

## 4. 验证

```bash
cd /Users/wangbaye/Projects/AppInfoTool
(cd packages/apk_parser && dart test && dart analyze --fatal-infos --fatal-warnings)
flutter analyze --fatal-infos --fatal-warnings
flutter test
```

合成测试覆盖：v2 分段/偏移接线、EOCD 改写、摘要一致/不一致两条路径。

## 5. 剩余

- 签名验证仍然交给 `apksigner`；本版本不自己实现密码学验签。
- Phase E 官方基线未做（需要首批真实指纹）。
- C-4 的 10 条技术点 finding 仍未拆分。
