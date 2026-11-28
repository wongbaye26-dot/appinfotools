# V3.0 阶段 1 报告：分析基础设施

日期：2026-11-28
基线：`main @ 01971a2`（阶段 0 审计）
提交：`2a52fcc` + 本报告提交
状态：**完成**（1.8 无头入口按设计推迟到阶段 8）

## 1. 目标

为 F01–F10 提供**一套共用、可序列化、跨 run 稳定**的数据基础：组件身份、
Finding 指纹、制品身份、证据扩展字段、扫描 Profile 校验。

不做：任何扫描器实现、任何 UI、任何报告 schema 变更。

## 2. 变更清单

| 文件 | 变更 |
| --- | --- |
| `packages/analysis_model/pubspec.yaml` | 新增 `crypto: ^3.0.6`（纯 Dart 哈希） |
| `packages/analysis_model/lib/src/v3/component.dart` | 新增：`Component` / `ComponentPurl` / 四个枚举 |
| `packages/analysis_model/lib/src/v3/finding_fingerprint.dart` | 新增：`FindingFingerprint` + 三个规范化函数 |
| `packages/analysis_model/lib/src/artifact_inventory.dart` | `ArtifactIdentity`；`ArtifactEntry` 增 `artifactId` / `parentPath` / `archiveEntry` / `stableId` |
| `packages/analysis_model/lib/src/security_finding.dart` | `SecurityEvidence` 增可选 `redactedValue` / `extractorId` |
| `packages/analysis_model/lib/src/v3/scan_profile.dart` | 新增：`ScanProfile` / `ScanBudgets` / `ScanStage` / `ScanProfileException` |
| `lib/models/analysis/analysis_run.dart` | `AnalysisRun` 增可选 `model` 载荷（快照之外的结构化数据） |
| `docs/architecture/APPINFOTOOL_V3_ANALYSIS_ARCHITECTURE.md` | 新增：模型口径与持久化/兼容决策 |
| `docs/product/APPINFOTOOL_V3_PROGRESS.md` | 新增：九阶段进度表 |
| `packages/analysis_model/test/v3/*` | 新增 5 个测试文件，35 条用例 |

## 3. 新增接口（签名）

```dart
String? ComponentPurl.build({
  required String? name,
  required ComponentEcosystem ecosystem,
  String? namespace, String? version,
  ComponentPlatform? platform,
  Map<String, String> qualifiers = const {},
});

Component Component.create({ required String name, ... });
String Component.componentId({ required String name, required ComponentEcosystem ecosystem,
  required ComponentPlatform platform, String? version });

String FindingFingerprint.of({ required String ruleId, required String platform,
  String? artifactPath, String? location, String? value });

String ArtifactIdentity.of(String path);
(String?, String?) ArtifactIdentity.describe(String path);

ScanProfile ScanProfile.fromJson(Map<String, Object?> json); // 非法即抛 ScanProfileException
```

## 4. 关键决策与理由

| 决策 | 理由 |
| --- | --- |
| `Component.id` 只用 生态+平台+名称+版本 | 跨包/跨 run 稳定；同一 SDK 不同版本才能对齐成「版本变化」 |
| 版本未知写 `null`，PURL 不输出 `@` | 「未知」与「已知为空」不能混；报告里也不出现 `@null` |
| 指纹去掉偏移与行号 | 重编译/重新压缩会变，否则同一条问题每次都算「新增」 |
| 指纹里的值只存 sha256 前 16 位 | 指纹会进历史与导出，不能暴露密钥原文 |
| 嵌套归档用 `!` 分隔身份 | F04 需要「同一路径、不同容器」是两个条目 |
| Profile 未知扫描器整体拒绝 | 避免「配了但没生效」的静默失败 |
| `AnalysisRun.model` 与 `snapshot` 并存 | snapshot 是导出契约；结构化模型只服务查询，缺了要能降级 |

## 5. 兼容性与迁移

- `ArtifactEntry` / `SecurityEvidence` 新字段全部可选、默认 null，旧构造调用零改动；
- `AnalysisRun` 旧 JSON 无 `model` 键 → `null`，读取方按「只有快照」处理；
- 索引 `indexSchemaVersion` 保持 2（本次不涉及列表展示字段）；
- 报告 schema 仍是 v11（本次无报告结构变更）。

## 6. 测试证据

```
cd packages/analysis_model && dart test      # 183 passed（新增 35）
cd packages/analysis_model && dart analyze    # No issues found
flutter analyze                               # No issues found
flutter test test/analysis_run_test.dart      # 12 passed（含 2 条新旧 JSON 兼容）
```

覆盖面：PURL 编码与排序、组件 id 稳定性、JSON 往返与缺字段、指纹规范化与
敏感值不落明文、嵌套归档身份、Profile 非法配置一次报全。

## 7. 已知限制

| 限制 | 影响 | 处理 |
| --- | --- | --- |
| `Component` 尚无生产者 | 阶段 2/3 之前只是空模型 | 阶段 3（F02/F03）接 LibChecker 与 framework 识别 |
| 指纹尚未写入 `SecurityFinding` | 现有 finding 仍无稳定 id | 阶段 2 起由规则层产出时生成 |
| `AnalysisRun.model` 尚无写入口 | 历史 run 暂时只有 snapshot | 阶段 2 起分析完成后写入 |
| 无头分析入口未验证 | CLI 还不能复用 | 阶段 8（F09）下沉 `getApkInfo` 时解决 |

## 8. 风险

- **模型先行、落地滞后**：如果阶段 2/3 不按这些模型写入，会出现「两套身份」；
  入口检查：任何新扫描器提交必须引用 `Component.id` / `FindingFingerprint`。
- **指纹算法变更**：改规范化必须升 `version`，否则用户「已忽略」会错位。

## 9. 未完成项（本阶段范围内）

- 1.8 无头入口验证：受 `lib/apkparser/apk_info.dart` 的 Flutter 依赖阻塞，按设计留到阶段 8。

## 10. 下一阶段入口（阶段 2：F04 + F01）

- 文件树/搜索/查看器复用 `ApkReader` / `ZipHelper` 与现有预算常量；
- `SecretMatch` 复用 `FindingFingerprint` 做稳定 id、`redactedValue` 做展示；
- 任何用户可见的敏感值默认脱敏，明文需显式动作（阶段 2 的安全评审项）。

## 11. 命令与提交

- 提交 `2a52fcc feat(v3): 阶段 1 分析基础设施模型`
- 本报告随后提交；
- 未改动 `v2.11.0` tag、未改报告 schema、未新增 Flutter 依赖。

## 12. 结论

阶段 1 **完成**：模型、校验器、兼容读取与测试已就位；1.8 按架构文档推迟到阶段 8。
可以进入阶段 2。
