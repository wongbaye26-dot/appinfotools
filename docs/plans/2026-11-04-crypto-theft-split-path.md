# Split / XAPK / aapt2 审计路径接入

> **状态**：已实现并通过 XAPK 相关测试与根项目回归（2026-11-04）
> **问题**：`_auditExtractedBaseApk`（aapt2/分包路径）此前只传 `meta + dex + native`，新能力全部缺失
> **完成**：该路径现在与主 `parse_task` 同口径接入 artifacts / loadGraph / payload / methodScan / seal / baseline

---

## 0. 结论

分包安装包（XAPK/APKM/APKS）走 aapt2 时，安全审计不再只跑老规则：

| 能力 | 主路径 | 分包路径（现在） |
|---|---|---|
| 制品清单 | ✅ | ✅ |
| 加载链 | ✅ | ✅ |
| 载荷探测 | ✅ | ✅ |
| 方法扫描复用 | ✅ | ✅ |
| APK v1/v2 密封 | ✅ | ✅（base APK） |
| 官方基线 | ✅ | ✅（base APK） |

仍然保留并如实写进 limitation：

> `android.split_apk.base_only` —— 只分析 base APK；各分包自己的 DEX / 资源 / ABI split 未参与。

## 1. 改动

`lib/apkparser/apk_info.dart` 的 `_auditExtractedBaseApk`：

- 读取条目事实 → 制品清单；
- `DexMethodScanner.scan` 一次，加载链与审计共用；
- `AndroidLoadGraphScanner.scan(methodScan:)`；
- `_probePayloadsForBase`（≤64 条、单条 ≤8 MiB、4 KiB 头部）；
- `_checkSealForBase`：有 v2 优先 v2，否则 v1；
- `OfficialBaselineStore.matchAndroid`：包名 + 证书 SHA-256；
- 全部传给 `AndroidSecurityAudit.audit`。

## 2. 验证

- `test/xapk_security_audit_test.dart` + `test/xapk_real_fixture_test.dart`：**12 通过**；
- 根项目 `flutter test`：**1,755 通过 / 15 跳过 / 0 失败**；
- 根项目 `flutter analyze`：No issues found；
- `dart format`：380 files，0 changed。

## 3. 剩余

- 分包自己的 DEX / 资源仍未分析；这是“base-only” limitation，不是 bug；
- 若要把分包也纳入，需要在解包后对每个 split 单独跑审计并合并覆盖/证据，工作量和误报风险都更大。
