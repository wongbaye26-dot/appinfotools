# CgBI 夹具的来历

这里的文件**不是手写的字节**，而是 Apple 自己的工具产出的 —— 手工拼的样本会带着
和实现相同的错误假设，等于自证。

## 文件

| 文件 | 是什么 |
|---|---|
| `rgba-alpha-16x16.cgbi.png` | `pngcrush -iphone` 产出的 CgBI 变体（16×16、8 位 RGBA、含四档 alpha） |
| `rgba-alpha-16x16.rgba` | `pngcrush -revert-iphone-optimizations` 还原出来的**直通 RGBA**，1024 字节，作为期望值 |

测试 `test/cgbi_png_test.dart` 断言：把 CgBI 那个文件喂给
`normalizeCgbiPng`，解出来的像素与 `.rgba` **逐字节相同**。

## 生成命令

```sh
PNGCRUSH=/Applications/Xcode.app/Contents/Developer/usr/bin/pngcrush

# 1. 先造一张普通 RGBA PNG（16×16 渐变，alpha 取 0 / 85 / 170 / 255）
#    见生成脚本；这里只记 pngcrush 的两步
$PNGCRUSH -iphone -q plain.png rgba-alpha-16x16.cgbi.png
$PNGCRUSH -revert-iphone-optimizations -q rgba-alpha-16x16.cgbi.png revert.png

# 2. 把 revert.png 的 IDAT 解压、还原行过滤器，写成 rgba-alpha-16x16.rgba
```

## CgBI 到底是什么（以及结论是怎么来的）

`pngcrush -iphone` 对**彩色** PNG 做三件事：

1. 在签名之后插入一个 `CgBI` 块（实测还可能跟着 `iDOT`，那是 Apple 的并行解码
   优化，与解码无关）；
2. `IDAT` 改成**裸 deflate** —— 没有 zlib 头，也没有 adler32 尾；
3. 像素改成 `B, G, R, A`，且 `B/G/R` 已按 `A` **预乘**。

对**灰度**（色彩类型 0）与**灰度+alpha**（4），`pngcrush -iphone` 不做这个变换，
仍输出标准 PNG；对 RGB（2）会先转成 RGBA。**所以 CgBI 实际上只以 8 位 RGBA、
非隔行出现** —— `normalizeCgbiPng` 也只接受这一种，其余一律如实说明原因。

### 反预乘用截断，不是四舍五入

拿上面这个 16 个含半透明像素的夹具比对 Apple 的还原结果：

| 反预乘写法 | 与 Apple 一致 |
|---|---|
| 只换通道、不反预乘 | 8 / 16 |
| 换通道 + 四舍五入 | 12 / 16 |
| 换通道 + **整数截断** | **16 / 16** |

即 `R = R_premul * 255 ~/ A`。`A == 255`（应用图标基本不透明）时两种写法都是恒等
变换，所以在真实样本上看不出差别 —— 但没有必要和基准实现不一致。

### 信息确实会丢

预乘是**有损**的：`A = 0` 的像素在 CgBI 里就是 `(0, 0, 0, 0)`，原来的颜色再也回不
来；半透明像素反预乘后与原始值最多差几个色阶。这是格式本身的性质，不是实现的
近似 —— 因此这里不把它说成「精确还原」。

## 真实样本的交叉验证

`sun_signed.ipa` 里 `Payload/UjTBpiBdS.app/` 下的两个 `AppIcon*.png`
（`AppIcon60x60@2x.png` 120×120、`AppIcon76x76@2x~ipad.png` 152×152）都是 CgBI。
用 `sips` 把它们转成标准 PNG 作为基准，与本实现解出的像素**全图逐点比对**：
14400 个像素 0 处不符（两个图标全不透明，反预乘是恒等变换，因此是逐字节精确的）。
