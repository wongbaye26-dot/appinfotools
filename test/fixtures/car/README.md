# Assets.car 夹具

## installer-progress.car

macOS 系统自带的真实资产目录：

```
/System/Library/CoreServices/Installer Progress.app/Contents/Resources/Assets.car
```

18,008 字节、23 个块、4 张图。选它而不是 `Chess.app`（664 KB）或
`Music.app`（几十 MB）：**足够小，又覆盖了三种关键形态**（灰度图、ARGB 图、
「有宽高但没有像素」的空壳）。

### 为什么用系统产物而不是手拼

BOM 的块表与 `ISTC` 的字段偏移都是**按偏移访问的二进制结构**，拼错不会报错，
只会读出一个看起来合理的错值（本轮实测踩了三次，见下）。手拼样本会带着与
解析器相同的错误假设 —— 那正是本项目反复强调的自证循环。

### 期望值（`assetutil --info` 的原始输出）

`assetutil` 是 macOS 自带工具，是本格式唯一可用的独立实现：

```sh
$ assetutil --info installer-progress.car
```

```json
[
  { "StorageVersion": 17, "CoreUIVersion": 1011, "SchemaVersion": 2 },
  { "AssetType": "Image", "Name": "LowBatteryEmpty",
    "PixelWidth": 173, "PixelHeight": 72, "Encoding": "Gray",
    "SizeOnDisk": 857, "RenditionName": "LowBatteryEmpty.png" },
  { "AssetType": "Image", "Name": "LowBatteryEmpty",
    "PixelWidth": 346, "PixelHeight": 144, "Encoding": "Gray",
    "SizeOnDisk": 1332, "RenditionName": "LowBatteryEmpty@2x.png" },
  { "AssetType": "Image", "Name": "LowBatteryFlashing",
    "PixelWidth": 30, "PixelHeight": 72, "Encoding": "ARGB",
    "SizeOnDisk": 739, "RenditionName": "LowBatteryFlashing.png" },
  { "AssetType": "Image", "Name": "LowBatteryFlashing",
    "PixelWidth": 60, "PixelHeight": 144, "Encoding": "ARGB",
    "SizeOnDisk": 1155, "RenditionName": "LowBatteryFlashing@2x.png" }
]
```

本项目的解析结果与之逐条一致（`packages/ipa_parser/test/assets_car_test.dart`）。

### 两个字段的对应关系

| assetutil | 本项目 | 说明 |
|---|---|---|
| `Encoding: "ARGB"` | `pixelFormat == 'ARGB'` | 文件里存的 4CC 是 `BGRA`，按小端读出来要**反转** |
| `Encoding: "Gray"` | `pixelFormat == 'GA8 '` | 同上，`GA8 ` 反序读出来是 ` 8AG` |
| `SizeOnDisk` | `sizeOnDisk` | 块长度，逐字节相等 |
| `RenditionName` | `renditionName` | `ISTC` 头 `0x28` 起的 NUL 结尾字符串 |
| `Name` | `assetName` | 来自 `RENDITIONS` 键索引，见 `appicon-ios.car` |
| `NameIdentifier` | `assetIdentifier` | 键里 17 号字段的值 |

## appicon-ios.car

**用 Apple 自己的工具产出的**极小 iOS 资产目录（28,072 字节），不是系统样本、
更不是手拼：

```sh
# 1) 造一个有 AppIcon + 两个普通图像集的 xcassets
#    AppIcon: icon60.png(60x60, 3x) + icon1024.png(1024x1024, ios-marketing)
#    BrandMark.imageset: brand40.png(1x) + brand80.png(2x)
#    ToolbarGlyph.imageset: glyph24.png(1x)
# 2) 编译
actool --compile out --platform iphoneos --minimum-deployment-target 13.0 \
       --app-icon AppIcon --output-partial-info-plist partial.plist \
       --output-format human-readable-text Assets.xcassets
```

`Platform: ios / 13.0`，与系统里那几份 macOS 目录的 `Key Format` 不同
（9 项 vs 8 项）—— 正好用来证明属性编号不是写死的，而是从 `KEYFORMAT` 读的。

### 期望值（`assetutil --info` 的原始输出，只列与本实现相关的字段）

```json
[
  { "StorageVersion": 17, "CoreUIVersion": 1010, "Platform": "ios",
    "Key Format": ["kCRThemeAppearanceName", "kCRThemeLocalizationName",
                   "kCRThemeScaleName", "kCRThemeIdiomName", "kCRThemeSubtypeName",
                   "kCRThemeDimension2Name", "kCRThemeIdentifierName",
                   "kCRThemeElementName", "kCRThemePartName"] },

  { "AssetType": "Icon Image",       "Name": "AppIcon",   "NameIdentifier": 6849,
    "RenditionName": "icon1024.png", "PixelWidth": 1024, "PixelHeight": 1024,
    "Scale": 1, "SizeOnDisk": 6548, "Encoding": "ARGB", "Compression": "lzfse" },
  { "AssetType": "Icon Image",       "Name": "AppIcon",   "NameIdentifier": 6849,
    "RenditionName": "icon60.png",   "PixelWidth": 60,   "PixelHeight": 60,
    "Scale": 3, "SizeOnDisk": 668,  "Encoding": "ARGB", "Compression": "lzfse" },

  { "AssetType": "Image", "Name": "BrandMark", "NameIdentifier": 9463,
    "RenditionName": "brand40.png", "PixelWidth": 40, "PixelHeight": 40,
    "Scale": 1, "SizeOnDisk": 330 },
  { "AssetType": "Image", "Name": "BrandMark", "NameIdentifier": 9463,
    "RenditionName": "brand80.png", "PixelWidth": 80, "PixelHeight": 80,
    "Scale": 2, "SizeOnDisk": 583 },
  { "AssetType": "Image", "Name": "ToolbarGlyph", "NameIdentifier": 7517,
    "RenditionName": "glyph24.png", "PixelWidth": 24, "PixelHeight": 24,
    "Scale": 1, "SizeOnDisk": 330 },

  { "AssetType": "MultiSized Image", "Name": "AppIcon", "NameIdentifier": 6849,
    "RenditionName": null, "PixelWidth": null, "SizeOnDisk": 236 },
  { "AssetType": "MultiSized Image", "Name": "AppIcon", "NameIdentifier": 6849,
    "RenditionName": null, "PixelWidth": null, "SizeOnDisk": 236 },

  { "AssetType": "PackedImage", "Name": "ZZZZPackedAsset-1.1.0-gamut0",
    "NameIdentifier": null, "PixelWidth": 70, "PixelHeight": 44,
    "SizeOnDisk": 614 }
]
```

### 这份夹具一次覆盖五件事

1. **资产名**：3 个名字（`AppIcon` / `BrandMark` / `ToolbarGlyph`），
   `NameIdentifier` 与键里 17 号字段逐条相等。
2. **同一个资产多张 rendition**：`AppIcon` 有 4 条 —— 两张真图 + 两张
   `MultiSized Image` 空壳（236 字节，没有 rendition 名）。
3. **图集成员**：`actool` 把两个小图集打包成 `ZZZZPackedAsset-1.1.0-gamut0`，
   它的键里标识符是 **0**，所以没有资产名。本实现单列为「图集成员」，
   不硬凑一个名字。
4. **`BrandMark` / `ToolbarGlyph` 的 1x rendition 只有 330 字节**（2x 是 583）——
   像素被并进图集，单条 rendition 里没有。所以 `BrandMark` 只有 80×80 那张
   值得尝试解码，而它解出来的字节数与 `80×80×4` 对不上（见下）。
5. **多流 LZFSE**：`icon1024.png` 的块长只有 6,548 字节，里面有 **4 个
   `bvx2 … bvx$` 流**（3 × 1,396,736 + 4,096 = **4,194,304** = 1024×1024×4）。
   只解第一个流会得到「差 2/3」，那正是上一轮所有 `pixel_size_mismatch` 的来源。

### 解不出来的两种，都要如实报

| rendition | 现象 | 本实现的处理 |
|---|---|---|
| `brand80.png` | 解出 44,880 字节，而 80×80×4 = 25,600 | `pixel_size_mismatch`，写出三个数 |
| `brand40` / `glyph24` | 块里没有自己的像素（并进图集了） | 判为没有像素，不尝试 |

**不截断、不拉伸、不猜 bpp** —— 一张错的图标比「取不到」糟糕得多。

## palette-single.car / palette-banded.car

两份都是 **`actool` 真实编译**的索引色样本。像素值是生成脚本写的，
所以期望值不来自本实现：

| 夹具 | 尺寸 | 内容 | 块数 | 调色板 |
|---|---|---:|---:|---|
| `palette-single.car`（18 KB） | 300×300 | 横向三段纯色：红 / 绿 / 蓝 | 1 | 3 条 |
| `palette-banded.car`（19 KB） | 1500×1000 | 同样的三段色 | **2** | 3 条 + **1 条** |

### 为什么第二个夹具是必需的

`actool` 会按约 1–1.5 M 像素把大图切成条带（实测 1125×2436 的启动图切成
932+932+572 行）。**每条带带一份自己的调色板**：

```
palette-banded.car:
  CarPaletteChunk(rows 0..698,   3 entries)   ← 跨了红/绿两条颜色带
  CarPaletteChunk(rows 699..999, 1 entries)   ← 这一段全蓝，只需要 1 条
```

如果按「一份调色板套全图」实现，下半段的单色索引会映射到第一份调色板的
第 0 条 —— 颜色直接错，而画面仍然「像一张图」。用例
`多块：跨块边界颜色连续` 就是钉这个：边界两侧的行平均色差必须 ≤ 1。

### 生成命令

```sh
# 300×300：三段纯色
# 1500×1000：同样的三段纯色（触发分块）
actool --compile out --platform iphoneos --minimum-deployment-target 13.0 \
       --output-partial-info-plist p.plist \
       --output-format human-readable-text A.xcassets
```

### 索引色的块内布局（实测）

```
"dmp2" | 04 01 0a 04 | u16 宽 | u16 本块行数 | u16 条目数 | u16 每条字节数
       | 条目数 × 每条字节数 的调色板（**BGRA**）
       | u32 紧随其后的流字节数
       | bvx2 …
```

- 参数 `04 01 0a 04` 是「索引色」模式；`02 01 0a 04` 是另一种多层格式（不解）。
- 第二个 u16 是**本块行数**，不是整图高度 —— 条带把它切开了。
- 调色板条目按 **BGRA** 存（与 `ARGB` 像素的内存布局同一条规则）。
  实测依据：三色图里索引 0 落在图像右侧的蓝色区，而调色板[0] 是
  `ff 00 00 ff` —— 只有按 BGRA 读才是蓝。
- **ISTC 的 `pixelFormat` 仍然写 `ARGB`**：那个字段描述的是解码后的目标
  格式，不是落盘形态。照它算期望字节数会得到「少了 3/4」的假象。

## 三个实测踩过的坑

1. **端序混用**：`BOMStore` 头与块表是**大端**，`RATC` 与 `ISTC` 头是**小端**。
   按大端读 `RATC` 的版本字段会得到 285212672 / 4077060096 这种明显不可能的数。
2. **块表条目数不是 `indexOffset` 处的那个 u32**（读出 256，而真实块数是头里的
   `blockCount`，本夹具 23）。按 `count + count×8` 读必然错位。
3. **4CC 是反序存的**：文件里 `BGRA` 表示 `ARGB`、`GA8 ` 读出来是 ` 8AG`。
   不反转的话，`Encoding` 一栏全是「乱码」，而且看起来像有效数据。

## 空壳：`LowBatteryFlashing.png`

它的 `SizeOnDisk` 只有 739 字节，而 30×72 的像素至少要 2160 字节 —— 块内
拉不出像素（实测块体全是 0）。这类条目在系统样本里成千上万
（`Music.app` 有 5,694 个），本项目把它们单列为 `placeholderOnly`，
不计入 `rasterImages`。
