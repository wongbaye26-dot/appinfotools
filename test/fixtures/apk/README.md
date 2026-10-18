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

## attr-fixture.apk

一个由 `aapt2` **真实产出**的最小 APK，专门用来钉住「框架属性 ID → 属性名」的解析。

### 为什么需要它

`_kFrameworkAttrNames` 曾经是一份 63 条的表，其中 **51 条 ID 对应错了名字**
（`0x01010010` 写成 `resource`，实为 `exported`；`0x01010280` 写成
`screenSize`，实为 `allowBackup`）。后果是 `android:exported` /
`debuggable` / `allowBackup` / `usesCleartextTraffic` 在**所有真实包**上
都读不到，四条安全规则长期静默失效。

它没被发现的原因很具体：当时的用例都手工构造 `ApkMeta`，测的是「拿到一个
`bool` 之后规则怎么判」，而不是「这个 `bool` 能不能从字节里拿到」。
所以这个夹具必须**从真实字节走完整条链路**。

第二件事：AXML 的布尔值 `tvData` 是**有符号** 32 位读出来的，而 `true` 的
规范编码是 `0xffffffff`（即 `-1`）。旧代码写 `data == 0xffffffff`，于是
**每一个 `true` 都变成 `false`** —— 比读不到更糟，因为它是一个「看起来
很正常的具体值」。

### 内容

见 `attr-fixture.AndroidManifest.xml`。刻意覆盖了正反两面：

| 位置 | 声明 | 用途 |
|---|---|---|
| `<application>` | `debuggable="true"` | 真的 `true`（旧代码会读成 `false`） |
| `<application>` | `allowBackup="false"` | 真的 `false`（不能把 `false` 和「没读到」混为一谈） |
| `<application>` | `usesCleartextTraffic="true"` | 规则 D 的输入 |
| `<application>` | `networkSecurityConfig="@xml/..."` | 规则 D 在 NSC 存在时必须**不判定** |
| `<activity>` | `exported="true"` + `enabled="false"` | 导出组件规则；同时是启动页（必须被排除） |
| `<provider>` | `exported="true"` + `authorities="..."` | `authorities` 曾与 `debuggable` 的 ID 互换 |
| `<service>` | `exported="false"` | 「读到了 false」与「没读到」要能区分 |
| `<uses-permission>` | `maxSdkVersion="28"` | 版本适用条件 |

### 生成命令

```sh
AAPT2=~/Library/Android/sdk/build-tools/34.0.0/aapt2
JAR=~/Library/Android/sdk/platforms/android-34/android.jar
$AAPT2 compile --dir res -o compiled.zip
$AAPT2 link -o attr-fixture.apk -I "$JAR" \
  --manifest AndroidManifest.xml compiled.zip
```

### 期望值（用 aapt2 独立核对，不是从本项目的解析器拿的）

```sh
$AAPT2 dump xmltree attr-fixture.apk --file AndroidManifest.xml
```

该输出里每条属性都带自己的资源 ID，例如
`A: ...android:exported(0x01010010)=true` —— 这正是判定「解析器有没有
读对属性」的第三方依据。完整的 ID 对照表快照在
`packages/apk_parser/test/fixtures/android_34_attrs.txt`。

## nsc-fixture.apk

一份由 `aapt2` **真实产出**的最小 APK，用来钉住
`android:networkSecurityConfig` 的**展开**（资源 id → 文件路径 → AXML）。

### 为什么需要它

AOSP `ApplicationInfo`：API 24 起，只要声明了 `android:networkSecurityConfig`，
`android:usesCleartextTraffic` **就不再生效**，明文策略完全由那份 XML 决定。
只读清单属性会在真实包上得出两种错误结论：

- 照抄属性 → 证据指向一个平台根本不看的地方；
- 因为「属性无效」就不判定 → 把真发现吞掉（假阴性）。

唯一正确的做法是打开那份 XML。实测 5 个真实包里 4 个 `usesCleartextTraffic=true`，
其中 3 个同时有 NSC，展开后 `base-config cleartextTrafficPermitted="true"`
—— 它们确实允许明文，所以规则 D 报得对。

### 内容（刻意做成「base 禁止、域名放行」）

```xml
<network-security-config>
    <base-config cleartextTrafficPermitted="false">
        <trust-anchors><certificates src="system" /></trust-anchors>
    </base-config>
    <domain-config cleartextTrafficPermitted="true">
        <domain includeSubdomains="true">api.example.com</domain>
        <domain includeSubdomains="false">legacy.example.org</domain>
    </domain-config>
</network-security-config>
```

这个组合能一次测到三件事：

1. `base-config` 的布尔值读到了（`false`）；
2. `domain-config` 覆盖 base（整体仍然「允许明文」）；
3. **域名是元素文本**（`<domain>api.example.com</domain>`），不是属性 ——
   不取 AXML 的 `RES_XML_CDATA_TYPE` 就只能数出「有 2 条规则」，
   说不出是哪两个域名。

源文件见同目录的 `nsc-fixture.AndroidManifest.xml` 与
`nsc-fixture.network_security_config.xml`。

### 生成命令

```sh
AAPT2=~/Library/Android/sdk/build-tools/34.0.0/aapt2
JAR=~/Library/Android/sdk/platforms/android-34/android.jar
$AAPT2 compile --dir res -o compiled.zip
$AAPT2 link -o nsc-fixture.apk -I "$JAR" \
  --manifest AndroidManifest.xml compiled.zip
```

### 期望值（用 aapt2 独立核对）

```sh
$AAPT2 dump xmltree nsc-fixture.apk --file res/xml/network_security_config.xml
```

输出里能看到 `base-config cleartextTrafficPermitted=false`、
`domain-config cleartextTrafficPermitted=true`，以及两条
`T: 'api.example.com'` / `T: 'legacy.example.org'`。

## manifest-extra-fixture.apk

一份由 `aapt2` **真实产出**的最小 APK，用来钉住清单里四项「数据已经在手但
此前没人读」的属性：

| 项 | 不读它时的错误结论 |
|---|---|
| `android:sharedUserId` | 「与同签名应用共享沙箱」完全不可见 |
| `android:protectionLevel` | 导出组件只要写了 `android:permission` 就当「受保护」，而 `normal` 级自定义权限**任何应用都能申请** |
| `android:dataExtractionRules` / `fullBackupContent` | `allowBackup="true"` 就说「整包数据可被备份」，而 `"false"` 其实把备份彻底关了 |

### 内容（三个组件刻意覆盖三种权限形态）

```xml
<manifest android:sharedUserId="com.example.shared">
  <permission android:name="...WEAK"   android:protectionLevel="normal" />
  <permission android:name="...STRONG" android:protectionLevel="signature" />
  <application android:allowBackup="true"
               android:dataExtractionRules="@xml/data_extraction_rules">
    <provider android:name=".WeakProvider" android:exported="true"
              android:permission="...WEAK" />        <!-- 等于没保护 -->
    <service  android:name=".StrongService" android:exported="true"
              android:permission="...STRONG" />      <!-- 真的受保护 -->
    <receiver android:name=".JobReceiver" android:exported="true"
              android:permission="android.permission.BIND_JOB_SERVICE" />
                                                     <!-- 框架权限：保守当成受保护 -->
  </application>
</manifest>
```

### 生成命令

```sh
AAPT2=~/Library/Android/sdk/build-tools/34.0.0/aapt2
JAR=~/Library/Android/sdk/platforms/android-34/android.jar
$AAPT2 compile --dir res -o compiled.zip
$AAPT2 link -o manifest-extra-fixture.apk -I "$JAR" \
  --manifest AndroidManifest.xml compiled.zip
```

源文件见同目录的 `manifest-extra-fixture.AndroidManifest.xml` 与
`manifest-extra-fixture.data_extraction_rules.xml`。

### 期望值（用 aapt2 独立核对）

```sh
$AAPT2 dump xmltree manifest-extra-fixture.apk --file AndroidManifest.xml
  A: ...sharedUserId(0x0101000b)="com.example.shared"
  A: ...protectionLevel(0x01010009)=0x00000000     ← normal
  A: ...protectionLevel(0x01010009)=0x00000002     ← signature
  A: ...dataExtractionRules(0x0101063e)=@0x7f010000
```

> **`protectionLevel` 是整数标志位，不是字符串。** 按字符串找 `"signature"`
> 永远找不到，规则会静默不生效 —— 这是本项目第三次踩到「值读到了但形态
> 不对」（前两次是属性 ID 错位、布尔值被读成有符号 -1）。
