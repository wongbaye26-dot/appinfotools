# AppInfoTool 2.11.0 — Stage 4 结构化网络线索

## 结论

Stage 4 完成：网络信息从“域名 + IPv4 两个字符串数组”升级为结构化线索，保留完整 URL / WebSocket，来源制品可追溯；Android 与 iOS 共用同一提取器。所有线索仍是**静态字符串提取**，不代表运行时访问。

## 模型

`packages/analysis_model/lib/src/network_facts.dart`

- 新增 `NetworkClueType { domain, ipv4, ipv6, url, websocket }`。
- `NetworkClue { id, type, value, sourcePath, context }`。
- `id` 由 type + value + sourcePath 的 FNV-1a 64 位派生，形式 `nc_<16 hex>`；同一线索跨报告稳定。
- `NetworkFacts` 保留 `domains` / `ips` 兼容旧报告，同时新增 `clues`。
- `isEmpty` 同时考虑三者。

## 提取

`packages/analysis_model/lib/src/network_endpoints.dart`

- 新增 `collect(..., {List<NetworkClue>? clues, String? sourcePath})`。
- URL / WebSocket：保留完整 `scheme://host[:port]/path`，`ws`/`wss` 标为 WebSocket；去掉尾部标点。
- 域名、IPv4、IPv6 分别产出线索。
- 去重按稳定 ID，最多 4×`maxEndpoints` 条。
- 原有 `domains` / `ips` 输出保持不变。

调用方：
- Android `DexClueScanner` 在同一字符串遍历里收集 `networkClues`，`sourcePath` 为 DEX 名；`DexScanResult` 新增 `networkClues`。
- iOS `IosPrivacyAudit` 的字符串扫描收集线索，`sourcePath` 为当前可执行文件/框架路径。
- Android/iOS 的 `NetworkFacts` 都带上 `clues`。

## UI / 报告

- 新增 `lib/widgets/network_clues_card.dart`：
  - 安全 Tab 显示线索总数与按类型计数。
  - “查看全部线索”弹层显示类型、完整值、来源文件。
  - 明确写“仅静态字符串提取，不代表运行时访问过”。
- `AnalysisReport.renderJson` 的 `network` 增加 `clues[]`（id/type/value/sourcePath/context）；`domains`/`ips` 保留。
- 只有真实提取到线索时才渲染卡片。

## 已知限制

- IPv6 只做字面量识别，不保证压缩/展开形态规范；裸 IPv6 可能来自非网络上下文。
- URL 保留原始字符串，不做参数归一化；不判断是否可达。
- 仍不解析加密字符串、原生拼接或运行时生成的地址。
- 没有网络线索的搜索/过滤/分组；弹层按提取顺序展示。

## 验证

```bash
flutter test                                      # 1895 passed / 19 skipped
flutter analyze --fatal-infos --fatal-warnings    # No issues found
dart format --output=none --set-exit-if-changed . # 467 files, 0 changed
flutter build bundle                              # exit 0
flutter test test/network_clues_card_test.dart    # 3 passed
flutter test packages/analysis_model/test/network_endpoints_test.dart # 16 passed
```
