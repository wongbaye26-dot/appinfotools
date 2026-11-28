# LibChecker 规则数据移植规格（LibChecker-Rules v5 / dataVersion 50 → AppInfoTool）

> 状态：**调研稿，未实现**
> 日期：2026-11-28
> 参考实现：`/tmp/ApkInfoPlus`（MIT，Rust；只读克隆，commit 时点）
> 数据来源：`LibChecker/LibChecker-Rules` 的 `rules-data` 分支，**Apache-2.0**
> 目标：`/Users/wangbaye/Projects/AppInfoTool`（MIT，Flutter/Dart）
> 本文件是唯一被创建的目标仓库文件，未改动任何源码。

## 0. 结论速览

| 项 | 事实 | 对移植的影响 |
|---|---|---|
| 上游数据包 | `portable-v5.zip`，**4,651,175 B**（zip 内 `store`，未压缩；解压后 4,088,093 B / 3135 个条目） | 不能直接打进 App；必须重打包或压紧 |
| 规则数 | **3053** 条（`type` 0–9 全部）；参考实现只保留 **3039** 条（丢掉 type 6 的 14 条） | 类型 6/7/8 不存在于 v5 数据中，只有 6 有 14 条 |
| 正则规则 | **123** 条（0:78、1:9、2:22、3:1、4:5、5:8、9:0） | Dart `RegExp` 全部可编译（实测 123/123） |
| 详情文件 | **2934** 个文件 / 2,534,408 B；去重后 **891** 份 payload，合并成一份 **849,369 B**（Rust 格式）/ **520,107 B**（紧凑数组格式） | 必须去重，否则白存 1.6 MB |
| 图标 | **197** 个 SVG（+1 个 `icons/index.json`），合计 **573,833 B**；被规则引用 195 个 | 项目当前**没有** SVG 渲染依赖（无 `flutter_svg`） |
| 语言 | 只有 **zh-Hans / en** 两种（ko 只有 1 条，rule 1857） | ja/ko 界面只能回落到英文 |
| Dart 语义 | `RegExp(unicode: true)` 下 **123/123 编译通过**；上游 19 条 fixtures **19/19 通过** | 可以直接移植，无需降级正则引擎 |
| 名称补全 | 组件名补全发生在 `crates/core/src/manifest.rs:167`，**不在** `rules.rs`/`report.rs` 里 | 目标仓库的 manifest 解析器**没有**这一步，必须自己补 |
| 推荐资产 | 单个 zip（compact bundle + 195 SVG + LICENSE）≈ **498 KB** | 冷启动解析 ~760 KB JSON |
| 许可 | Apache-2.0，`LICENSE` 11,544 B；数据 zip 内**不含** LICENSE/NOTICE | 必须自带 LICENSE + 出处署名 |

移植量估计：`RuleSet.find` ≈ 120 行 Dart（含 `normalizeDigitClass`）；`analyze` ≈ 200 行；DEX 包名/标记扫描 ≈ 80 行（复用现有 `DexStructure` + `DexTables`）；图标与详情展示 ≈ 150 行；生成器 ≈ 200 行 Python。**没有**需要新写的二进制格式解析。

---

## 1. 数据来源与校验

`https://raw.githubusercontent.com/LibChecker/LibChecker-Rules/rules-data/manifest.json` 原文（实测 2026-11-28）：

```json
{"artifacts":{"android":{"minimumReaderVersion":5,"path":"releases/50/android-v5.zip","schemaVersion":5,
  "sha256":"7f4506eab1117766a7378dfb74ecb61da7fcd2ebdb4228d5c6c4682e2e93039a","size":217630},
 "legacy":{"minimumReaderVersion":4,"path":"releases/50/legacy-v4.zip","schemaVersion":4,
  "sha256":"7849bd5276d7f91c55bd425a6e5caa501776b3d97a40d54fca9a8adc5fa458da","size":3221092},
 "portable":{"minimumReaderVersion":5,"path":"releases/50/portable-v5.zip","schemaVersion":5,
  "sha256":"9c7acc036dc628ae0cfd27604b1ccf8ee3deadd7d3cddea2e66b9b42b40edbd7","size":4651175}},
 "compilerRevision":"d09fc13240cd92fca9c7b5abb2baf4f3a9c4122db1f1e67e110e336383b4e0c2",
 "contentSha256":"cfe37f088d456620d2251901c6e5b5ff7d1d9aeaa9198b1ac252f73ab5ffe6c5",
 "dataVersion":50,"minimumReader":{"android":5,"portable":5},"ruleCount":3053,"schemaVersion":5,
 "sourceRevision":"50b60fe3381e02b6f6078df36f4c72aa7bc599f8"}
```

要点：

- `artifacts.portable.path` **相对 manifest 所在目录**（`rules-data/` 根），即 `https://raw.githubusercontent.com/LibChecker/LibChecker-Rules/rules-data/releases/50/portable-v5.zip`。
- 解析 `path` 前必须拒绝含 `..` 或以 `/` 开头的值（`crates/core/src/libchecker/update.rs` 已这么做）。
- 校验顺序：先 `size`，再 `sha256`（大小写不敏感比较）——只比 sha 不比 size 会在截断下载上浪费一次哈希。
- `minimumReader.portable > 5` 或 `schemaVersion != 5` → 拒绝。`android` 产物是给 Kotlin 端用的，Dart 端不用。
- `contentSha256` 是**规则内容**的摘要，与 zip 的 sha256 不同；我们的 bundle 里两者都记，便于排查"数据换了但 manifest 没换"。

解压后目录（`/tmp/libchecker/extracted`）：

```
metadata.json                 326 B
core.json                 964,037 B   （压缩得很紧，无空格）
matching-fixtures.json      3,651 B
details/<UUID>/<id>.json   2,934 个文件，2,534,408 B
icons/<iconId>.svg           197 个文件
icons/index.json               1 个文件
```

zip 里**没有** LICENSE / NOTICE（3135 个条目全部是上面这些）。LICENSE 要从仓库根另取：`https://raw.githubusercontent.com/LibChecker/LibChecker-Rules/v4/LICENSE`（11,544 B，Apache-2.0 全文，无版权行）。

---

## 2. 字段 schema

### 2.1 `metadata.json`（7 个字段，全部必读）

```json
{"compilerRevision":"d09fc13240cd92fca9c7b5abb2baf4f3a9c4122db1f1e67e110e336383b4e0c2",
 "contentSha256":"cfe37f088d456620d2251901c6e5b5ff7d1d9aeaa9198b1ac252f73ab5ffe6c5",
 "dataVersion":50,
 "minimumReader":{"android":5,"portable":5},
 "ruleCount":3053,
 "schemaVersion":5,
 "sourceRevision":"50b60fe3381e02b6f6078df36f4c72aa7bc599f8"}
```

| 字段 | 类型 | 用途 |
|---|---|---|
| `schemaVersion` | int | 必须 == 5 |
| `dataVersion` | int | 规则版本，单调递增；用于"要不要更新"和缓存失效 |
| `ruleCount` | int | 必须 == `len(core.rules)`（3053） |
| `minimumReader.portable` | int | 必须 <= 5 |
| `sourceRevision` / `compilerRevision` | hex string | 溯源 |
| `contentSha256` | hex string | 内容摘要 |

### 2.2 `core.json` 与单条规则

顶层只有两个键：`{"schemaVersion": 5, "rules": [...]}`，3053 条。规则对象 12 个字段（`serde(rename_all = "camelCase")`）：

| 字段 | 类型 | 说明 |
|---|---|---|
| `id` | u32 | 全表唯一（3053/3053），但**不连续**：1..3154 之间有 **101 个空洞**（86、94、114、123、178…）；**`priority` 恒等于 `id`**（3053/3053）。不要把 `id` 当数组下标 |
| `uuid` | string | 规则所属"库"的 UUID，同时是详情目录名 |
| `name` | string | **匹配键**：literal 名，或正则源串（当 `isRegexRule`） |
| `label` | string | 展示名（中文），分组键的一半 |
| `type` | u8 | 0 native / 1 service / 2 activity / 3 receiver / 4 provider / 5 dex / 6 static / 9 action |
| `iconId` | string \| null | 图标文件名（不含 `.svg`）；null 表示无图标 |
| `iconIndex` | int | 上游图标表下标（-1 = 无），与 `icons/index.json` 对应；**Rust 侧不反序列化**，Dart 也不需要 |
| `isSimpleColorIcon` | bool | 单色图标，可用主题色 tint |
| `isRegexRule` | bool | true 时 `name` 是正则 |
| `regexName` | string \| null | **符号名不是正则**（如 `regex_amap_sdk`、`regex_hapjs`，123 条里只有 56 个不同值）。**不要拿它编译正则** |
| `priority` | u32 | 排序键；升序优先。dv50 全部等于 `id`，但**不要**假设永远如此（生成器里断言，变化时保留字段） |
| `detailPath` | string \| null | `details/<uuid>/<id>.json`；2934 条非空 |

各类型真样例（原样，按 key 排序后打印）：

```jsonc
// type 0 native，literal，单色图标
{"detailPath":"details/DAA626BA-CBC2-4265-B2C7-145D8527EBAA/1.json","iconId":"ic_lib_tencent","iconIndex":48,"id":1,"isRegexRule":false,"isSimpleColorIcon":true,"label":"信鸽推送","name":"libxguardian.so","priority":1,"regexName":null,"type":0,"uuid":"DAA626BA-CBC2-4265-B2C7-145D8527EBAA"}

// type 0 native，正则
{"detailPath":"details/9B679884-4D19-408E-88DB-1F15B2EFF1D7/167.json","iconId":"ic_lib_amap","iconIndex":6,"id":167,"isRegexRule":true,"isSimpleColorIcon":true,"label":"高德地图 SDK","name":"libAMapSDK_MAP_v(.*)\\.so","priority":167,"regexName":"regex_amap_sdk","type":0,"uuid":"9B679884-4D19-408E-88DB-1F15B2EFF1D7"}

// type 1 service，literal
{"detailPath":"details/7F95A4F6-AFD2-451D-B835-1B969E7A53A4/183.json","iconId":"ic_lib_xiaomi","iconIndex":62,"id":183,"isRegexRule":false,"isSimpleColorIcon":false,"label":"MiPush","name":"com.xiaomi.mipush.sdk.MessageHandleService","priority":183,"regexName":null,"type":1,"uuid":"7F95A4F6-AFD2-451D-B835-1B969E7A53A4"}

// type 1 service，正则（注意 `.(.*)` 的点没转义 —— 上游就这样，照抄）
{"detailPath":"details/FD6B295F-6973-4D71-96E2-4EE19545FE26/189.json","iconId":"ic_lib_hapjs","iconIndex":25,"id":189,"isRegexRule":true,"isSimpleColorIcon":true,"label":"快应用","name":"org.hapjs.(.*)","priority":189,"regexName":"regex_hapjs","type":1,"uuid":"FD6B295F-6973-4D71-96E2-4EE19545FE26"}

// type 2 activity
{"detailPath":"details/4FD31734-31F8-4FAB-B6DB-5B98ACB0ADD3/287.json","iconId":"ic_lib_tencent","iconIndex":48,"id":287,"isRegexRule":false,"isSimpleColorIcon":true,"label":"米大师","name":"com.tencent.midas.wx.APMidasWXPayActivity","priority":287,"regexName":null,"type":2,"uuid":"4FD31734-31F8-4FAB-B6DB-5B98ACB0ADD3"}

// type 3 receiver
{"detailPath":"details/D656C0C1-8EBD-4BE3-AFA2-492B89C2B690/374.json","iconId":"ic_lib_getui","iconIndex":82,"id":374,"isRegexRule":false,"isSimpleColorIcon":true,"label":"Meizu Push(GeTui Proxy)","name":"com.igexin.sdk.FlymePushReceiver","priority":374,"regexName":null,"type":3,"uuid":"D656C0C1-8EBD-4BE3-AFA2-492B89C2B690"}

// type 4 provider（有图标）
{"detailPath":"details/DA771D36-4047-46ED-93D6-5F2794211BBF/428.json","iconId":"ic_lib_sensors","iconIndex":44,"id":428,"isRegexRule":false,"isSimpleColorIcon":true,"label":"神策分析 SDK","name":"com.sensorsdata.analytics.android.sdk.SensorsDataContentProvider","priority":428,"regexName":null,"type":4,"uuid":"DA771D36-4047-46ED-93D6-5F2794211BBF"}

// type 4 provider（无图标：iconId=null、iconIndex=-1，但 isSimpleColorIcon 仍为 true）
{"detailPath":"details/E848DA37-070B-4C3C-B045-FA3532E96C95/429.json","iconId":null,"iconIndex":-1,"id":429,"isRegexRule":false,"isSimpleColorIcon":true,"label":"OkDownload","name":"com.liulishuo.okdownload.OkDownloadProvider","priority":429,"regexName":null,"type":4,"uuid":"E848DA37-070B-4C3C-B045-FA3532E96C95"}

// type 5 dex，literal（包前缀），无详情
{"detailPath":null,"iconId":"ic_lib_material","iconIndex":33,"id":478,"isRegexRule":false,"isSimpleColorIcon":false,"label":"Material Design Components","name":"com.google.android.material","priority":478,"regexName":null,"type":5,"uuid":"FB560233-B6F0-53F8-B764-8DA2E6BBC4DE"}

// type 5 dex，正则
{"detailPath":null,"iconId":"ic_lib_square","iconIndex":47,"id":553,"isRegexRule":true,"isSimpleColorIcon":true,"label":"OkHttp3","name":"okhttp3\\.(.*)","priority":553,"regexName":"regex_okhttp3","type":5,"uuid":"CD835122-9111-51BB-B70D-91551169AD96"}

// type 9 action（完整 action 字符串）
{"detailPath":"details/0EA939B4-805A-4D08-9C68-47C745EB49E5/2286.json","iconId":"ic_lib_jetpack","iconIndex":28,"id":2286,"isRegexRule":false,"isSimpleColorIcon":false,"label":"Jetpack ProfileInstaller","name":"androidx.profileinstaller.action.BENCHMARK_OPERATION","priority":2286,"regexName":null,"type":9,"uuid":"0EA939B4-805A-4D08-9C68-47C745EB49E5"}
```

### 2.3 详情 JSON（`details/<uuid>/<id>.json`）

```json
{"data":[{"data":{"description":"让库能够提前预填充要由 ART 读取的编译轨迹。",
                   "dev_team":"Google",
                   "label":"Jetpack ProfileInstaller",
                   "rule_contributors":["Absinthe"],
                   "source_link":"https://developer.android.com/jetpack/androidx/releases/profileinstaller"},
          "locale":"zh-Hans"},
         {"data":{...},"locale":"en"}],
 "uuid":"0EA939B4-805A-4D08-9C68-47C745EB49E5"}
```

| 字段 | 类型 | 说明 |
|---|---|---|
| `uuid` | string | 与规则的 `uuid` 相同 |
| `data[].locale` | string | 只有 `zh-Hans`、`en`（+ 1 条 `ko`） |
| `data[].data.label` | string | 可能 ≠ `rule.label`（179 条不一致，见 §11） |
| `data[].data.dev_team` | string | 2 条为空 |
| `data[].data.description` | string | 最长 1410 字符，总计 892,983 字符 |
| `data[].data.source_link` | string | 28 条为空 |
| `data[].data.rule_contributors` | string[] | 常见单元素 |

统计：2934 个文件、`zh-Hans` 2934 条、`en` 2934 条、`ko` 1 条（`rule 1857` Naver Map）；按 `data` 数组去重后只有 **891** 份不同 payload。零缺字段、零孤儿文件、零缺失文件（`detailPath` 与文件一一对应）。

### 2.4 `icons/index.json`

198 个键（`"-1"` 加 `"0"`..`"196"`）：

```json
{"-1":{"iconId":null,"isSimpleColorIcon":true},
 "0":{"iconId":"ic_lib_360","isSimpleColorIcon":false},
 ...}
```

它只是 `iconIndex → (iconId, isSimpleColorIcon)` 的映射，和规则里的 `iconIndex/iconId/isSimpleColorIcon` 完全一致（3053/3053 校验通过）。**Dart 可以整体忽略它**：规则自带 `iconId`，文件路径直接 `icons/<iconId>.svg`。

### 2.5 `matching-fixtures.json`（语义回归金标）

```json
{"schemaVersion":5,
 "cases":[
   {"expected":2,"input":"foo","name":"exact precedence","type":0,
    "rules":[{"id":1,"isRegexRule":true,"name":"foo|bar","priority":2,"type":0},
             {"id":2,"isRegexRule":false,"name":"foo","priority":20,"type":0},
             {"id":3,"isRegexRule":true,"name":".*","priority":10,"type":0}]},
   ...]}
```

| 字段 | 类型 | 说明 |
|---|---|---|
| `schemaVersion` | int | 5 |
| `cases[].name` | string | 用例名（下面 19 条全文列出） |
| `cases[].type` | u8 | 查询用的类型 |
| `cases[].input` | string | 候选名 |
| `cases[].expected` | int \| null | **命中的规则 `id`**（不是下标！`alternation` 用 `expected:1` 命中 `id=1` 的 `foo|bar`，而下标 1 是 `foo`，会失败）；null = 不命中 |
| `cases[].rules[]` | object | 该用例**独占**的 5 字段规则集：`id/name/priority/isRegexRule/type`（没有 `label`、`uuid`） |
| `cases[].useRegex` | bool，可缺省 | 缺省 = true；`false` 表示走"只精确"路径 |

19 条用例全部清单（types 18×0 + 1×1；9 条 `expected` 为 null；1 条带 `useRegex:false`）：

`exact precedence`、`alternation`、`anchoring`、`final newline`（输入 `"bar\n"` → null）、`literal regex exact`（输入 `foo|bar` 精确命中正则规则）、`escaped dot`、`escaped dot negative`、`Unicode literal`（`库[0-9]+` 命中 `库12`）、`ASCII digits`（`lib\d+` 不命中 `lib١`）、`line separator`（输入含 U+2028 → null）、`non-BMP input`（`.` 命中 `😀`）、`regex disabled`、`wrong type`、`digit class ascii`（`[\d]+` 命中 `123`）、`digit class unicode`（`[\d]+` 不命中 `١`）、`literal slash d`（`\\d+` 命中 `\ddd`）、`literal slash unicode`、`slash then digits`（`\\\d+` 命中 `\123`）、`slash then unicode`。

这 19 条直接搬成 Dart 单元测试即可（见 §5.4）：**实测 19/19 通过**（`expected` 按 id 解析、`unicode: true`）。

---

## 3. 统计

### 3.1 按类型（3053 条）

| type | 含义 | 规则数 | 其中正则 | 有 `detailPath` | 无详情 |
|---|---|---|---|---|---|
| 0 | native | **1636** | 78 | 1628 | 8 |
| 1 | service | **296** | 9 | 294 | 2 |
| 2 | activity | **599** | 22 | 590 | 9 |
| 3 | receiver | **146** | 1 | 145 | 1 |
| 4 | provider | **173** | 5 | 169 | 4 |
| 5 | dex | **82** | 8 | **0** | 82 |
| 6 | static | 14 | 0 | 1 | 13 |
| 9 | action | **107** | 0 | 107 | 0 |
| 合计 | | 3053 | **123** | 2934 | 119 |

参考实现保留 0–5 + 9 = **3039** 条，type 6 的 14 条在加载时被 `retain` 丢掉（`rules.rs:SUPPORTED_TYPES`）。**type 5 一条详情都没有**（上游没写），所以 DEX 分组只能显示 label + 图标。

### 3.2 正则规则细节

- 123 条，`isRegexRule=true`；`regexName` 56 个不同值（同一 SDK 的多个正则共用一个符号名，例如 `regex_amap_sdk`），**只能当 key 用**。
- 含 `\d` 的只有 3 条：`1278`（`(libpython([1-9]\d*\.?\d*)|(0\.\d*[1-9]))(m)?\.so`）、`2576`（`libSnpeDspV\d+(Calculator)?Stub\.so`）、`2577`（`libsnpe_dsp_v\d{2}_domains_v\d+_skel\.so`）。`normalize_digit_class` 只影响这 3 条。
- 含 `$` 的 5 条（都在 `type 2/1`，字节跳动 mira stub 壳）：`1363`–`1366`、`1370`，形如 `com\.bytedance\.mira\.stub\.p[0-9]*\.StubStandardActivity[0-9]*$`。外面再套一层 `^(?:…)$` 变成 `^(?:…$)$` —— 双重锚定，语义不变（实测正常）。
- 最长 73 字符：`com\.qihoo360\.replugin\.component\.service\.server\.PluginPitService(.*)`。
- **没有** lookbehind / `\p{…}` / `\A` / `\z` / 占有量词 / 反向引用 / inline flag；`(?:` 出现 0 次（包装是我们加的）。
- 8 条 DEX 正则：`550`–`557`，分别是 `kotlin\.coroutines\.(.*)`、`kotlinx\.coroutines\.(.*)`、`kotlin\.(.*)`、`okhttp3\.(.*)`、`retrofit2\.(.*)`、`okio\.(.*)`、`com\.alipay\.(.*)`、`io\.flutter\.(.*)`。

### 3.3 label / 图标 / 语言

| 项 | 数量 |
|---|---|
| 不同 `label` | **928** |
| 不同 `(label, iconId)` | **940** |
| `iconId == null` 的规则 | 747（全部 `isSimpleColorIcon=true`） |
| `isSimpleColorIcon=true` 且有图标 | 766 |
| 同一 label 有多个 `iconId` | **12** 个 label（如 `Mtop SDK`：`ic_lib_alibaba` / `ic_lib_aliyun`；`腾讯移动推送`：`ic_lib_tencent` / `ic_lib_tencent_cloud`；`Agora RTC SDK`：无图标 / `ic_lib_agora`） |
| 详情语言 | `zh-Hans`、`en`（+1 条 `ko`） |
| 引用到的图标 | 195 个（197 个文件里 2 个没人用） |

`label` 有 12 个会因 `iconId` 不同被拆成两组——这是参考实现的分组键 `(label, iconId)` 的直接后果，`sdk_count` 也会把它们算成 2 个 SDK。要接受这一点（与 LibChecker 一致），或者改成只按 label 分组（会与上游数字不一致）。

### 3.4 体积

| 对象 | 原始 | gzip |
|---|---|---|
| `portable-v5.zip`（store） | **4,651,175 B** | — |
| 解压后全部内容 | 4,088,093 B | — |
| `core.json` | 964,037 B | 130,912 B |
| `metadata.json` | 326 B | — |
| `matching-fixtures.json` | 3,651 B | — |
| `details/`（2934 文件） | 2,534,408 B | — |
| 合并的 `details.json`（Rust slim，891 payload + 2934 paths） | **849,369 B** | 215,926 B |
| 合并的紧凑 details（数组格式，891 payload，按规则下标引用） | **520,107 B** | 174,839 B |
| `icons/`（197 SVG） | **573,833 B** | 205,187 B（拼接后）/ 266 KB（zip 内逐文件） |
| 紧凑 rules + regexIds（数组格式） | 239,811 B | 56,052 B |
| 紧凑 bundle（rules + details + meta） | **759,992 B** | **230,573 B** |
| bundle.json + 197 SVG + LICENSE 打成 deflate zip | — | **498,257 B** |
| 参考实现重打包 zip（元数据+core+details.json+icons+LICENSE） | — | **613,176 B** |

---

## 4. 匹配语义（`rules.rs` / `report.rs` 逐条）

### 4.1 加载

1. 读 `metadata.json` → `check_supported()`：`schemaVersion == 5` 且 `minimumReader.portable <= 5`，否则拒绝整包（不是降级）。
2. 读 `core.json`，反序列化规则。
3. `rules.retain(|r| SUPPORTED_TYPES.contains(&r.kind))`，`SUPPORTED_TYPES = [0,1,2,3,4,5,9]`。
4. 读详情（Rust 用 slim `details.json`；Dart 用 bundle 里的详情表）。
5. `rules.sort_by_key(|r| (r.priority, r.id))`。

### 4.2 索引

每类型（`HashMap<u8, TypeIndex>`）：

```rust
struct TypeIndex { exact: HashMap<String, usize>, regex: Vec<(Regex, usize)> }
```

- `exact`：在**全部**该类型规则上建（**包括 `isRegexRule` 的规则**，用其字面 `name`）。`entry(...).or_insert(i)` → 重复键时**先插入者胜**；因为已按 `(priority,id)` 排序，等价于"priority 最小、再 id 最小"。dv50 实测 `(type,name)` 无重复，这条只是防御。
- `regex`：只收 `isRegexRule` 的规则，按上面的排序顺序 push（= priority 升序、id 升序）。
- 正则编译：`Regex::new(&format!("^(?:{})$", normalize_digit_class(&rule.name)))`。**编译失败只 warn 并跳过该条**，不影响整包（上游有测试保证"每条都能编"）。
- 大小写敏感；不做任何 trim/小写化。

### 4.3 `find(kind, name, use_regex)`

```rust
if let Some(i) = index.exact.get(name) { return Some(&rules[i]); }     // 1. 精确
if !use_regex { return None; }                                          // 2. 只精确路径
if name.contains(any of LINE_TERMINATORS) { return None; }              // 3. 行终止符 → 不跑正则
for (re, i) in index.regex { if re.is_match(name) { return Some(&rules[i]); } }  // 4. 第一条命中
None
```

- `LINE_TERMINATORS = ['\n', '\r', '\u{85}', '\u{2028}', '\u{2029}']`。这道闸门是"正则不许跨行"的显式语义，**必须在 Dart 里照抄**（`\u0085` 在 Dart 的 `.` 里是匹配的，与 Rust 不同，靠这道闸门兜住）。
- 精确阶段**不**检查行终止符（所以含 `\n` 的候选名仍可能精确命中，虽然实际上没有这种规则）。
- 返回 `Option<&Rule>`，调用方用 `rule.name == candidate` 区分 `MatchSource::Exact` / `Regex`（`source_of`）。

### 4.4 `normalize_digit_class(pattern)`

逐字符扫描，维护 `in_class`：

| 输入 | 状态 | 输出 |
|---|---|---|
| `\d` | 不在 class | `[0-9]` |
| `\d` | 在 class | `0-9` |
| `\X`（其它） | 任意 | 原样 `\X` |
| 末尾孤立 `\` | — | `\` |
| `[` | 在 class 内 | `\[`（转义，防嵌套） |
| `[` | 不在 class | `[`，并进入 class；若下一个是 `^` 一并吞掉（`[^` 保留） |
| `]` | 在 class 内 | `]`，退出 class |
| `&`/`-`/`~` | 在 class 内且下一个字符相同 | 转义（`\&` / `\-` / `\~`） |
| 其它 | — | 原样 |

作用：把 PCRE 风格的 `\d`（Unicode 数字）降级为 ASCII 数字类，避免 `lib١` 命中 `lib\d+`。**Dart 的 `\d` 本来就是 ASCII**，所以这一步在 Dart 上不影响结果；但为了与 fixtures 的 `[\d]+` 用例、以及未来换成 `\d{2,}` 之类的写法保持同构，建议照抄（成本 20 行）。

### 4.5 详情与语言

- `detail(rule, lang)`：先查 slim `details.json` 的 `paths[detail_path]`，再退到 zip 里读 `details/<uuid>/<id>.json`；`None` 表示没有详情。
- `pick_locale(entries, lang)`：**精确等于 `lang`**，否则 `"en"`，否则第 0 条。没有"前缀匹配"、没有"zh-Hant→zh-Hans"。
- 目标仓库 i18n 是 `en/ja/ko/zh-CN/zh-HK/zh-TW`：`zh-CN/zh-HK/zh-TW → "zh-Hans"`，`en → "en"`，`ja/ko → 精确失败 → "en"`。rule 1857 有 `ko`，若想利用，需显式 `locale == "ko"` 的映射（只有 1 条，建议不做）。

### 4.6 native 校验（"过于常见的库名要旁证"）

```rust
fn passes_native_validation(name, all_names, markers) -> bool {
  "libjiagu.so"|"libjiagu_a64.so"|"libjiagu_x86.so"|"libjiagu_x64.so" => markers.qihoo,
  "libDexHelper.so"|"libDexHelper-x86.so"|"libdexjni.so" => markers.secneo,
  "libapp.so" => all_names.contains("libflutter.so") || markers.flutter_injector,
  "libmain.so" => all_names.contains("libunity.so"),
  _ => true,
}
```

- 校验失败 → 该库**记为未匹配**（`unmatched_native`），**不再**退到其它规则。
- `all_names` = APK 内**全部** ABI 的原生库文件名去重集合（不是当前这条所在的 ABI）。
- 标记来自 DEX `class_defs` 的类描述符（`crates/core/src/dex.rs:44-66`）：
  - `qihoo`：描述符以 `Lcom/qihoo/util/` **或** `Lcom/tianyu/util/` 开头；
  - `secneo`：以 `Lcom/secneo/apkwrapper/` 开头；
  - `flutter_injector`：描述符**恰好等于** `Lio/flutter/FlutterInjector;`；
  - （另有 `kotlin`：类前缀 `Lkotlin/`，或 `string_ids` 里出现 `Lkotlin/Metadata;`；`compose`：`Landroidx/compose/`。这两个不参与 LibChecker 匹配，只用于"技术栈"展示。）
- 原生库入参口径（`crates/core/src/info.rs:254`）：zip 条目必须是 `lib/<abi>/<file>` **恰好两段**、`<file>` 以 `.so` 结尾；`name` 是**纯文件名**；按 `(abi, name)` 排序。→ 上游 10 条不以 `.so` 结尾的 native 规则（`1132 libarmepic`、`1835 libbspatch_utils`、`1898 libxwebfullpack.so.bak`、`2517 libKcsdk-2.0.9` 等）是**死规则**，永远匹配不到；保留即可，不要为此放宽 `.so` 过滤（放宽会带进 `.so.bak` 之类并被计入统计）。

### 4.7 组件匹配（含名称补全与 action 回退）

```rust
fn match_component(rules, c) -> Option<(rule, source)> {
  let kind = match c.kind { Activity=>2, Service=>1, Receiver=>3, Provider=>4 };
  if let Some(r) = rules.find(kind, &c.name, /*use_regex*/ true) { return Some((r, source_of(r,&c.name))); }
  c.actions.iter().find_map(|a| rules.find(9, a, /*use_regex*/ false)).map(|r| (r, Action))
}
```

- 组件名**先补全**（`crates/core/src/manifest.rs:167`，这是 `report.rs` 之外的一步）：

  ```
  ".Foo"      → "<package>.Foo"
  "Foo"（无点）→ "<package>.Foo"
  其它         → 原样
  ```
  目标仓库 `packages/apk_parser/lib/src/manifest_parser.dart:200` 只存 `child.attributes['name']` 原值，**没有补全**——移植时必须补，否则 `.ui.MainActivity` 这类声明全部匹配不到（规则里全是全限定名）。
- `activity-alias` 也算 Activity（type 2），且用**别名自己的名字**匹配（不是 `targetActivity`）。Dart 的 `ComponentType.activityAlias` 要映射到 2。
- 没有 `name`（null / 空）的组件跳过。
- `actions`：所有 `<intent-filter>` 下的 `<action android:name>`，**去重保序**（首次出现顺序），跨 filter 展平。
- action 阶段**只用精确匹配**（`use_regex=false`），且是"第一个命中的 action"（manifest 顺序），不是"最高优先级"。
- 组件路径不对 action 回退再退回：命中不了就是没命中。

### 4.8 DEX 包匹配

输入是 `packages`：从每个 `classes*.dex` 的 `class_defs` 取类描述符，`Lcom/foo/Bar;` → `com.foo`（最后一个 `/` 之前、`/`→`.`；无 `/` 的默认包丢弃；非 `L…;` 丢弃）。计数是"该包直接定义的类数"，遍历时按 `BTreeMap` 输出**字典序**（`report.rs:103`，所以 `dex_packages` 是排序后的列表，分组 `items` 下标指向它）。

```rust
fn match_package(rules, pkg) {
  let mut p = pkg;
  loop {
    if let Some(r) = rules.find(5, p, /*use_regex*/ false) { return Some((r, Exact)); }  // 最长前缀
    match p.rfind('.') { Some(i) => p = &p[..i], None => break }
  }
  rules.find(5, pkg, /*use_regex*/ true).map(|r| (r, Regex))   // 再拿完整包名试正则
}
```

- 精确阶段是**祖先链逐级剥离**：`a.b.c.d` → `a.b.c.d`、`a.b.c`、`a.b`、`a`。第一个命中的就是"最长前缀"，返回 `MatchSource::Exact`。
- 正则只在**完整包名**上试一次，不试祖先（所以 `kotlin` 这个包本身不会被 `kotlin\.(.*)` 命中——需要至少一级子包）。
- 同一个 DEX 包只计一次（无论如何命中）。

### 4.9 分组、排序、`sdk_count`

三个独立的分组器（native / components / dex），组键 **`(label, iconId)`**：

- `items`：命中项下标（按输入顺序 push；native 是 `ApkInfo::native_libs` 下标，components 是 `meta.components` 下标，dex 是排序后的 `dex_packages` 下标）。
- `sources`：与 `items` 一一对应的 `Exact/Regex/Action`。
- 组内 `rule` = **第一条**命中的规则（用于取详情、图标），`simple_color_icon` 也取自它。
- 排序 `finish`：`BTreeMap<(Reverse(count), label, insertion_index)>` → **count 降序 → label 升序（UTF-8 字节序）→ 插入顺序**。`insertion_index` 只在"同 label 不同 iconId 且 count 相同"时生效（即 §3.3 那 12 个 label）。
- count 口径：
  - native：组内**去重库名**数（同一 `.so` 出现在 3 个 ABI 只算 1）；
  - components：`items.len()`（组件条数）；
  - dex：`items.len()`（包条数）。
- `sdk_count()`：三组并集里不同 `(label, iconId)` 的个数。**跨组也算**（同一 SDK 同时在 native 与 dex 命中只算 1）。
- `data_version` 透传 `metadata.dataVersion`；`unmatched_native` 是未命中的 native 下标列表（UI 用来列"未知原生库"）。

### 4.10 边界语义速查

| 情形 | 行为 |
|---|---|
| 大小写 | 全敏感（`libKcsdk-2.0.9` 不会匹配 `libkcsdk`） |
| 候选名含 `\n`/`\r`/U+0085/U+2028/U+2029 | 精确阶段照常，正则阶段**跳过** |
| 候选名含非 BMP（emoji） | Dart 需 `unicode: true` 才能让 `.` 匹配（fixtures `non-BMP input` 要求 `1`） |
| 正则编译失败的规则 | 跳过该条（不报错），精确阶段仍可用其字面名 |
| 同一 `(type,name)` 重复 | 先插入者胜（= priority/id 小者）；dv50 无重复 |
| 空名候选 | 不会命中（除非有 `name == ""` 的规则，无） |
| `use_regex=false` | 只走精确（DEX 前缀链、action 阶段） |

---

## 5. Dart 可行性

### 5.1 实测结论

环境：Dart SDK **3.13.5**（`/Users/wangbaye/development/flutter/bin/dart`；`dart` 不在默认 PATH）。脚本 `/tmp/libchecker/darttest/final_check.dart` 做了两件事：

1. 读 `core.json`，对**每条** `isRegexRule` 规则编译 `RegExp('^(?:' + normalizeDigitClass(name) + r')$', unicode: true)`；
2. 读 `matching-fixtures.json`，按 `expected == 规则 id` 语义跑 19 条。

结果：

```
regex rules: 123, compiled: 123, failures: 0
fixtures: 19/19 pass (pass=19 fail=0)
```

抽样：`libflutter.so → 71`（exact）、`libAMapSDK_MAP_v9.1.0.so → 167`（regex）、`okhttp3.internal.http → 553`（regex）、`com.tencent.midas.wx.APMidasWXPayActivity → 287`（exact）。

不加 `unicode: true` 时 123 条也都能编译，但 `non-BMP input` 这条 fixture 会失败（18/19）——**必须加 `unicode: true`**。

### 5.2 与 Rust 的差异（可接受 / 需处理）

| 差异 | 影响 | 处理 |
|---|---|---|
| Dart `\d` = ASCII（无 unicode 数字） | 与 Rust+`normalize_digit_class` 结果一致 | 照抄 normalize（无害，保证 `[\d]+` 的 fixture 语义） |
| Dart `.` 匹配 U+0085，Rust 不匹配 | 仅"含 U+0085 的名字 + 真需要 `.`"的场景 | 行终止符闸门已跳过正则，**无影响** |
| Dart `$` 不匹配尾部 `\n` 前的位置 | 与 Rust 一致（fixture `final newline` 要求 null） | 无需处理 |
| 非 BMP 需 `unicode: true` | 缺 flag 时 `.` 不匹配 emoji | 统一 `unicode: true` |
| `unicode: true` 下未转义的 `]`/`-`/`&` 类语义 | 我们照抄上游字符串，未新增写法 | 无 |
| `^`/`$` 默认为"整串"（无 multiline） | 与 Rust 一致 | 不要开 `multiLine` |
| Rust 的 `(?:…)` 里 `$` 重复锚定 | 语义等价 | 无需处理 |

**没有任何规则因语法失败**：123 条里不含 lookbehind、`\p{}`、`\A`、`\z`、占有量词、反向引用、inline flag；只用到 `\d`（3 条）和 `$`（5 条）。所以**不需要**降级到第三方正则库（如 `re2`/`pcre` 绑定）。

### 5.3 `find` 的 Dart 骨架

```dart
final class LibCheckerRule {
  final int id;
  final String name;      // literal 或正则源串
  final String label;
  final int type;
  final String? iconId;
  final bool simpleColorIcon;
  final bool isRegex;
  final int detailIndex;  // -1 = 无详情
  LibCheckerRule({...});
}

final class _TypeIndex {
  final Map<String, LibCheckerRule> exact = HashMap();
  final List<(RegExp, LibCheckerRule)> regex = [];   // 已按 (priority,id) 排序
}

final class LibCheckerRules {
  final int dataVersion;
  final List<LibCheckerRule> rules;          // 已按 (priority,id) 排序
  final Map<int, _TypeIndex> index = {};
  final Map<int, LibCheckerRule> byId = {};
  final List<List<LibCheckerLocale>> details; // detailIndex → 语言条目

  static const _lineTerminators = ['\n', '\r', '\u0085', '\u2028', '\u2029'];

  LibCheckerRule? find(int type, String name, {bool useRegex = true}) {
    final t = index[type];
    if (t == null) return null;
    final e = t.exact[name];
    if (e != null) return e;
    if (!useRegex) return null;
    for (final ch in _lineTerminators) {
      if (name.contains(ch)) return null;
    }
    for (final (re, rule) in t.regex) {
      if (re.hasMatch(name)) return rule;
    }
    return null;
  }
}
```

要点：

- `RegExp` 只编译一次（构造索引时），用 `unicode: true`，`try { } on FormatException { /* skip rule */ }` 对齐 Rust 的"跳过失败规则"。
- 正则列表顺序**必须**保持 `(priority, id)` 升序；不要按字符串或类型重排。
- `exact` 里要放**所有**规则（含正则规则的 `name` 字面值），与 Rust 一致。

### 5.4 自测（4 个必做）

1. **全量编译**：`assert(compiled == 123)`，并打印失败 id（当前为空）。
2. **fixtures**：19/19（`expected` 按 `id` 解析）。
3. **金标计数**：`rules.length == 3039`、`regex == 123`、`details.payloads == 891`、`icons == 197`。
4. **冒烟**：`find(0,'libflutter.so')!.label == 'Flutter'`；`find(5,'com.tencent.smtt.sdk')` 命中 X5；`find(5,'com.tencentx') == null`（包边界）；`find(5,'okhttp3.internal.http')` 命中 OkHttp3。

DEX 侧：`com.tencent.smtt.sdk` 命中 X5、`com.tencentx` 不命中（必须按 `.` 边界剥前缀，不能 `startsWith`）；`okhttp3.internal.http` 只能通过正则命中（`okhttp3` 本身不会被 `okhttp3\.(.*)` 命中）。

---

## 6. 推荐资产设计

### 6.1 方案对比

| 方案 | 内容 | 体积 | 优点 | 缺点 |
|---|---|---|---|---|
| **A（推荐）** | 单 zip：`bundle.json` + `icons/*.svg` + `LICENSE` + `fixtures.json` | **498,257 B** | 一个资产声明、版本原子、图标按需解压、可放 fixtures | 需要自定义 bundle 格式（生成器 ~200 行） |
| B | 参考实现式重打包 zip（`metadata/core/details.json/icons`） | 613,176 B | 与 Rust 加载器同构，语义零翻译 | 比 A 大 23%；`details.json` 的 `paths` 映射白占 ~160 KB |
| C | 纯 JSON（bundle.json 原样）+ 图标目录资产 | 759,992 B（gzip 230,573）+ 573,833 B | 无需 zip 解析、图标可用 `SvgPicture.asset` 缓存 | APK 里要放 195 个独立资产条目；JSON 未压缩解析 |
| D | 上游 `portable-v5.zip` 原样打入 | 4,651,175 B | 零生成器 | APK +4.6 MB，不可接受 |

**推荐 A**：`assets/libchecker/libchecker_v5.zip`（≈498 KB）。理由：

- 目标仓库已有 `archive` 4.0.9（git fork，`huanfeng/archive`）依赖，`ZipDecoder().decodeBytes` 在 `packages/apk_parser/lib/src/apk_reader.dart:151` 已在用；该版本 `ArchiveFile.readBytes()/content` **按需解压**（`archive_file.dart:181`，`getContent()` 里 `if (_content == null) decompress()`），所以 197 个 SVG 只有真正显示时才解压，不会拖慢冷启动。
- 单资产 → `pubspec.yaml` 只加一行，更新时整个文件替换，不会出现"规则新、图标旧"的半更新状态。

### 6.2 推荐 bundle 格式（生成器产物）

```
libchecker_v5.zip
├── bundle.json          # 760 KB（未压缩），deflate 后 232 KB
├── icons/ic_lib_*.svg   # 195 个在用图标（可保留全部 197，差 <2 KB）
├── fixtures.json        # 3,651 B，上游原样，供单测
└── LICENSE              # 11,544 B，Apache-2.0 原文
```

`bundle.json`（紧凑数组，实测 759,992 B）：

```json
{
  "meta": {"schemaVersion": 5, "dataVersion": 50,
           "sourceRevision": "50b60fe3…", "contentSha256": "cfe37f08…",
           "artifactSha256": "9c7acc03…", "generatedAt": "2026-11-28"},
  "regexIds": [167, 172, 189, ...],
  "rules": [
    [1, "libxguardian.so", "信鸽推送", 0, "ic_lib_tencent", 1, 0],
    [478, "com.google.android.material", "Material Design Components", 5, "ic_lib_material", 0, -1]
  ],
  "details": [
    {"zh-Hans": ["标签","dev_team","描述","source_link",["贡献者"]],
     "en":      ["label","dev_team","description","source_link",["contributor"]]}
  ],
  "markers": {
    "dexClassPrefixes": [
      {"prefix": "Lcom/qihoo/util/", "flag": "qihoo"},
      {"prefix": "Lcom/tianyu/util/", "flag": "qihoo"},
      {"prefix": "Lcom/secneo/apkwrapper/", "flag": "secneo"}
    ],
    "dexClassExact": [{"descriptor": "Lio/flutter/FlutterInjector;", "flag": "flutterInjector"}]
  }
}
```

- `rules[i]` 7 元组：`[id, name, label, type, iconId, isSimpleColorIcon(0/1), detailIndex]`。
  - `priority` 不存（dp50 全等于 `id`）；生成器**断言**这一点，若将来不成立则回退到 8 元组（多一个 `priority`），Dart 侧用同一个 loader 版本号区分。
  - `isRegexRule` 不逐条存，用 `regexIds`（123 个 int）表达；精确阶段本来就要把所有 `name` 放进 exact map。
  - `detailIndex` = `-1` 表示无详情。
- `details`：891 条，按 `locale → [label, dev_team, description, source_link, contributors]` 的数组存（比对象键省 ~100 KB）。注意 `label` 与 `rules[].label` **不是同一个值**（179 条不一致），展示时以 `rules[].label` 为准，详情页可显示详情里的本地化 label。
- `markers`：把 `dex.rs` 里那 4 条常量放进数据，避免 Dart 源码里再抄一遍；`kotlin/compose` 不参与匹配，可另放 `techMarkers`（可选）。
- 图标路径不入 bundle，约定 `icons/<iconId>.svg`。

### 6.3 加载与开销

```dart
final bytes = (await rootBundle.load('assets/libchecker/libchecker_v5.zip')).buffer.asUint8List();
final archive = ZipDecoder().decodeBytes(bytes);          // 只读中央目录
final bundleJson = utf8.decode(archive.findFile('bundle.json')!.readBytes()!);
final rules = LibCheckerRules.fromBundle(jsonDecode(bundleJson) as Map<String, dynamic>);
// 图标按需：archive.findFile('icons/$iconId.svg')?.readBytes()
```

估算：760 KB JSON 在移动端 `jsonDecode` 约 30–60 ms（可放到 isolate）；123 条正则编译约 2–5 ms（可延到首次 `analyze` 时懒编译）；索引内存 ≈ 3039 × 小对象 ≈ 1–2 MB，详情 891 × 5 字段 ≈ 1 MB。建议：`LibCheckerRules` 进程内单例 + `dataVersion` 作为缓存键。

---

## 7. 生成器脚本设计

位置：`tool/sync_libchecker_rules.py`（与现有 `tool/generate_icons.py` 同风格：只依赖标准库，`--dry-run`，可重复执行；哈希用 `hashlib`，不需要 `crypto` 包）。

流程：

1. `GET https://raw.githubusercontent.com/LibChecker/LibChecker-Rules/rules-data/manifest.json`（可用 `--manifest-url` / `--manifest-file` 覆盖，便于离线与回放）。
2. 校验 `schemaVersion == 5`、`minimumReader.portable <= 5`。
3. 解析 `artifacts.portable.path`：拒绝 `..` / 绝对路径；拼到 manifest 目录；下载到临时文件。
4. 校验 `size` 与 `sha256`（小写比较）；失败即中止，**不覆盖**现有资产。
5. 解压；校验 `metadata.dataVersion == manifest.dataVersion`、`metadata.ruleCount == len(core.rules)`、`schemaVersion == 5`。
6. 校验规则字段完整性：`type ∈ {0,1,2,3,4,5,6,9}`、`id` 唯一、`(type,name)` 唯一、`priority == id`（不成立则**保留 priority** 并升 bundle 版本）、`isRegexRule` 与 `regexName` 的一致性只记录不阻塞。
7. 校验详情：`detailPath` 指向的文件存在；文件内 `uuid` 与规则一致；收集 `data`，按"`data` 数组序列化后排序"去重（参考脚本用 `json.dumps(entries, ensure_ascii=False, sort_keys=True)`）→ 891 条 payload；建立 `rule.id → payloadIndex`。
8. 校验图标：每个非空 `iconId` 有 `icons/<iconId>.svg`；记录未使用图标数。
9. 生成 `bundle.json`（§6.2），写成紧凑 JSON（`separators=(',',':')`），`sort_keys=True` 只在 `meta` 上；把 `fixtures.json`、`LICENSE`（`--license-file` 或下载 `.../v4/LICENSE`）一并写入 zip：deflate level 9、**固定时间戳** `(1980,1,1,0,0,0)`、固定条目顺序（`bundle.json`、`fixtures.json`、`icons/` 升序、`LICENSE`）→ 字节级可复现。
10. 写 `assets/libchecker/libchecker_v5.zip`；打印：`dataVersion`、bundle 字节数、zip 字节数、sha256、规则/正则/详情/图标计数。
11. `--dry-run` 只打印差异（版本、体积、计数），不落盘；`--check` 只校验现有资产是否与上游一致（CI 用）。

CI 策略：**不要把生成器放进构建**（构建期联网不可接受）。资产提交进仓库，另加一个 Dart 单测（§5.4）守 123/891/3039/19 这些数字；`tool/sync_libchecker_rules.py --check` 做成手动/每周任务，输出"上游有新版"的 issue。

---

## 8. 图标

### 8.1 数据

- 197 个 `icons/ic_lib_*.svg`（文件名 == `<iconId>.svg`），合计 **573,833 B**；均值 2,912 B、中位 1,738 B、p90 5,060 B。
- 最大：`ic_lib_maa_framework.svg` 85,658 B、`ic_lib_fcitx.svg` 18,406、`ic_lib_vorbis.svg` 16,621、`ic_lib_netease.svg` 14,454、`ic_lib_xiaomi.svg` 12,190；最小 `ic_lib_jolt.svg` 254 B。
- 被规则引用的 **195** 个；2 个没人用：`ic_lib_android_ide`、`ic_lib_fcitx`（后者还是第 2 大，建议生成器剔除未用图标）。
- 56 个 `isSimpleColorIcon=true`（合计 198,475 B）：**都是单色填充**（`fill="#000000"` / `#111113` 之类），无 `currentColor`，无渐变；可以安全地按主题色 tint。
- 尺寸：`width="24" height="24"` + `viewBox`；viewBox 分布：`0 0 1024 1024` 184 个、`0 0 24 24` 3 个、`192×192`/`20×20`/`828×828`/`48×48`/`32×32`/`1058×1024`/`240×240`/`1041×1024`/`72×66`/`576×576` 各 1 个。
- 唯一没有 `width`/`height` 属性的是 `ic_lib_mediatek.svg`（只有 viewBox）——渲染时必须自己给 24×24 的约束，别依赖固有尺寸。

### 8.2 渲染方案

目标仓库**没有** `flutter_svg`/`vector_graphics`（`pubspec.yaml` 与 `pubspec.lock` 都没有，`~/.pub-cache` 里也没有），但已有 `path_drawing`（`flutter_svg` 的依赖之一）。

| 方案 | 做法 | 评价 |
|---|---|---|
| **推荐** | 新增 `flutter_svg`（`^2.x`），`SvgPicture.string(svgString, width: 24, height: 24)` | 纯 Dart，无需本地栅格化工具；197 张按需解码，可配 `ColorFilter` tint |
| 备选 | 生成器预栅格化成 PNG（24/48 dp ×3） | 体积更小、渲染更快，但本机**没有**栅格化工具：`rsvg-convert`/`resvg`/`inkscape` 都不存在，`cairosvg` 装了但缺 `libcairo-2`（`dlopen` 失败）。需要引入新工具链，不建议 |
| 最省事 | 用图标的主色画一个圆角方块 + 首字母（不渲染 SVG） | 零依赖，但丢信息，只适合降级 |

Tint 细节：简单色图标用 `ColorFilter.mode(themeColor, BlendMode.srcIn)`；非简单色图标**不要** tint（45 个非 simple 图标也只有单 fill，不能靠 fill 数判断，必须用 `isSimpleColorIcon` 元数据）。若不想加 `ColorFilter`，也可在 Dart 侧把 `fill="#000000"` 替换成目标色再 `SvgPicture.string`（56 个图标都能这么干，但语义上就别动多色图标）。

缓存：`iconId → String`（SVG 源串）用 LRU（上限 ~60）即可；`flutter_svg` 自己也有 picture cache。列表页只显示分组图标（≤ 几十个），不会一次渲染 195 张。

---

## 9. Dart 侧实现清单

### 9.1 数据模型

```dart
enum MatchSource { exact, regex, action }

final class LibCheckerHit {
  final LibCheckerRule rule;
  final MatchSource source;
}

final class SdkGroup {
  final String label;
  final String? iconId;
  final bool simpleColorIcon;
  final LibCheckerRule rule;       // 组内第一条命中
  final List<int> items;           // native/组件/包 的下标
  final List<MatchSource> sources;
  final int count;                 // native=去重库名数；其它=items.length
}

final class LibCheckerReport {
  final int dataVersion;
  final List<SdkGroup> native;
  final List<int> unmatchedNative;
  final List<SdkGroup> components;
  final List<SdkGroup> dex;
  final List<String> dexPackages;  // 与 dex 分组的 items 下标对应
  final Set<String> techMarkers;   // qihoo/secneo/flutterInjector/...
  int get sdkCount => {...}        // (label, iconId) 并集
}
```

### 9.2 `analyze` 移植要点

1. 输入：`List<(abi, name, size)>` 全量原生库（§9.3）、`List<AndroidComponent>`（补全名 + actions）、`List<String>` dex 包名（字典序）、`DexMarkers`。
2. native：`find(0, name)` → `.filter(passesNativeValidation)` → 失败进 `unmatchedNative`。
3. components：按 `AndroidComponent.type` 映射 kind（`activityAlias → 2`），`find` → 失败则按 manifest 顺序遍历 actions 做 `find(9, action, useRegex: false)`。
4. dex：`matchPackage`。
5. 分组 + 排序（`count desc, label asc, insertion`）；`sdkCount` 取并集。
6. 详情/图标按 `labels` 惰性取（分组时才查，别在 analyze 里全量解 891 份详情）。

### 9.3 DEX 包名与标记扫描

现有基础设施够用，不需要新解析器：

```dart
// apk_reader: 取 classes*.dex 字节（预算内）
// DexStructure 提供 section('class_defs')（itemSize 32）
// DexTables(bytes, structure).typeDescriptor(classIdx) 拿描述符
for (var i = 0; i < classDefs.size; i++) {
  final base = classDefs.offset + i * classDefs.itemSize;
  final classIdx = data.getUint32(base, Endian.little);
  final desc = tables.typeDescriptor(classIdx);
  if (desc == null || !desc.startsWith('L') || !desc.endsWith(';')) continue;
  final slash = desc.lastIndexOf('/');
  if (slash <= 1) continue;                       // 默认包丢弃
  final pkg = desc.substring(1, slash).replaceAll('/', '.');
  packages[pkg] = (packages[pkg] ?? 0) + 1;
  // markers: startsWith('Lcom/qihoo/util/') 等
}
```

- 多 dex 逐个累加；`class_count` 也一起累计。
- `class_defs` 的 `size` 是头部声明的 u32，必须先用 `DexSection.isWithin` 之类的边界检查（`dex_structure.dart:73` 已有 `size <= (fileSize - offset) ~/ itemSize` 的判定），否则畸形包会让循环跑到越界。
- 与 `SdkInventoryScanner`（按 `string_ids` 扫类名前缀）**职责不同**：那个统计"引用次数"，不是包名，也不是 `class_defs`。两者可并存，但**别拿 string_ids 的类名前缀冒充包名**（会混进字符串常量里形似类名的东西）。
- 预算：`class_defs` 遍历只读 type_ids，比 `string_ids` 便宜；但超大 APK（>10 万类）仍建议沿用现有 `maxDexBytes` 预算与超限标记。

### 9.4 组件输入

- 补全名（§4.7），**这是移植中最容易漏的一步**；同时把 `activityAlias` 归到 2。
- `actions` 展平 + 去重保序。
- 只处理 `<application>` 下四类元素（`manifest_parser.dart:192` 已经在做）。

### 9.5 原生库输入

`ParsedApkData.nativeLibraries` 是"预算内选出的、按名去重的、每个库一个 ABI"——**不满足** LibChecker 的需求（它要全量、要跨 ABI 名字集合做 `libapp.so`/`libmain.so` 校验、还要 native 分组按 ABI 顺序）。

建议：在解析阶段用 `reader.listFilesWithSize(extension: '.so')`（`apk_reader.dart:510`）拿全量条目，按 `lib/<abi>/<name>` 恰好两段、`name.endsWith('.so')` 过滤，按 `(abi, name)` 排序后单独存一个 `List<(abi, name)>`，供 LibChecker 使用。**不要**放宽 `.so` 过滤（见 §4.6）。

### 9.6 `sdk_count` 与 UI

- `sdkCount` = 三分组 `(label, iconId)` 并集大小；与 LibChecker 的"识别到 N 个 SDK"口径一致。
- 分组内 `sources` 可用于在条目上标"正则/action"来源（可选）。
- `unmatchedNative` 适合"未知原生库"折叠区。
- 注意：现有 `SdkDescriptor`/`SdkInventoryScanner`（`packages/apk_parser/lib/src/security/`）是**另一套**精选目录（DEX 引用计数），与 LibChecker 的 3053 条规则没有数据关系。建议**并存不合并**：一个给"安全/技术栈"用，一个给"库识别"用；如果合并，两者的 SDK 计数会互相污染，且 LibChecker 的 label 是中文的。

### 9.7 性能

- 索引构建 O(n log n)，n=3039，可忽略。
- 正则只在候选名上跑，候选量 = 原生库名 + 组件名 + 包名（通常 < 2 万），123 条正则按优先级短路，实测无压力。
- 详情与 SVG 全部惰性。
- 冷启动建议：`LibCheckerRules` 懒加载（第一次进"库识别"页时），避免拖慢 APK 首屏。

### 9.8 测试

- fixtures 19 条 → 纯 Dart 单测（不依赖 APK）。
- 计数金标（§5.4 第 3 条）。
- 真实 APK 冒烟：Flutter 应用（`libflutter.so` + `libapp.so`）、含腾讯 X5 的应用（`com.tencent.smtt.sdk`）、360 加固包（`libjiagu.so` 需 `com.qihoo.util` 旁证）、Unity 包（`libmain.so` 需 `libunity.so`）。
- 回归：把 `docs/notes/reference-permission-signature-spec.md` 的做法沿用——只创建本文件，不动源码。

---

## 10. 许可与署名

- 规则数据仓库：**Apache-2.0**（`LICENSE` 11,544 B；`portable-v5.zip` 内**不含** LICENSE/NOTICE，必须另外取）。
- Apache-2.0 §4 要求：随分发提供许可证副本、保留版权/归属声明、标注修改。
  - 资产 zip 内放 `LICENSE`（原文）。
  - `bundle.meta` 写 `sourceRevision` / `dataVersion` / `artifactSha256`（可追溯）。
  - App 的"关于/开源许可"页加一条：`LibChecker Rules (Apache-2.0), https://github.com/LibChecker/LibChecker-Rules`，并注明"本应用对其进行了重打包（去重、紧凑化），未修改规则内容"。
  - 仓库根已有 MIT；LibChecker 数据是独立许可，不要并进项目 LICENSE，单独放 `assets/libchecker/LICENSE`。
- 参考实现 `/tmp/ApkInfoPlus` 是 MIT：我们只移植语义（重写 Dart），不复制 Rust 代码，故无需在产物里附 MIT 声明；但本文件的"参考实现"标注保留。

---

## 11. 风险与未决

| # | 风险 | 证据 | 建议 |
|---|---|---|---|
| 1 | **组件名未补全** → 大量 activity/service 漏配 | 目标仓库 `manifest_parser.dart:200` 存原值；上游补全在 `manifest.rs:167` | 移植时先补全；加单测：`.Foo` / `Foo` / `a.b.Foo` |
| 2 | 无 SVG 渲染依赖 | `pubspec.yaml`/`pubspec.lock` 无 `flutter_svg`；pub-cache 也没有 | 新增 `flutter_svg`，或接受"无图标"降级 |
| 3 | `label` 两处不一致（179 条） | e.g. `id 7` core=`小米更新 SDK` / 详情=`小米应用检查更新 SDK`；`id 76` `realm` vs `Realm` | 分组与列表用 `rule.label`；详情页展示详情里的本地化 label |
| 4 | 12 个 label 因 iconId 不同被拆成 2 组 | §3.3 | 接受（与上游一致），或另加"按 label 合并"的展示开关 |
| 5 | 只有 zh-Hans / en | 2934 / 2934 / 1(ko) | ja/ko 用户看到英文；如需日韩文案只能自己补（不建议） |
| 6 | 82 条 DEX 规则全无详情 | `detailPath` 全 null | DEX 分组只显示 label+图标；不要显示空详情页 |
| 7 | `priority` 恒等于 `id` | 3053/3053 | 生成器断言；别把"按 id 排序"写死成"按 priority"以外的假设 |
| 8 | 10 条 native 规则名不以 `.so` 结尾 → 永远不命中 | §4.6 | 保留死规则；不要放宽 `.so` 过滤 |
| 9 | 上游正则里未转义的 `.`（如 `org.hapjs.(.*)`）会多匹配 | 上游原样 | 照抄（与 LibChecker 结果一致），不要"顺手修正" |
| 10 | 非 BMP / U+0085 / 尾部换行 的差异 | §5.2 | 统一 `unicode: true` + 行终止符闸门；fixtures 已覆盖 |
| 11 | `ic_lib_mediatek.svg` 无 width/height | §8.1 | UI 固定 24×24 |
| 12 | 全量原生库列表当前不在 `ParsedApkData` 里 | `parse_task.dart` 只存预算内 `nativeLibraries` | 解析阶段新增全量 `(abi, name, size)`；`libapp.so`/`libmain.so` 校验依赖它 |
| 13 | DEX 包名口径必须是 `class_defs` | `dex.rs:44-66` | 别用 `string_ids` 的类名前缀代替；多 dex 累加 |
| 14 | bundle 体积随数据版本增长 | dv50 → 498 KB | `dataVersion` 变化时重跑生成器并记录新 sha；体积涨 >20% 时再评估压缩（例如只保留 zh-Hans + en 的描述裁剪） |

---

## 附录 A：本文所有实测数字的来源文件

- `/tmp/ApkInfoPlus/crates/core/src/libchecker/rules.rs` — `find` / `normalizeDigitClass` / 索引
- `/tmp/ApkInfoPlus/crates/core/src/libchecker/report.rs` — `analyze` / 分组 / `sdk_count` / 校验
- `/tmp/ApkInfoPlus/crates/core/src/libchecker/update.rs` — manifest 校验与 sha256
- `/tmp/ApkInfoPlus/crates/core/src/manifest.rs:126-172` — `collect_components` / `normalize_component_name` / actions 去重保序
- `/tmp/ApkInfoPlus/crates/core/src/dex.rs:44-66` — `class_defs` → packages + markers
- `/tmp/ApkInfoPlus/crates/core/src/info.rs:243-276` — `NativeLib` 口径
- `/tmp/ApkInfoPlus/scripts/sync-libchecker-rules.py` — 重打包参考
- `/tmp/libchecker/{manifest.json,portable-v5.zip,LICENSE,bundle_compact.json,bundle_test.zip}` — 上游数据与实测产物
- `/tmp/libchecker/darttest/final_check.dart` — 123/123 + 19/19 的验证脚本
- `/tmp/libchecker/extracted/` — 解压后的 `core.json` / `details/` / `icons/` / `matching-fixtures.json`
