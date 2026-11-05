# Split / XAPK：split DEX、资源与原生库纳入审计

> **日期**：2026-11-05｜**状态**：已实现，门禁全绿

---

## 1. 改动

`lib/apkparser/apk_info.dart` 的 XAPK 分支：

- 提取 base APK 后，同时把其余 split APK 解到临时目录（最多 50 个）；
- `_auditExtractedBaseApk` 新增 `splitApkPaths`；
- 对每个 split：
  - 读 DEX，名称加 `split:<basename>/` 前缀，避免与 base 重名；
  - 读 `resources.arsc` 全局字符串池 + 文本 assets；
  - 收集 `.so` 候选，与 base 一起走 `selectLibraries` 预算；
- 审计输入改为合并后的 DEX / resourceStrings / nativeEntries；
- split 条目以 `split:<label>/` 前缀进入 artifact inventory、load graph 和
  payload probe；
- base 与 split 的签名证书 SHA-256 做一致性比较，不一致时产出
  `ANDROID-SPLIT-CERT-MISMATCH`（P1），并追加
  `android.split_apk.cert_mismatch` 限制说明；
- 新增带 DEX 的合成 XAPK 回归：base + split 两份 DEX 都进入
  `android.dex.structure` 的 limit。

## 2. 仍未覆盖

- split 的密封校验已合并进 base 的 `SealCheck`：路径加 `split:<label>/`
  前缀，任一 mismatch 会让汇总状态为 mismatch，从而产出
  `ANDROID-APK-SEAL-MISMATCH`；
- split 数量上限 50；真实大 XAPK 未压测。

## 3. 门禁

| 项 | 结果 |
|---|---|
| 根项目 `flutter test` | **1,772 通过 / 15 跳过 / 0 失败** |
| 根项目 `flutter analyze` | No issues found |
| `analysis_model` | 141 通过 |
| `apk_parser` | 216 通过 |
| `ipa_parser` | 239 通过 |
| `archive_safety` / `app_icon_extractor` | 40 / 25 通过 |
| `dart format` | 404 files，0 changed |

## 4. 备注

真实 XAPK fixture 只有一个 config split，未包含 DEX；本实现主要靠代码路径和
现有 XAPK 解析测试覆盖，后续有带 DEX 的 XAPK 样本时应补端到端断言。
