# 报告质量评审

> 对象：`217_0919155004.apk`（Android）与 `Ptv_signed_v3.ipa`（iOS）两份导出报告
> 日期：2026-10-22

## 结论

**有明确优化空间，其中 4 项是 bug，不是风格问题。**

最严重的一条不是格式：**iOS 那份报告里最致命的三个发现，在「结论」里一个字都没提。**

| 等级 | 项 | 影响 |
|---|---|---|
| 🔴 bug | `$entry.key` 插值错误 → 证据里印出 `MapEntry(...).key` | 17 条用途说明的证据全部损坏 |
| 🔴 bug | 短 TLD 把长域名截断 → 域名列表混进碎片 | iOS 50 个域名里约 1/4 是假域名 |
| 🔴 bug | 否定结论被算进「能力主题」 | 读者会以为发现了数据外发 |
| 🔴 设计 | 结论段忽略 iOS 重打包 / 注入 / 标识不匹配 | 最致命的发现被埋在中间 |
| 🟡 质量 | 组件与权限重复渲染两遍 | 报告长度虚增约 40 行 |
| 🟡 质量 | 中英混排（证据 detail、limitation） | 中文界面下突然冒出英文句子 |
| 🟡 质量 | 覆盖率 `covered/limit` 与 `status` 不同源 | 「已覆盖 24490/24490」其实只扫了 20/69 个文件 |
| 🟢 打磨 | 空「解析诊断」表、域名无覆盖率维度、`READ_PRIVILEGED_PHONE_STATE` 未提示无效 | 可信度细节 |

---

## 一、四个 bug

### 1. `$entry.key` 在 Dart 里只插值 `entry`

**证据**（iOS 报告，17 条用途说明全是这样）：

```
infoPlist (Payload/JpoALFZUs.app/Info.plist / MapEntry(NSAppleMusicUsageDescription: 需要您的同意, APP才能访问媒体资料库).key): 需要您的同意, APP才能访问媒体资料库
```

`ios_privacy_audit.dart:309`：

```dart
location: '${infoPlist.bundle.path}/Info.plist / $entry.key',
```

Dart 里 `'$entry.key'` **等价于** `'${entry}.key'` —— 插的是 `entry` 的 `toString()`，
后面拼一个字面量 `.key`。要插属性必须写 `${entry.key}`。

`$entry` 的 `toString()` 是 `MapEntry(NSAppleMusicUsageDescription: 需要您的同意…)`，
于是 location 变成 `MapEntry(...).key`。

**全仓只有这一处**（我扫了 `$name.prop` 形式的裸插值）。修起来一行。

**为什么没被测试抓到**：这条证据的断言大概只检查了 `detail`（用途说明原文），
没检查 `location`。

### 2. 短 TLD 把长域名截断

**证据**（iOS 报告 50 个域名里）：

```
com.apple.co       ← com.apple.coremedia
io.agora.me        ← io.agora.media
dump.system.co     ← dump.system.core*
rtc.metering.co    ← rtc.metering.com*
data.report.co     ← ...
rtc.report.co
error.co / status.co / subviews.co / dump.co
1.3.com / com.app / com.net
```

**为什么**：`network_endpoints.dart` 的裸域名正则

```dart
r'\b([a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+'
r'(com|cn|net|org|io|co|ai|dev|app|info|me|tv|xyz|top|cloud|gov|edu)'
```

`co` / `me` / `io` / `app` / `dev` 这些短 TLD 在交替里，正则引擎会「尽早收工」：
`com.apple.coremedia` 中 `com.apple.` 吃掉前缀、`co` 命中 TLD，匹配就结束，
后面的 `remedia` 被丢弃。实测复现：

```
com.apple.coremedia   -> [com.apple.co]
io.agora.media        -> [io.agora.me]
dump.system.core      -> [dump.system.co]
```

**修法**：TLD 后面加负向断言 `(?![a-z0-9])`，要求它必须是标签的结尾。
一行正则，但要连带更新 `tlds` 那份常量（注释里已经警告过两处必须一致）。

**风险**：修完域名数量会减少（假域名消失），这会让真实样本的「域名数」变化 ——
`security_baseline.json` 里没有域名，所以不影响基线。

### 3. 否定结论被算进「能力主题」

**证据**：

| 报告 | 能力视图的行 | 问题 |
|---|---|---|
| Android | `数据外发 \| 1 \| ANDROID-RULE-F` | RULE-F 是「**未发现**上传特征」，被归到「数据外发」 |
| iOS | `其它 \| 13 \| … IOS-SCAN-COVERAGE …` | SCAN-COVERAGE 是**覆盖率元信息**，不是能力 |

读者扫一眼「数据外发 1 条」，会以为这个包有数据外发问题 —— 实际那条说的是
「我们没找到」。这与整个项目「不让否定结论读成风险」的原则直接冲突。

**修法**：能力视图里排除两类：
- `ANDROID-RULE-F` / `IOS-RULE-F` / `IOS-SCAN-COVERAGE` / `IOS-REPAKAGED` 这类
  **元信息或否定结论**；
- 更彻底的做法：给 `SecurityFinding` 加一个 `isMeta` 标记，由引擎声明「这条不是风险」，
  呈现层据此排除。前者是临时方案，后者是根治。

### 4. 结论段完全忽略 iOS 的高危发现

**证据**（`Ptv_signed_v3.ipa` 的结论段只有一行）：

```
## 结论
- 签名信息: 签名验证失败
```

而同一份报告的中段写着：

| 事实 | 位置 | 严重性 |
|---|---|---|
| `.app` 根目录有注入的 `kKipwwl.dylib` | `IOS-REPACKAGED [p2]` | 重打包的直接证据 |
| 描述文件授权的是 `com.nguyenkim.antbuddynkm`，应用声明 `aecy.Edimension168ecy.app` | 「签名与授权」 | **盗用他人描述文件的铁证** |
| 证书链是 Apple Provisioning Profile Signing | 「签名与授权」 | 企业/侧载签名 |
| `NSAllowsArbitraryLoads=true` + 图像/网络线索 | `IOS-RULE-D-ESCALATED [p1]` | p1 |

`analysis_report.dart:137` 的 `_conclusion` 只做了两件事：
签名结论、Android 的加固线索。**没有任何 iOS 分支**，也不看最高等级的发现。

于是「这个包被重打包、还挂着别人的描述文件」这件事，读者要翻到报告 60% 处才看见。

**修法**：结论段应该是「按等级取前 N 条 + 一行总述」，而不是「固定两行」。
至少补上：最高等级发现、重打包结论、标识不匹配。

---

## 二、质量问题

### 5. 组件与权限重复渲染

Android 报告的「Android 专属信息」表格里已经有一行把 18 个组件全列了
（用 `<br>` 分隔），紧接着又有「### 组件 (18)」一节把同样的 18 条再列一遍。
权限同理（表格里的 components 行 + `### 权限列表 (10)`）。

一份 9.6 MB 的包，报告有 274 行，其中约 40 行是纯重复。

**建议**：表格里只写「18 个（见下）」，不展开。

### 6. 中英混排

| 位置 | 内容 |
|---|---|
| `ANDROID-PERMISSION-WITHOUT-API` 证据 | `declared; no matching API marker found in the scanned DEX` |
| `IOS-PERMISSION-REQUEST` 局限 | `Only the selector table is checked. Permission requests issued from…` |
| `IOS-SCAN-COVERAGE` 局限 | `The scan only extracts printable ASCII strings: …` |

正文是中文（说明本地化生效了），但 `SecurityEvidence.detail` 和部分 `limitation`
仍是英文硬编码。中文界面下这是明显的断裂。

`limitation` 有 `limitationCode` 机制，但上面这几条要么没填 code，要么代码里
直接写了英文字符串。

### 7. 覆盖率 `covered/limit` 与 `status` 不同源（第五次实例）

iOS 报告：

```
| Mach-O 调用点 | 已覆盖 | 24490/24490 | …（二进制共 155317 个函数）… |
| 可执行文件   | 部分覆盖 | 20/69     |
```

「调用点 24490/24490 已覆盖」读起来是「全都看了」，但那只是**20 个文件之内**的
数字 —— 另外 49 个可执行文件里的引用根本没进这个分母。

严格辩护是成立的（这一维的语义是「引用→函数的归属率」，不是文件覆盖率），
但读者不会这么读。这是同一个 bug 模式的第五次出现（前四次：
`android.nativeHardening`、`android.nativeSymbols`、`android.arsc`、`ios.executables`）。

**建议**：`ios.machoSites` 的 note 里补一句「仅覆盖 20/69 个可执行文件」，
或者把这一维的 `limit` 改成「所有可执行文件里的引用总数」（需要扫全部，成本高）。

---

## 三、细节打磨

| 项 | 现象 | 建议 |
|---|---|---|

| 域名无覆盖率 | 网络端点没有对应的覆盖维度，读者不知道「提取了多少 / 漏了多少」 | 加一维，或至少说明来源（哪个文件的哪类字符串） |
| `READ_PRIVILEGED_PHONE_STATE` | 被列在「未纳入风险目录」的事实记录里 | 这是 `signature\|privileged` 权限，第三方应用声明了也拿不到 —— 应明确说「声明无效」 |
| iOS `IOS-PHOTO-PICKER` 证据 | `/System/Library/Frameworks/PhotosUI.framework/PhotosUI` 是**链接的框架路径** | 任何链接 PhotosUI 的应用都会命中；应改用选择子（`PHPickerViewController`） |
| `ANDROID-RULE-F` 的覆盖率前提 | 正文说「未发现上传」，而 DEX 只扫了 49% | 应在正文里带上「只扫了 49%」，否则这条否定结论过强 |
| iOS 域名数量 | 50 条上限（`maxEndpoints`），修完碎片后剩多少不知道 | 上限本身合理，但应标注「已截断」 |

---

### 一处更正

初稿里我写「空诊断表仍渲染了表头」——**那是看错了**。`_diagnostics` 在
`result.diagnostics.isEmpty` 时直接 `return`，本来就没有表头。原文只有
「没有记录任何诊断」一句，是正确的。

同理，「`covered/limit` 与 `status` 不同源」这一条，严格说 `ios.machoSites`
的语义是「引用→函数的归属率」，不是文件覆盖率 —— 措辞需要补（已改），
但不算 bug。

## 四、建议的处理顺序

1. ~~**`$entry.key` 插值**~~ ✅ 已修（`1ab86fb`）
2. ~~**域名正则加边界断言**~~ ✅ 已修
3. ~~**能力视图排除元信息 / 否定结论**~~ ✅ 已修（`SecurityFinding.isMeta`）
4. ~~**结论段改为「按等级取前 N 条」**~~ ✅ 已修
5. ~~组件 / 权限去重、中英混排~~ ✅ 已修
6. ~~覆盖率措辞与其余细节~~ ✅ 已修

全部落在 `1ab86fb`。语料基线因 `photos-ui` 去伪而重新生成 —— 见下节。

## 五、修完的连带发现：10 个样本的假阳性

去掉 `photos-ui` 这条弱证据之后，12 个真实 IPA 里只有 2 个真的有
`PHPickerViewController`。其余 10 个此前都因为**链接了 PhotosUI** 被判「有照片
选择器」，于是 `IOS-RULE-A`（广泛相册访问却没有选择器路径）**不成立** ——
假阳性把一个更严重的问题盖住了。

拿 `皇冠-v6.9.63.ipa` 验证过：`picker_selector=false`，它确实只有
`PHPhotoLibrary` + `PHAsset`。新结论 `IOS-RULE-A [p2]` 是对的。

这条正好印证评审里那句话：**错误的正向证据比没有证据更糟** —— 它不只是多报
一条，还会让真正该报的那条不出现。
