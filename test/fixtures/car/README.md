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

`assetutil` 的 `Name`（资产名）来自 `RENDITIONS` 索引，本项目**不解析**它 ——
所以给不出「这四张图属于哪个资产」。理由见 `docs/notes/assets-car.md`。

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
