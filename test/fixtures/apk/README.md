# 加固 APK 的样本片段

## hardened-manifest.axml

从一个**真实的加固 APK**（60.6 MiB，用户提供）里提取出的 `AndroidManifest.xml`，
共 36240 字节。只取这一个文件而不是整个 APK：样本本身体积太大且属于用户数据，
而这一段恰好包含了我们要测的那件事。

### 这个样本特殊在哪

它是一份**故意做成非标准**的 AXML，用来让「按标准布局硬编码偏移」的解析器
读不到东西：

1. **`attributeStart` 被放大**。标准值是 20（属性紧跟在 12 字节的
   `attrExt` 头之后），而这份文件里 `<manifest>` 是 **181**、`<uses-sdk>` 是 87、
   `<uses-permission>` 是 67/96/44…… 也就是说，头与真正的属性之间塞了
   一段**诱饵字节**。按「紧跟 header」读会读到诱饵，属性全部丢失。
2. **`attributeSize` 也被放大**（22–26，标准 20）。
3. 元素区之前多出两个非标准块（`0x0200` 1360 字节、`0x0101` 1220 字节）。
4. APK 里还有 78 个名字形如 `AndroidManifest.xml/..xml`、`META-INF/ .xml`
   的诱饵条目 —— 它们不是同名重复项，但名字里带 `..` 段。

### 期望值（独立核对）

用一份独立写的 Python 解码器（直接按 `ResourceTypes.h` 的布局读，不依赖本项目
的解析器）核对过：

| 字段 | 值 |
|---|---|
| `package` | `com.QOCrchtmmAzhekiE.HVkokqyMaKAafvaY` |
| `android:versionCode` | `1` |
| `android:versionName` | `8.5.5` |
| `android:compileSdkVersion` | `36` |
| `uses-sdk android:minSdkVersion` | `24` |
| `uses-sdk android:targetSdkVersion` | `34` |
| `application android:label` | `杏⟠⎗吧` |
| `application android:icon` | `@0x7f0f0007` |
| `application android:name` | `com.QOCrchtmmAzhekiE.HVkokqyMaKAafvaY.qupsCHDDcKMNzULd` |
| `uses-permission` 条数 | 40（其中 `READ_EXTERNAL_STORAGE` 带 `maxSdkVersion=32`）|
| 组件数 | 22 |

预期结果**不是**从本项目的解析器拿的 —— 那样等于自证。
