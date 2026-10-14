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

## standard-manifest.axml

一份**手工构造的最小标准 AXML**（约 150 字节），只有一个 `<manifest>` 元素与
一个属性，`attributeStart` / `attributeSize` 都取标准值 20。

存在的唯一目的是**反向验证**：确保「非标准布局」的检测不会把正常文件误报成
加固样本。这份文件是手工拼的 —— 没有工具会产出「这么小的标准 AXML」，
而它要断言的正是「什么都不报」。

## night-mode-resources.apk / no-night-mode-resources.apk

一对**由 `aapt2` 真实产出**的最小 APK，用来钉住 `resources.arsc` 里的
`uiMode`（夜间模式）解析。区别只有一个：前者多一个 `res/values-night/`。

用真实产物而不是手拼字节，是因为 `ResTable_config` 的字段偏移必须与
AOSP 的实际布局一致 —— 手拼的样本会带着与解析器相同的错误假设，等于自证。
生成命令（macOS，Android SDK build-tools 36.1.0）：

```sh
AAPT2=~/Library/Android/sdk/build-tools/36.1.0/aapt2
JAR=~/Library/Android/sdk/platforms/android-34/android.jar

# 每个样本一个目录，内含：
#   AndroidManifest.xml（package=com.example.fixture, minSdk=21, targetSdk=34）
#   res/values/strings.xml        —— app_name + color/bg
#   res/values-night/strings.xml  —— 仅 night 样本有，覆盖 color/bg
#   res/drawable/icon.png         —— 1x1 PNG

(cd "$dir" && "$AAPT2" compile --dir res -o compiled.zip \
  && "$AAPT2" link -o out.apk -I "$JAR" --manifest AndroidManifest.xml compiled.zip)
```

### 期望值（用 aapt2 独立核对，不是从本项目的解析器拿的）

```sh
$AAPT2 dump configurations night-mode-resources.apk
night
$AAPT2 dump configurations no-night-mode-resources.apk
（空）
```

| 夹具 | `hasNightModeResources` | 依据 |
|---|---|---|
| `night-mode-resources.apk` | `true` | `aapt2 dump configurations` 输出 `night` |
| `no-night-mode-resources.apk` | `false` | 同上，输出为空 |

两个都要留：只留带夜间资源的那个，`hasNightModeResources` 直接
`return true` 也能通过。

## cyclic-color-alias.apk / cyclic-color-icon.apk

一对**含真实资源引用环**的 APK，同样由 `aapt2 link` 产出。

它们纠正了一个我原先写错的判断：我以为「`aapt2` 不可能产出引用环」，于是把
「表里有环」当成了篡改的证据。实测 `aapt2 link` 对
`<color name="a">@color/b</color>` + `<color name="b">@color/a</color>`
**照单全收**，并原样写进资源表。所以发现环时只能说「这些资源解析不了」，
**不能说**「这个包被人动过手脚」。

| 夹具 | 内容 |
|---|---|
| `cyclic-color-alias.apk` | `color/a → @color/b`、`color/b → @color/a` |
| `cyclic-color-icon.apk` | 同上，外加 `color/icon_fill → @color/a` 和一个用 `@color/icon_fill` 作 `fillColor` 的矢量图标 |

生成命令与上面一致（同一个 `aapt2 compile` + `aapt2 link` 流程），只是
`res/values/values.xml` 与 `res/drawable/ic_launcher.xml` 的内容不同：

```xml
<!-- cyclic-color-alias.apk 的 res/values/values.xml -->
<resources>
  <string name="app_name">Cycle</string>
  <color name="a">@color/b</color>
  <color name="b">@color/a</color>
</resources>
```

```xml
<!-- cyclic-color-icon.apk 额外有的 res/drawable/ic_launcher.xml -->
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="24dp" android:height="24dp"
    android:viewportWidth="24" android:viewportHeight="24">
  <path android:fillColor="@color/icon_fill"
      android:pathData="M0,0 L24,0 L24,24 L0,24 Z" />
</vector>
```

### 期望值（用 aapt2 独立核对）

```sh
$AAPT2 dump resources cyclic-color-alias.apk | grep -E 'resource 0x|@color'
    resource 0x7f010000 color/a
      () @color/b
    resource 0x7f010000 … color/b
      () @color/a
```

用途：
- `cyclic-color-alias.apk` 钉住 `ResourceReferenceGraph.findCycles` 在**真实表**
  上确实能检出环（否则那组纯函数测试可能只是自证）。
- `cyclic-color-icon.apk` 钉住「图标渲染遇到环时必须留下说明」——
  这个夹具的图标填充色指向环，渲染会失败，而失败**必须能解释**。
