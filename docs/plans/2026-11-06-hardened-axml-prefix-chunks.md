# 2026-11-06 — 加固 APK 的 AXML「诱饵 chunk 前置」导致清单读不出来

> **触发样本**：`/Users/wangbaye/Downloads/200_1106154007.apk`（用户提供，29 MB，只读、不入库）
> **状态**：已修复，完整质量门禁通过（见 §6）
> **外部核对工具**：`aapt2 dump badging`（build-tools 36.1.0）

---

## 1. 现象

用户在界面上看到「解析不了 / 解析失败」；无头入口的实测结果是**能打开但字段几乎全空**：

```
packageName:   com.jKJNPisqzojujqpK.yBjYcgXuuZmrJjjk   ← 来自 resources.arsc 回退
versionName:   null
versionCode:   null
minSdk:        null    targetSdk: null
permissions(0)  label: null
```

`ApkReader` 的诊断字段：

```
open.ok=true   budgetFailure=null   structureAnomaly=null
manifestFailure = AndroidManifest.xml could not be parsed:
                  FormatException: Invalid String table identifier.
                  Expecting 0x1, found 0x7fc7
```

所以**不是 ZIP 打不开、也不是预算拒绝**：ZIP 能打开，manifest 条目也在，只是 AXML 解析在第一个 chunk 就失败了，于是落到 2026-11-05 的 `_fallbackFromResources`（只给包名）。

## 2. 样本结构（只读取证）

| 项 | 值 |
|---|---|
| ZIP 条目 | 2375 条，声明解压合计约 47.7 MiB |
| 精确名关键条目 | `AndroidManifest.xml` 259,568 B；`resources.arsc` 1,626,192 B；`classes.dex` 33,410,875 B，各 1 条、无重名 |
| 诱饵路径 | 612 条畸形路径（`AndroidManifest.xml/..xml`、`/resources.arsc///.xml`、`classes.dex/\\.xml`、`META-INF/ .xml` …），1455 条以 `.xml` 结尾 |
| manifest CRC | 声明 `0xd7d74bca`，实际 `0xd7d74bcb`（**差 1**，与 `224_1105154007.apk` 同家族手法）；`aapt2` 与本项目的 ZIP 解码器都不据此拒绝 |
| AXML 根头 | `03 00 08 00` + `f0 f5 03 00`（= 259,568，与文件长度一致） |

关键在 offset 8 之后：

```
0x0008   78 个等长 chunk，每个 848 字节 (0x350)
         type = 0x7fxx（53 种不同假类型），headerSize = 8，size = 848，内容全 0
0x10268  真正的 RES_STRING_POOL_TYPE：01 00 1c 00
         size 19096、254 条字符串、stringsStart 1044 → 结束于 0x14d00
```

即**正常 string pool 被 78 个诱饵 chunk 推后了 66,144 字节**（0x10268 而不是 8）。
`aapt2 dump badging` 只警告 `warn: unexpected chunk type 0.` 就继续解析并给出完整结果 ——
AOSP 的口径是「跳过未知 chunk」；我们旧版 `BinaryXmlDecompressor` 的口径是
「offset 8 必须是 string pool」，于是直接抛异常。

## 3. 与 11-05 那个样本的区别

| | `224_1105154007.apk`（11-05） | `200_1106154007.apk`（本次） |
|---|---|---|
| 手法 | 把 string pool 的 chunk type 改成 `0x7ff4`，后面没有合法字符串池 | 在合法字符串池**前面**塞诱饵 chunk，字符串池本身完好 |
| 能不能修 | 修不了，只能从 arsc 回退包名 | **能修**：跳过诱饵后整份清单可读 |
| 已有对策 | `_fallbackFromResources` + `manifestUnparsed` | 本次新增「跳过未知 chunk」 |

两条路径并存：真的解不出来时仍走回退，能解出来时不再退化。

## 4. 修复

### 4.1 `packages/apk_parser/lib/src/binary_xml.dart`

- 新增 `_skipToStringPool()`：从 8 字节文件头之后逐 chunk 找
  `RES_XML_STRING_TABLE`，找到就回退到 chunk 起点交给 `parseStrings()`。
  与 AOSP/aapt2 同口径。
- **安全边界**：每个 chunk 先验 `chunkSize >= 8` 且 `start + chunkSize <= 文件长度`；
  跳过数量上限 256、前置字节上限 8 MiB；找不到字符串池时抛异常。
  畸形/超限文件仍然被拒绝，不会把不可信布局当成正常清单。
- `decompressToDocument()`（manifest/清单链路）与 `decompressXml()`
  （矢量图 / 自适应图标链路）**两条入口都接上**，避免只修一半。
- 保留旧的 `Invalid String table identifier` 判词：上层与既有测试靠它区分
  「清单被破坏」与「根本没有清单」。

### 4.2 不把「跳过」悄悄吞掉

`AxmlLayoutAnomalies` 新增 `skippedPrefixChunks` / `stringPoolOffset`，
`notes()` / `evidence()` 产出稳定 code `android.manifest.string_pool_prefix`
（参数 `count` / `offset`）。呈现层 `AnalysisReport.limitationNoteText` 注册该 code，
6 个语言包补上文案；`build_runner` 已重跑。

### 4.3 结果（修复后，与 aapt2 逐项一致）

```
packageName   com.jKJNPisqzojujqpK.yBjYcgXuuZmrJjjk
versionName   3.8.7.0      versionCode 178649800
minSdk 24     targetSdk 36  compileSdk 36
label         ⎄✡b⧙⎔e⁛∿t⧜3∡6⟯5⁏⭎
permissions   31 条（aapt2 的 31 条逐条比对，0 缺失）
manifestUnparsed = false     manifestFailure = null
```

官方无头探针 `PERF_APK=… flutter test tool/perf_probe_apk_test.dart`：
端到端 `open → parse → 资源表 → DEX → 加固线索 → 制品清单 → 加载链 →
载荷探测 → 安全审计 → 资源引用环` **266.8 ms 全程无错**。

## 5. 回归测试

`test/axml_prefix_chunks_test.dart`（6 条，含 1 条可选真实样本）：

- 以真实夹具 `test/fixtures/apk/signed-v2-v3.apk` 的 manifest 为底，插入
  78 个 848 字节诱饵块；期望值用 `aapt2 dump badging` 独立核对
  （`com.example.extrafixture` / `3.0` / sdk 21→29），断言清单完整解析且
  note 的 `count=78`、`offset=0x10268`。
- `decompressXml` 同样跳过诱饵（矢量图链路）。
- **反向守卫**：跳过数 > 256 时拒绝；诱饵 chunk 声明尺寸 < 8 时拒绝。
- 新 note code 走本地化，不退回英文原文。
- 可选真实样本用例：`APPINFOTOOL_HARDENED_APK=/path/to.apk` 时跑
  （样本 29 MB 且属用户数据，不入库；默认跳过）。本机已用它跑通。

## 6. 全量质量门禁

| 项 | 结果 |
|---|---|
| `flutter pub get --enforce-lockfile` / `build_runner` | 通过 |
| `dart format --output=none --set-exit-if-changed` | **416 files，0 changed** |
| 根 `flutter analyze --fatal-infos --fatal-warnings` | No issues found |
| 根 `flutter test` | **1,786 通过 / 16 跳过 / 0 失败** |
| `analysis_model` / `apk_parser` / `ipa_parser` | 141 / 218 / 245 通过，analyze 全绿 |
| `app_icon_extractor` / `archive_safety` | 通过，analyze 全绿 |

## 7. 仍然存在的边界（照实列出，不粉饰）

- manifest 的 CRC 差 1：`aapt2` 与本项目都不据此拒绝；目前只作为结构异常被记录，
  没有升级成「签名/完整性结论」。
- 612 条畸形路径名仍在包里：`artifact_inventory_scanner` 的 2000 条上限会截断，
  `hardening.dart` 的 `decoyArchiveEntries` 会把它们当加固线索。
- `classes.dex` 33.4 MB 是壳：`DexClueScanner` 单 DEX 8 MiB 预算只扫前 8 MiB，
  `android.dex.strings` 标 partial；壳内真正 DEX 仍不在静态覆盖范围。
- 若 manifest 真被破坏（11-05 那个家族），仍只有 arsc 包名回退，版本/权限/组件
  保持「没读到」，不猜。

## 8. 改动文件

**修改**：`packages/apk_parser/lib/src/binary_xml.dart`、
`lib/utils/analysis_report.dart`、
`assets/i18n/{en,zh-CN,zh-HK,zh-TW,ja,ko}.json`

**新增**：`test/axml_prefix_chunks_test.dart`、
`docs/plans/2026-11-06-hardened-axml-prefix-chunks.md`
