# Assets.car 格式调研

> 状态：**索引、资产名、像素提取都已实现**。
> - 索引：`assets_car.dart`（名字/宽高/像素格式/压缩方式/字节数/资产名）
> - 解码：`lzfse.dart`（纯 Dart LZFSE，与 Apple 的 `libcompression`
>   **逐字节一致**；含一个块里多个串接流）
> - 出图：`assets_car_extract.dart` + `png_encoder.dart`
>
> 但**不是每个 rendition 都能出图** —— 见 §六的第 3 条（实测 44%）。
>
> 本文记录已验证的格式事实与卡点，避免下次重复探索。

## 为什么值得记

`Assets.car` 是 Apple 私有的资产目录格式，**没有任何公开文档**，而且：

- 没有工具能导出里面的图（`assetutil` 只有 `--info`，`--output` 是「清理废弃资产」）；
- 系统里 5 个 `Assets.car` 的图**全部是 ARGB / BGRA 原始像素 + LZFSE 压缩**，
  没有一个是 PNG/JPEG 编码的 —— 所以「直接抠出 PNG」这条路径在本机无法验证。

## 一、BOMStore 容器

```
0x00  magic[8]        "BOMStore"
0x08  u32 version     1
0x0C  u32 blockCount  例如 87
0x10  u32 indexOffset 块表在文件中的位置（通常贴近文件末尾）
0x14  u32 indexLength
0x18  u32 varsOffset  变量名表
0x1C  u32 varsLength
```

### 块表（**这是最容易读错的地方**）

`indexOffset` 处：

```
indexOffset + 0x00   u32  （读出来是 256，**不要**当成条目数）
indexOffset + 0x04   blockCount × { u32 address、u32 length }   ← 大端
```

`address` 是**文件内绝对偏移**，`length` 是块长度。

按 `u32 count + count×8` 读会走进死路：那个 256 与 `blockCount=87` 矛盾，
`indexLength=2072` 也对不上任何整数解。**用头里的 `blockCount` 才是对的** ——
实测从 `indexOffset + 4` 起每 8 字节读 87 条，全部落在数据区、长度合理、
互不越界。

验证方式：`block[1]` 必须是 CARHEADER（见下），实测 `(512, 436)` 且
`0x200` 处正是 `RATC`。

四种候选布局（`delta ∈ {0,4,8}` × `stride ∈ {8,12}`）只有
`delta=4, stride=8` 能给出「条目数 == blockCount」。这条自洽性约束就是
当初反解出布局的办法。

### 变量名表

```
varsOffset + 0x00   u32 count
varsOffset + 0x04   count × { u32 blockIndex、u8 nameLen、name[nameLen] }
```

实测（Chess.app）：7 项 —— `CARHEADER`(1)、`RENDITIONS`(2)、`FACETKEYS`(4)、
`APPEARANCEKEYS`(6)、`KEYFORMAT`(36)、`EXTENDED_METADATA`(75)、`BITMAPKEYS`(76)。

> 注意这里的 `blockIndex` 与块表中「第几条」**不是同一个编号空间**，
> `CARHEADER → 1` 恰好对上，`RENDITIONS → 2` 对不上（2 号块是 29 字节的字符串块）。
> 这一处**还没有搞清楚**，是下一步要解决的第一件事。

## 二、CARHEADER（`RATC`）

```
0x00  magic[4]  "RATC"
0x04  u32       CoreUIVersion   （实测 1011）  ← 小端
0x08  u32       StorageVersion  （实测 17）    ← 小端
```

实测 Chess.app：`RATC` + `1011` + `17` + ... 后跟 `"@(#)PROGRAM:CoreUI ..."`。

`1011` 与 `17` 分别对应 `assetutil --info` 的 `CoreUIVersion` 与
`StorageVersion` —— **这是「块表解析正确」的外部证据**。

## 三、图像块（`ISTC`）

```
0x00  magic[4]   "ISTC"
0x04  u32        version（实测 1）
0x08  u32        ...
0x0C  u32        width       （实测 0x400 = 1024）
0x10  u32        height      （实测 0x400 = 1024）
0x14  u32        ...
0x18  char[4]    像素格式    "BGRA" / "GVS " / "GA16" / ...
...
       u32 + str  rendition 名  （实测 "image.png"）
...
       "bvx2"    ← LZFSE 压缩流从这里开始
```

`len` 与 `assetutil --info` 的 `SizeOnDisk` **逐字节相等**（实测 311137），
`rendition 名` 与 `RenditionName` 相等（`image.png`）。这两条是最硬的交叉验证。

### 卡点：LZFSE

`bvx2` 是 LZFSE 的块魔数（另有 `bvxn` / `bvx-` / `bvx1`）。
1024×1024 的 BGRA 未压缩是 4,194,304 字节，`SizeOnDisk` 只有 311,137
（压缩比 13.5:1）—— **数据一定被压缩了，不可能是「直接抠出像素」。**

Dart 侧没有 LZFSE 实现。要提取图像必须自己移植解码器
（FSE 表 + Huffman + v1/v2/uncompressed 块，约 500–700 行）。

**验证办法是存在的**：macOS 有 `libcompression`，可以写个小 C 程序用
`COMPRESSION_LZFSE` 压缩一段已知数据生成夹具，期望值就是原始字节 ——
不必自证。这条路还没走。

## 四、系统样本的编码分布（决定「该报什么」）

| 应用 | ARGB | ARGB-16 | Gray |
|---|---|---|---|
| Chess | 5 | 1 | — |
| Siri | 9 | 1 | 4 |
| FindMy | 65 | — | 56 |
| QuickTime Player | 13 | 1 | 1 |
| Music | 1820 | 1 | 4768 |

**一个 PNG/JPEG 都没有。** macOS 应用的资产全是原始像素格式。

iOS 应用的 `AppIcon` 传统上是 PNG，但本机**没有 iOS 的 `Assets.car` 样本**，
这条路径无法验证 —— 这也是为什么不应该先写「PNG 提取」再去找样本。

## 五、「空壳」rendition —— 以及一次被推翻的判定

`assetutil --info` 里 `SizeOnDisk: 334` 出现过成千上万次（Music.app 有 5,694
个）。这类块的宽高齐全、块内没有任何压缩标记、块体只有 334 字节 —— 是引用/
占位，**没有像素**。

**但原先的判据把它连累了真图。** 当时的规则是「没有压缩标记 + 块装不下
`width × height` → 空壳」，于是 `installer-progress.car` 里 739 字节的
`LowBatteryFlashing.png`（30×72）被判成空壳。实际上它的块里有：

```
64 6d 70 32 | 04 01 0a 04 | 1e 00 | 48 00 | 35 00 | 04 00
 "dmp2"        参数         30      72      53      4
```

`dmp2` = **deepmap2**，后面跟着的 30×72 与 `ISTC` 声明完全一致 —— 它是一张
压过的 30×72 图，只是用的不是 LZFSE。于是新增 `CarCompression.deepmap2`：
**有像素，但我们不解这个码**。把「我们解不了」说成「没有像素」是错的。

修后判据（`AssetsCarImage.embedsPixels`）：块里有编码标记（`bvx*` / `dmp2`）
→ 有像素；一个标记都没有 → 只有块装得下 1 字节/像素才算。后一档是启发式，
文档里明确写成启发式，不当判据用。

实测分布（84 个容器、19,737 个光栅块）：`bvx*` 3,194、`dmp2` 284、
无标记且块装不下（真空壳）12,612、无标记但块装得下 3,920。

## 六、结论

| 能力 | 状态 |
|---|---|
| 列出 Assets.car 里的图（名字/宽高/像素格式/压缩方式/字节数） | **已实现**，与 `assetutil --info` 逐条对齐 |
| 识别「空壳」、deepmap2 与矢量（`GVS `/`PDF `） | **已实现** |
| LZFSE 解码（`bvx2` / `bvx-` / `bvx$`，含**串接的多流**） | **已实现**，与 `libcompression` 逐字节一致 |
| 提取像素并编成 PNG | **已实现**，但受下面的限制 |
| 拿到资产名（`AppIcon` / `AppIcon_Assets/...`） | **已实现**，见 §七 |

### 四件必须说明的事

**1. 通道顺序不是猜的，是 CoreGraphics 说的。**

`ARGB`（4CC 反转后）对应内存字节 `B,G,R,A`。这不是从文档抄的，而是让
CoreGraphics 自己解释：用 `kCGImageAlphaPremultipliedFirst |
kCGBitmapByteOrder32Little` 从 4 个已知字节 `[10,20,30,255]` 构造 `CGImage`，
再画进标准 RGBA 上下文，读回 `[30,20,10,255]` —— 所以 **byte0 = B**。

`GA8 ` 同理：`[77,200]` 读回 `[77,77,77,200]`，即 byte0 = 灰度、byte1 = alpha。

**2. 一个块里可能有多个 LZFSE 流 —— 这是上一轮所有失败的真正原因。**

上一版本这里写的是「payload 里还有一层没搞清的封装（内容 90% 是零、有约
1026 字节的周期结构）」。**那个结论是错的。** 真实结构是：

```
[KCBC 头 20B][bvx2 … bvx$][KCBC 头][bvx2 … bvx$]…[bvx2 … bvx$]
```

一个 `ISTC` 块里的像素被切成若干段、每段一个独立的 LZFSE 流。`actool` 编出的
1024×1024 图标是 **4 个流**：3 × 1,396,736 + 4,096 = 4,194,304 = 1024²×4。
只解第一个流自然「少了 2/3」。

`KCBC` 头（"KCBC" + 8 字节 0 + u32 行数 + u32 紧随其后的流字节数）不是必需的：
Chess.app 的块里流与流之间只有 4 字节记录。所以实现方式是「解完一段，在有界
窗口内找下一个流头」，最终用**总字节数必须精确等于 W×H×bpp** 把关。

修后实测（84 个容器、3,244 张能尝试的图）：**1,428 张出图（44.0%）**，其中
**191 张是多流的** —— 这 191 张在修复前必定失败。真实样本：
`bi-ying-0828.ipa` 的 1024 图标（507 KB 压缩）解出 4 MiB、编成 458 KB PNG，95 ms。

**3. 仍有解不开的，原因各不相同（都不猜）。**

| 失败码 | 实测数量 | 含义 |
|---|---:|---|
| `pixel_size_mismatch` | 1,335 | 解出的字节数与 `W×H×bpp` 对不上。已确认两种成因：payload 是 1 字节/像素（LaunchImage 类），或解出的比预期**多**（Chess 的某个 1024 图层 7,341,104、BrandMark 80×80 44,880） |
| `unsupported_deepmap2` | 284 | 纯 `dmp2` 载荷，不解这个码 |
| `lzfse_block.unsupported_lzvn` | 109 | 某个**后续** chunk 是 LZVN（`bvxn`）。注意：作为**第一个**流时实测 0 次，所以上一版本「光栅图里 0 次」的说法只在「首流」意义上成立 |
| `unsupported_format` | 88 | `RGBW` / `ATAD` 等像素格式 |

**4. 两个不支持的块类型是**报出来的**，不是猜出来的。**

`bvx1`（v1 头）没有工具产出、没有样本；`bvxn`（LZVN）作为流首在实测的 951 张
真实光栅图里出现 **0** 次。两者都抛带稳定 code 的异常，而不是写一个没验证过的
实现 —— 「能跑但结果是错的」比「明确说不支持」糟糕得多。

## 七、资产名（`RENDITIONS` 的键索引）

上一层只回答「有哪些图」，不回答「这张图属于哪个资产」。资产名在
`RENDITIONS` 里，而它是 `CSI key` 数组 —— 没有文档。反解结果：

```
KEYFORMAT 块（"tmfk"，其余字段小端）
  0x00 "tmfk"
  0x04 u32 0
  0x08 u32 属性个数 N
  0x0C N × u32 属性编号（有序）

键签名 = 2 × N 字节：N 个 u16 小端字段，顺序与 KEYFORMAT 一致。
  每个 ISTC 块在**块表里**的前一块就是它自己的键，长度恰为 2N。
  字段 17（kCRThemeIdentifierName）= 资产名哈希。

名字表：一块字符串 + 紧随其后的「稀疏键」
  稀疏键 = u32 0 + u16 个数 M + M × (u16 属性编号, u16 值)
  总长恰为 6 + 4M，编号严格递增且都在 KEYFORMAT 里。
```

三条反解线索：

1. 稀疏键的 `03 00` 按大端读是 768（不可能），按**小端**读是 3（= 字段数）。
2. `2N` 不是猜的：83 个容器里**每一个** ISTC 的前一块长度都恰好是 `2N`。
3. 「前一块就是它的键」是**块表顺序**，不是文件偏移顺序。

验证到什么程度：

- 属性编号 17 = `kCRThemeIdentifierName`：`assetutil --info` 的 `Key Format`
  名字数组与本实现解析出的编号数组**逐位对应**（8 / 11 / 12 / 14 / 17 项都见过），
  每张 rendition 的 `NameIdentifier` 与键里 17 号字段**逐条相等**。
- **83 个容器、25,986 个 ISTC**：除 `PackedImage`（图集成员，本来就没有资产名）
  外**零差异**（按 `(SizeOnDisk, 资产名)` 多重集逐条比对）。
- 7,500 个名字，16 位哈希**零碰撞** —— 但仍按可能碰撞处理（撞了就报「不确定」，
  不随手挑一个）。

图集成员（`identifier == 0`）没有资产名 —— `assetutil` 给它的是合成名
`ZZZZPackedAsset-…`。本实现单列为 `isAtlasMember`，不硬凑名字。

### 顺带确认的两件事

- **真实 iOS 应用的图像全是 `bvx2`**（`bi-ying` 的 1024 图标、`Ptv` 的 1024
  图标都是）。`deepmap2` 主要在 macOS 侧。
- `dmp2` 标记与 `bvx` **通常同时存在**（2,595 个光栅块两者都有，只有 284 个
  是纯 `dmp2`），所以判定的第一优先永远是 `bvx`。

