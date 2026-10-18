# Assets.car 格式调研（未完成实现）

> 状态：**索引已实现**（`packages/ipa_parser/lib/src/assets_car.dart`），
> 能列出每张 rendition 的名字/宽高/像素格式/压缩方式/字节数。
> **像素不解码**：数据是 LZFSE 压缩的（见 §三）。
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

## 五、「空壳」rendition

`assetutil --info` 里 `SizeOnDisk: 334` 出现过成千上万次（Music.app 有 5,694
个）。实测这些块：宽高齐全、`compression == none`，但块体**全是 0**，只有
334 字节。它们是引用/占位，**没有像素**。

判据（`AssetsCarImage.embedsPixels`）：压缩过 → 有；未压缩 → 块至少要装得下
`width × height` 字节。实测 `LowBatteryFlashing.png`（30×72、739 字节）就是
空壳：739 < 2160。

## 六、结论

| 能力 | 状态 |
|---|---|
| 列出 Assets.car 里的图（名字/宽高/像素格式/压缩方式/字节数） | **已实现**，与 `assetutil --info` 逐条对齐 |
| 识别「空壳」与矢量（`GVS `/`PDF `） | **已实现** |
| 拿到资产名（`AppIcon` / `AppIcon_Assets/...`） | 未做：要解析 `RENDITIONS` 的 CPI key |
| 提取**未压缩**像素的图 | 需 PNG 编码器（~200 行） |
| 提取**压缩**的图 | 需 LZFSE 解码器（~500–700 行），验证办法是用 `libcompression` 生成夹具 |

前两行已交付且完全可验证。剩下的都要新写编解码器。

