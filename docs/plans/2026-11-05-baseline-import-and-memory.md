# 基线导入工具 + ΔRSS 基线

> **日期**：2026-11-05｜**状态**：工具与探针已落地，质量门禁全绿
> **范围**：`tool/import_baseline.dart`、`tool/perf_probe_*.dart` 的 RSS 输出
> **性质**：工具/测量，不改检测口径

---

## 1. 基线导入工具

```bash
dart run tool/import_baseline.dart <apk|ipa> \
  --source-type other|official-site|app-store|google-play|public-fingerprint \
  --source-url https://... \
  --out /tmp/entry.json          # 只输出条目
# 或
  --merge                        # 并入 assets/baseline/official_baseline_v1.json
```

行为：

- APK：`ApkReader` 取 packageId / label / 签名证书 SHA-256；
- IPA：`IpaContainerReader` + `IpaInfoPlistReader` + `IpaSignatureMaterialReader` 取 Bundle ID / display name / Team ID（要求有描述文件）；
- 输出条目自动带 `sources`、`retrievedAt`、`status=active`；
- 默认 notes 写明 **caller-provided / not independently verified**；传 `--official` 才写“official”；
- `--merge` 遇到同 platform + packageId 的已有条目会**拒绝覆盖**，必须人工改基线文件；
- 不会把本地绝对路径写进基线。

实测：
- `17加固.apk` → 输出 `android.com.pwtma.tgewuir.ddmw`；
- `wnsr_signed.ipa` → 输出 `top.modely.wns` + Team ID。

## 1.5 基线完整性

- 基线文件新增 `integritySha256`：对 `entries` 的规范 JSON（`jsonEncode`）做 SHA-256；
- `OfficialBaselineStore.parse` 校验该字段，不匹配直接返回 `null`（按 `unavailable` 处理）；
- `import_baseline.dart --merge` 合并后自动重算；
- 测试覆盖：坏哈希被拒绝、随包资产通过。

## 2. ΔRSS 基线

`tool/perf_probe_apk_test.dart` / `tool/perf_probe_test.dart` 末尾新增：

```
RSS start=... MB end=... MB peak=... MB
```

实测（当前代码）：

| 样本 | start | end | peak | 首屏/安全结果 |
|---|---:|---:|---:|---|
| APK 68.8 MB | 141.0 MB | 380.4 MB | 384.9 MB | e2e 1,729.8 ms |
| IPA 40.5 MB（探针同时持有多份 Archive） | 145.3 MB | 654.2 MB | 881.2 MB | 首屏 ~295 ms；安全结果 **~2.2 s** |
| IPA 40.5 MB（单次 analyze，保留字节） | 144.6 MB | 352.6 MB | **~527–535 MB** | 同上 |
| IPA 40.5 MB（**生产口径，retainRawBytes=false**） | 144.8 MB | **284.1 MB** | **436.1 MB** | 同上 |

结论：

- APK 内存峰值约 385 MB，可接受性需要产品定；
- 旧探针的 881 MB 峰值**包含它自己同时打开的多份 Archive**，不是单次分析的真实值；
- 新增 `tool/perf_probe_memory_test.dart` 只开一个归档、只跑一次 analyze：峰值 **527.5 MB**、结束 344.3 MB；
- 安全结果已从 5.8 s 降到 **约 2.2 s**：Unicode 扫描改为只走真实的 `__TEXT,__cstring` / `__TEXT,__ustring` 节，非 Mach-O 输入才退回整文件；
- 生产 worker 不再把主可执行文件字节带进 `IpaAnalysis`（`retainRawBytes=false`），但探针受 Archive/GC 影响，峰值仍在 **约 436–526 MB** 波动；
- 仍需要产品定内存预算/进一步收敛，不能声称已达标；
- 已把 `IosCallSiteScanner` 从「保存所有命中地址 + 二次 perSelector 列表」改成命中时即时归属/限函数数；语义计数保留，但该样本峰值仍未下降；
- 新增 `tool/perf_probe_ios_analysis_stages_test.dart`，把 `analyze` 的阶段与 RSS 对齐：
  - `macho-parsed` 后约 353 MB；
  - `resolve:classes` 后仍约 353 MB；
  - **`tables-added` → `methname-done` 之间 maxRss 报到 ~545 MB**（`__objc_methname` 只有 122 KB）；
  - `ascii-done` current 仍约 354 MB。
  峰值落在引用表/选择子表阶段，不是 ASCII consume 常驻；但单独跑 `resolve` 测不到同样峰值，且 `maxRss` 是进程级异步值，精确归属仍不可靠。
- 已把 marker 样例从「全部命中串」限制到 5 条、调用点去掉全量地址列表，峰值均未下降。
- CodeResources 校验增加 32 MiB/文件、64 MiB 总量预算，避免大包一次读入大文件；该样本未触发，但保护了大包路径；
- 这仍是**单点测量**，没有回归曲线/门禁；探针不进门禁。

## 3. 导入工具稳定 id 单测

`buildBaselineEntryId` 抽到 `lib/utils/baseline_entry_id.dart`，覆盖小写/非法字符归一/64 字符截断；`tool/import_baseline.dart` 复用它。提取路径抽到 `lib/utils/baseline_entry_extractor.dart`，用 `signed-v2-v3.apk` fixture 覆盖 packageId/证书 SHA-256/id/notes，并覆盖缺失文件异常。

## 4. 质量门禁

| 项 | 结果 |
|---|---|
| 根项目 `flutter test` | **1,769 通过 / 15 跳过 / 0 失败** |
| 根项目 `flutter analyze` | No issues found |
| `analysis_model` | 141 通过 |
| `apk_parser` | 213 通过 |
| `ipa_parser` | 236 通过 |
| `archive_safety` / `app_icon_extractor` | 40 / 25 通过 |
| `dart format` | 399 files，0 changed |

## 4. 下一步

1. IPA Unicode 扫描性能：5–6 s 安全审计需要优化（预算/节级扫描/预筛），否则大包交互不可接受；
2. 基线导入工具补单元测试（当前仅用真实文件手测）；
3. 是否把 ΔRSS 纳入发布检查清单；
4. 继续等官方样本补基线数据。
