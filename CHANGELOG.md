# Changelog

## 2.4.14 — 2026-10-18

> 安全分析能力审计（`docs/audit/2026-10-18-security-analysis-capability-audit.md`）
> 提出的 7 项建议**全部落地**。评分 65 → **74/100**。
> 核心不是「多查了什么」，而是**让报告里的覆盖率数字说真话**。

### 安全修复

- **原生库覆盖率此前是虚高的。** 抖音 343 MB 的包有 **266 个唯一库名**，
  只扫了 24 个，覆盖表却写「24/24 已覆盖」—— 因为 `limit` 用的是「传进审计
  的条目数」，而 `selectLibraries` 挑剩下的 242 个库**没有任何消费者**，
  在报告里完全不可见。现在 `limit` 用全包唯一库名数，`status` 把「选择阶段
  被跳过」也算 `partial`，并新增一条带数量的未扫描说明。
  **修后：`partial 24/266` + 「242 个原生库完全没有被扫描」。**
- **大包字符串扫描只覆盖约 11%，而覆盖表看不出比例。** `dex.strings` 的
  `limit` 改为 DEX 总字节。实测：抖音 **11.0%**、`49af6cnn` 90.0%、
  `138_1018` **5.8%**（一个 145 MB 的单 DEX 只扫了前 8 MiB）。
- **iOS 主可执行文件有 47% 没扫。** 单文件预算 16 → **64 MiB**。
  `sun_signed.ipa` 的主二进制 34.3 MiB，原先后 19.2 MiB 完全没看 ——
  2.4.13 那个「声明了相机但没实现」的误报就是这么来的。
  **修后 `ios.macho.strings` 从 `partial` 变 `covered`，`IOS-CAMERA` 正常产出。**
- **iOS 原生符号只扫主可执行文件。** 25 个可执行文件里 24 个的符号表没看。
  现在嵌套 bundle 一并扫描：`ios.nativeSymbols` 从 `covered 1` 变
  **`covered 25/25`**（并有了分母）。
- **权限重复声明产生重复发现项。** 抖音把 `ACCESS_COARSE_LOCATION` 声明了两次，
  界面出现两张一模一样的卡片。按 `(name, maxSdkVersion, sdk23Only)` 精确去重 ——
  同名但 `maxSdkVersion` 不同的仍是两条（一条可能已过期、一条仍生效）。

### 新增检测

- **`ANDROID-RULE-G`**：敏感数据来源 + 上传。此前 6 条组合规则里 4 条是图片链，
  而「通讯录 / 短信 / 定位 / 录音 / 剪贴板 / 设备标识 → 上传」这类最常见的外传
  模式**一条规则都没有**，只有 INFO 级权限条目。
  **按来源稀有度分级**：通讯录 / 短信 / 录音 → P2（正常应用里「读这些 + 上传」
  并不常见），定位 / 剪贴板 / 设备标识 → P3（几乎每个应用都有，一律 P2 会让这条
  规则在九成应用上出现，读者会学会忽略它）。
  三条防误报约束都写了测试：只有来源不报、只有上传不报、只有字符串线索时
  `dataTransform` 留 null。
- **iOS 通讯录 / 定位 / 麦克风的「声明 vs 实现」双向对照**：
  有 API 没声明 → `IOS-USAGE-MISSING-FOR-API`（P2，运行时会崩、上架被拒）；
  有声明没 API → `IOS-USAGE-WITHOUT-API`（info，过度声明）。
  麦克风刻意不收 `AVAudioSession`（播放也要用），反向检查则把 `AVCapture`
  也算作实现证据（`AVCaptureSession` 配音频输入同样能录音）。
- **Android 相机 API 与录屏**：新增 `android.hardware.camera2` /
  `android.hardware.Camera` 标记（此前「能不能拍照」只能从权限推）；
  `MediaProjection` 从 OCR 线索里摘出来，单列 `ANDROID-SCREEN-CAPTURE`（P3）——
  录屏抓的是画面，不是识别文字。
- **`ANDROID-SPECIAL-ACCESS`**（P3/confirmed）：无障碍服务 / 设备管理器 /
  通知监听。判据是**清单里组件的 `android:permission="...BIND_*"`**，
  不是 DEX 字面量 —— 后者在真实样本上立刻误报：飞牛TV 的「无障碍」来自
  Material 的 `MaterialAutoCompleteTextView` 查询 `AccessibilityServiceInfo`，
  子串匹配把 UI 库的正常调用算成了无障碍服务。修后只有真正声明了
  `BIND_ACCESSIBILITY_SERVICE` 的包（如抖音）才报。
- **三个新标记**：`TelephonyManager`（设备标识）、`ContactsContract`（通讯录）、
  `DexClassLoader`（运行时加载）。最后一个**不产出风险结论**，只进「覆盖不足」——
  被加载的代码不在归档里，静态分析的结论对那部分不成立。
- **`ANDROID-RULE-F` 补证据**：否定结论也要说明「查了什么」（N 个 DEX /
  M 个调用点），否则它与「根本没查」在数据上无法区分。

### 质量

- 测试 **1,303 → 1,408**（+105）。新增 `audit_coverage_honesty_test.dart`（9）、
  `android_sensitive_source_rule_test.dart`（10）、
  `audit_permission_and_rulef_test.dart`（6）、
  `ios_native_symbols_nested_test.dart`（7）、
  `android_sensitive_source_extended_test.dart`（19）、
  `ios_usage_capability_matrix_test.dart`（15）、
  `android_camera_and_screen_capture_test.dart`（8）、
  `android_manifest_hygiene_test.dart`（19）、
  `manifest_attr_resolution_test.dart`（12）、
  `framework_attr_names_test.dart`（5，在 `packages/apk_parser`）。
- 真实样本回归：抖音 55/55 DEX、端到端 **14.13 s**；
  `sun_signed.ipa` 静态解析 **239.9 ms**（+7.8%，预算从 16 提到 64 MiB 的代价）。
- **验证轮已把这几项做完**（见下一节）：界面目视、NSC 展开、真实 XAPK、
  联网下载、Windows / Linux。

### 第四轮：清单配置维度 —— 以及两处「输出正常但内容是错的」的解析缺陷

#### 新增检测（清单层，此前完全没查过）

- **`ANDROID-DEBUGGABLE`（P1）**：`android:debuggable="true"` 出现在发布包里，
  任何人拿到设备就能 `run-as` 进应用、读内存、替换代码。
- **`ANDROID-EXPORTED-COMPONENT`（P2 / P3）**：导出且没有 `android:permission`
  保护的组件。有 `ContentProvider` 时 P2（直接暴露数据），否则 P3。
  **启动页（MAIN/LAUNCHER）排除** —— 它必须导出，报它等于每个应用都报一条；
  `exported` 未声明时不替平台猜默认值（默认取决于 intent-filter 与 targetSdk）。
  实测抖音有 **159 个**，正文只点名前 12 个（provider 优先）并明写「另有 N 个」，
  证据行上限 20 —— 6 KB 正文 + 159 行证据只会让人跳过整块面板。
- **`ANDROID-ALLOW-BACKUP`（P3）**：显式 `allowBackup="true"`，`adb backup`
  可整包导出应用私有数据。只报显式 true；未声明时默认也是 true，
  但那样每个包都会报。

#### 修掉的解析缺陷（严重性高于上面三条新规则）

- **框架属性表 63 条里 51 条 ID 错位。** `_kFrameworkAttrNames` 把
  `0x01010010` 记成 `resource`（实为 **`exported`**）、`0x01010280` 记成
  `screenSize`（实为 **`allowBackup`**）、`0x01010018` 记成 `debuggable`
  （实为 `authorities`）…… 而 `_resolveStringOrResourceId` 是**表优先**的
  （混淆包会重写字符串池里的属性名，资源 ID 改不动）。于是
  `android:exported` / `debuggable` / `allowBackup` / `usesCleartextTraffic`
  在**所有真实包**上都读不到 —— 意味着 **`RULE-D`（明文流量）从上线起就在
  真实包上静默失效**，`AndroidComponent.exported` 恒为 `null`。
  **单测一直是绿的**，因为用例都手工构造 `ApkMeta`：测的是「拿到一个 bool
  之后规则怎么判」，不是「这个 bool 能不能从字节里拿到」。
  修法：表重写为 aapt2 权威值并**裁剪到解析器真正消费的 20 条**；新增
  `packages/apk_parser/test/fixtures/android_34_attrs.txt`（aapt2 输出的
  1,545 条快照）逐条比对；新增 `test/fixtures/apk/attr-fixture.apk`
  （`aapt2 link` 真实产出）走完整条「字节 → ApkMeta」链路。
- **每一个 `true` 都被读成 `false`。** AXML 的 `tvData` 按**有符号** 32 位读，
  而 `true` 的规范编码是 `0xffffffff`（即 `-1`），旧代码写
  `data == 0xffffffff` —— 永远不成立。这比「读不到」更糟：读不到至少是 `null`
  能被发现，读成 `false` 是一个看起来很正常的具体值。改成平台侧同一条判据
  （非 0 即真）。

#### 属性一旦能读，两个事实错误立刻显形

- **`RULE-D` 与 `networkSecurityConfig` 的优先级。** 修完上两条后，5 个真实包
  里 **4 个** `usesCleartextTraffic=true`，规则 D 以 **P1** 出现在 80% 的应用上。
  而 AOSP `ApplicationInfo` 明确写着：API 24 起，只要声明了
  `android:networkSecurityConfig`，`usesCleartextTraffic` **就不再生效**。
  也就是说其中 3 个（抖音、飞牛、飞牛TV）的报告是**事实错误**，不只是说得太重。
  当时的处理是：NSC 存在时这一维**不予判定**，并在覆盖率里单列
  `android.cleartextPolicy`（partial + 说明），**不能静默消失**。

  > **这一步走错了，见下面「验证轮」§1。** 「属性被忽略」不等于「策略不成立」：
  > 真正该做的是**打开那份 NSC**。展开后这 3 个包的
  > `base-config cleartextTrafficPermitted="true"` —— 它们确实允许明文，
  > 规则 D 原本就报得对；「不判定」反而会把真发现吞掉。
- **导出组件列表刷屏。** 见上面的点名上限。

#### 评分

安全分析能力 **78 → 81 / 100**（`docs/audit/2026-10-18-security-analysis-capability-audit.md` §12）。
新增的是清单配置维度；更值钱的是修正了两处「输出看起来正常但内容是错的」缺陷 ——
它影响的是**已有**结论的可信度。

### 验证轮：把上一轮列的「未验证」逐项做掉

五项里 **三项通过、一项部分通过、一项做不到**，并且**抓到一个让真实下载
100% 失败的 bug**。测试 1,408 → **1,430**。

#### 1. NSC 真正展开 —— 并推翻了上一轮的结论

上一轮的处理是「声明了 `networkSecurityConfig` 就不判定明文策略」。推理没错
（属性确实被平台忽略），**结论错了**：真正该做的是**打开那份 XML**。

现在走完整条链路：资源 id → `resources.arsc` 里的文件路径 →
归档条目（有界读取）→ AXML → `NetworkSecurityConfigInfo`。
顺带给 AXML 补了**文本节点**：`<domain>api.example.com</domain>` 的域名在
`RES_XML_CDATA_TYPE` 里，此前是显式跳过的 —— 不补就只能数出「有 2 条规则」。

真实样本（aapt2 独立核对）：抖音 `r/7cm.xml`、飞牛与飞牛TV `res/8G.xml`，
三份都是 `base-config cleartextTrafficPermitted="true"` —— **它们确实允许明文**，
规则 D 原本就报得对。上一轮说的「3 个是事实错误」是错的；按「不判定」上线
反而会把这 3 个真发现静默吞掉。

证据改为指向真正生效的那份配置（`network security config (res/8G.xml) /
base-config`），并新增 `SecurityEvidenceSource.networkSecurityConfig` ——
否则界面上会打「AndroidManifest.xml」的标签，而证据行写的是 `res/8G.xml`。

#### 2. 界面目视：换了一条路

`RepaintBoundary.toImage()` 在本机**会让整个测试进程被 SIGKILL**（退出码 137，
无任何输出，关掉工具沙箱也一样）。改走 web 构建 + 无头 Chrome 截图，
步骤与症状记在 `docs/notes/ui-snapshot.md`。

看到的：抖音的导出组件卡片 12 个名字 + 「另有 147 个未列出」，约 10 行；
规则 D 正文是中文；覆盖率面板出现「明文流量策略 1/1」；
三种夹具在 920px 宽下都没有溢出与竖排文字。

#### 3. 联网下载：抓到 `Content-Encoding` 缺陷（本轮最值钱的一条）

第一次真的联网跑，build-tools **100% 失败**：

```
incomplete download: got 81933386 of 81667633 bytes
```

收到的比声明的多 265,753 字节 —— `HttpClient` 默认 `autoUncompress: true`，
`Content-Length` 是**编码后**长度而流里给的是**解码后**字节。同一个原因还让
索引下载的进度变成 **946%**。

修法：完整性检查只在 `compressionState == notCompressed` 时比字节数
（真正的完整性由 SHA1 校验保证）；编码过的响应进度报「总量未知」。

修复后真实下载通过：index ✓ → archive ✓ → **SHA1 verified** →
`build-tools/37.0.0/aapt2` 可执行（`aapt2 version` 退出 0）→ 临时目录无残留。
新增 `tool_download_encoding_test.dart`（2 条），并已确认这两条在旧实现下变红。

#### 4. 真实 XAPK：只做到部分

APKPure 的下载端点对非浏览器客户端一律 **403**（带 UA/Referer 也一样），
没能下到线上样本。退一步：容器按公开规范自打，内层 APK 用 `aapt2 link --split`
真实产出，`manifest.json` 里刻意把同一分包列两次。

验证到：`getSplitApks` 去重后返回 2 条、返回的是**归档条目名**、
两条都能被 `ApkReader` 解析（base 有启动页，config split 没有应用级字段）。
**没验证到**：真实打包器的边角字段、obb 展开、真机 `adb install-multiple`。

#### 5. Windows / Linux：只能静态审计

CI 有 `build-windows`（windows-latest）与 `build-linux`（ubuntu-latest）两个 job；
平台分支逐项核对过（`.exe`/`.bat` 后缀、`PATH` 分隔符与 `PATHEXT`、
`chmod` 由 `!Platform.isWindows` 挡住、`explorer.exe`/`open`/`xdg-open` 齐全）。
本轮新增的 NSC 展开只用归档条目名（`/` 分隔）做 `archive.findFile`，
**从不落到文件系统**，不受平台分隔符影响。
**没验证到**：真机运行、文件关联注册、安装对话框里的 `adb` 调用。

#### 评分

安全分析能力 **81 → 82 / 100**。方法论上的收获比分数重要：
**五个「未验证」里两个一验就发现了真缺陷**（NSC 结论是反的、下载 100% 失败），
而它们此前都通过全绿的门禁 —— 「测试全绿」只证明已写下的断言成立，
不证明没写的那部分对。

### 第一档：把「数据已经在手但没人读」的四项接上

上一轮盘点出的第一档全部落地。测试 1,430 → **1,456**。

| 缺口 | 此前的错误结论 |
|---|---|
| `android:sharedUserId` | 与同签名应用共享沙箱这件事**完全不可见** |
| `android:protectionLevel` | 导出组件只要写了 `android:permission` 就当「受保护」 |
| `fullBackupContent` / `dataExtractionRules` | `allowBackup="true"` 就说「整包数据可被备份」 |
| iOS `get-task-allow` | iOS 侧**没有** debuggable 这条规则（Android 侧是 P1） |

#### 新增规则

- **`ANDROID-SHARED-USER-ID`（P2）**：声明了 `sharedUserId`，与同签名的其它
  应用共享 UID 与沙箱。只报声明事实（是否真有同 UID 应用装在设备上无法静态判断）。
- **`ANDROID-EXPORTED-COMPONENT` 的语义修正**：`android:permission` 指向
  **本包自己声明**且 `protectionLevel` 不是 `signature` 的权限时，视为
  **没有保护** —— `normal` / `dangerous` 级权限任何应用都能申请。
  正文措辞随之换成 `without an effective android:permission guard`，
  并新增 `android.exported_component_weak` / `_weak_many` 两个文案。
  框架权限与别包声明的权限看不到级别，**保守当成受保护**（猜错要偏向不误报）。
- **`IOS-GET-TASK-ALLOW`（P1）**：描述文件授予 `get-task-allow=true`，
  调试器可附加进程。这是 iOS 的 `debuggable` —— 此前两侧能力不对称。
- **`IOS-PUSH-SANDBOX`（P3）**：`aps-environment="development"`，
  推送绑定沙箱环境，说明是开发签名。
  刻意**不报** `keychain-access-groups` / `application-groups` /
  `associated-domains` —— 正常应用里太常见，报了读者会忽略整个面板。

#### 语义修正（比新规则更值钱）

- **备份被规则关掉时不报**：`fullBackupContent="false"`（API 23–30）或
  `dataExtractionRules="false"`（API 31+）会彻底关闭自动备份，
  此时再报 `allowBackup="true"` 是**事实上不成立**的发现。
- **备份规则文件要在证据里点出来**：只列引用形态（`@res/0x...`）。
  实测飞牛写了 `fullBackupContent="true"` —— 那不是这个属性的合法值，
  把它当「有规则清单」列出来等于替平台解释一个无效值。
- **iOS 覆盖率新增 `ios.entitlements`**：没有 `embedded.mobileprovision`
  （App Store 分发把授权项放在签名里）时标 **notApplicable**，
  不能说成「已覆盖、没问题」。

#### 真实样本抓到的第一个实例

抖音有 **2 个**导出 receiver（`CardLifecycleReceiver` /
`CardProjectStatusReceiver`）只由
`com.ss.android.ugc.aweme.permission.sendXiaoYiCardInfo` 保护，而这条权限
**没有声明 protectionLevel**（平台默认 `normal`）—— 任何应用都能申请到它，
等于没有保护。导出组件从 159 变成 **161**。

同时修了一个呈现缺陷：证据上限 20 条，按类型排序时 activity 排最后，
这 2 个弱权限组件正好被挤出上限 —— 正文说「effective guard」而 20 条证据
全写「without android:permission」，读者会认为工具在乱说。
现在弱权限证据优先列，**正文声称了什么，证据里就有对应的一条**。

#### 又一次「值读到了但形态不对」

`android:protectionLevel` 在 AXML 里是**整数标志位**（`0x0`=normal、
`0x2`=signature），不是字符串。按字符串找 `"signature"` 永远找不到，
规则会静默不生效。这是本项目第三次踩这一类坑（前两次：属性 ID 错位 51/63、
布尔值 `0xffffffff` 被读成有符号 `-1`）。
现在 `protectionLevelValue` 按位解析，`protectionLevelText` 输出
`signature|privileged` 这种可读形态供证据行使用。

### 第二档：签名方案、WebView 桥、权限交叉核对、iOS 组合规则

测试 1,456 → **1,491**。

#### 新增：APK Signing Block 解析（回答「有没有 v2+ 签名」）

签名结论此前**完全**交给 `apksigner`，于是没装工具就一律「未验证」，
也看不出「**只有 v1 签名**」。后者不是学术问题：v1（JAR）只保护 ZIP
**条目内容**的摘要，**不保护 ZIP 结构** —— 往归档里塞入额外条目
（额外的 dex / 资源 / so）不会让 v1 失效，那是重打包最省事的形态。

现在读 EOCD → 中央目录偏移 → 往前 24 字节找 `APK Sig Block 42` →
按 pair 解析 v2 (`0x7109871a`) / v3 (`0xf05368c0`) / v3.1 (`0x1b93ad61`)。

**分工不变**：只回答「块在不在、里面有哪些 id」，不验证任何签名。
`readSigningSchemes` 的失败路径与「没有签名块」严格分开 ——
`parsed == false` 绝不折成 `v1Only`，那是把「我们没看到」说成
「这个包只有 v1 签名」。

真实样本与 apksigner 逐条一致：

| 样本 | 本项目 | apksigner |
|---|---|---|
| `49af6cnn-1018` | `[v2, v3]` | v1/v2/v3 = true/true/true |
| `app.apk` | `[v2]` | v1/v2/v3 = false/true/false |
| `抖音-v40.7.0` | `[v2, v3]` | — |
| `飞牛-v1.37.1` | `[v2]` | false/true/false |
| `飞牛TV-v1.4.1` | `[v2]` | — |

新增规则 **`ANDROID-V1-ONLY-SIGNING`（P3 / independentCapability）**：
只报签名方案事实，**不**推断「被篡改」—— v1-only 的包完全可以是合法有效签名。

#### 新增：`ANDROID-WEBVIEW-BRIDGE` —— 从 P2 降为 P3，理由是真实样本

`addJavascriptInterface` 是 Android 最经典的 RCE 面，一开始给了 P2。
真实样本上 **5 个包有 4 个命中**，而证据显示调用点**全部来自第三方 SDK**：

| 样本 | 调用点来自 |
|---|---|
| `49af6cnn` | Adjust、极验 Geetest、hCaptcha、神策 |
| `app.apk` | 极光推送、Facebook AppEvents、网易易盾 |
| `抖音` | 字节 webx / 小程序容器 |
| `飞牛` | flutter_inappwebview 插件 |
| `飞牛TV` | 无 |

验证码 / 统计 / 社交分享这类 SDK 必须用 JS 桥才能工作，它几乎是每个
现代应用的标配。按 P2 报等于在 80% 的应用上出现 —— 与 RULE-D 同一类错误。
改成 **P3 + 正文与 limitation 都说明「多数来自第三方 SDK，先看调用点」**。

#### 新增：`ANDROID-PERMISSION-WITHOUT-API`（P3）

iOS 早就有 `IOS-USAGE-WITHOUT-API`（声明了没用），Android 侧没有对应物。
现在只对**判据明确**的权限做交叉核对（读通讯录必然碰 `ContactsContract`、
读短信必然碰 `SmsManager`）—— `WRITE_EXTERNAL_STORAGE` 这类可能只走
`java.io.File` 的**不编目**，硬判会误报。

两道闸：**没扫过 DEX 就不判**（「没看到」不是「没有」）；`sdk23Only`
的声明不参与（生效条件无法静态判定）。

真实样本抓到 1 例：抖音声明了 `READ_CONTACTS`，40 个 DEX 里没有
`ContactsContract`。

顺带修了一个既有误判：`RECORD_AUDIO` 的代码证据此前只认 `MediaRecorder`，
用 `AudioRecord` 直读 PCM 的应用会被判成「声明了没用」。已补
`recording-audiorecord` 标记。

#### 新增：`IOS-RULE-G` —— iOS 缺的那条组合规则

Android 有 `ANDROID-RULE-G`（通讯录 / 短信 / 录音 → 上传），iOS 只有
A/B/C/E/F。现在补上，分级按来源稀有度：通讯录 / 麦克风 → **P2**，
只有定位 → **P3**（`IOS-RULE-G-COMMON`）—— 定位几乎每个应用都有。

三条规则各自成立不合并：C 是图片链、E 要后台、G 只要两段。

### 第三档：原生库二进制加固 —— 以及一个只在真实包上才看得见的发现

测试 1,491 → **1,520**。

#### 新增：`ElfHardening`（NX 栈 / RELRO / BIND_NOW / 栈保护 / strip）

读程序头与动态段，不反汇编：

| 属性 | 判据 |
|---|---|
| NX 栈 | 有 `PT_GNU_STACK` 且 `p_flags` 不含 `PF_X` |
| RELRO | 有 `PT_GNU_RELRO` |
| BIND_NOW | `DT_FLAGS & DF_BIND_NOW` 或 `DT_FLAGS_1 & DF_1_NOW`（**两个都要查**）|
| 栈保护 | `.dynsym` 里导入 `__stack_chk_fail` |
| 已 strip | 没有 `.SHT_SYMTAB` 节 |

三个容易错的二进制细节：`p_flags` 在 64 位位于偏移 4、**32 位位于偏移 24**；
`DT_FLAGS` 与 `DT_FLAGS_1` 是两个 tag；`.symtab` 会被 strip 掉，所以栈保护
必须查 `.dynsym`。

#### 最重要的决定：这一维**只报一条**

实测 4 个真实包的 **386 个** arm64 `.so`（`llvm-readelf` 逐个数）：

| 属性 | 不满足的库数 |
|---|---|
| 可执行栈 | **0** |
| 缺 RELRO | **1**（Flutter 的 `libapp.so`，Dart AOT 快照）|
| 缺 BIND_NOW | **1**（同一个）|
| 未 strip | **0** |

NDK 默认就带 `-z relro -z now` 与 NX 栈。所以：

- **只对「可执行栈」产出 `ANDROID-NATIVE-EXEC-STACK`（P2）** —— 没有哪种正常
  构建需要它，出现即缺陷；
- 缺 RELRO 写进覆盖率的说明（`android.native_hardening.some_without_relro`），
  因为它是合法构建选择，逐库报会命中**所有** Flutter 应用；
- 覆盖率给**数字**（「386 个库里 385 个是 Full RELRO + NX」），不逐库列举。

#### 顺带抓到一个只在真实包上出现的发现

抖音的 `lib/arm64-v8a/libsm_impl.so`（162,912 字节）头部是 **`dex\n035`** ——
**不是 ELF，是一段 DEX 字节码**。文件名完全合规（`lib*.so`、在 `lib/arm64-v8a/` 下），
**只看名字的检查永远发现不了**。

新增信号 `HardeningSignal.dexDisguisedAsNativeLibrary`（`strong` 级）。
它与既有的 `dexHeaderNotStandard` 是反向的两件事：

| 信号 | 含义 |
|---|---|
| `dexHeaderNotStandard` | 文件名像 DEX，内容不是 |
| `dexDisguisedAsNativeLibrary` | 文件名像原生库，**内容是 DEX** |

后者是具体的隐藏手法：只扫 `classes*.dex` 的工具完全看不到这段代码，
运行时用 `DexClassLoader` 从 `lib/` 目录直接加载。

#### 夹具

七个 `.so` 由 **NDK 25.1** 的 clang 真实编译（`hardening-native.c`），
期望值用 `llvm-readelf` / `llvm-nm` 独立核对：
`default` / `execstack` / `norelro` / `partial-relro` / `no-canary` /
`canary` / `canary-stripped`。

其中 `hardening-default` 是一个**反例夹具**：同样的源码与默认 flags，
它没有 `__stack_chk_fail` —— 所以「没有这个符号」不能读成「没开栈保护」。

### 第四档：第三方服务类 SDK 盘点 —— 以及一次「在最需要它的包上返回 0」的返工

测试 1,520 → **1,520**（新增 24 条在 `apk_parser` 包内）。

#### 先量，再决定收哪些前缀

候选 60 个前缀在 4 个真实包（86 DEX / 431 MiB）上量了一遍：

| 前缀 | 4 个包里的命中数 |
|---|---|
| `okhttp3` | **4** |
| `com/google/gson` | **4** |
| `com/google/android/material` | **4** |
| `com/airbnb/lottie` | **4** |
| `com/geetest` | 1 |
| `com/hcaptcha` | 1 |
| `com/sensorsdata` | 1 |
| `com/tencent/bugly` | 1 |

前四个是**基础工具库**（HTTP / JSON / UI / 动画）—— 它们出现在几乎每个应用里，
列出来等于「每个应用都有第三方库」，一句废话。所以目录**只收有服务含义的**
24 个：统计归因、推送、验证码风控、社交登录、地图、崩溃上报、对象存储、RTC。

#### 一次返工：`string_ids` 取代字节扫描

第一版复用 `DexClueScanner`（暴力扫全部字节、单 DEX 8 MiB、总计 48 MiB）。
真实样本立刻打脸 —— **抖音 55 个 DEX 命中 0 个**，而直接搜字节能找到 175 次
`com/tencent/mm/opensdk`。

量了成本才看清原因：

| `maxTotalBytes` | 耗时 | 命中的服务类 SDK |
|---|---|---|
| 48 MiB（生产默认） | 1.9 s | **0 个** |
| 128 MiB | 5.2 s | 2 个 |
| 512 MiB | 14.4 s | 3 个 |

**不是阈值的问题，是位置的问题**：DEX 的 `string_data` 在文件后半部分
（头 → id 表 → class_defs → data），单文件 8 MiB 的上限把它整段截掉了。
抖音的 DEX 平均就有 8 MiB —— 也就是说**在最需要这个功能的包上，它返回 0**。

改成按 `string_ids` 精确索引（`SdkInventoryScanner`）：读 DEX 头两个字段、
按每个 `string_id_item` 的偏移跳到 `string_data_item` 读前缀，不需要扫全部字节。
结果：

| 包 | 修复前 | 修复后 |
|---|---|---|
| 49af6cnn | 5 个 | **8 个**（覆盖 6/6 DEX）|
| app.apk | 7 个 | **8 个**（5/5）|
| 抖音 | **0 个** | **5 个**（40/40）|
| 飞牛 | 1 个 | **2 个**（3/3）|

#### 顺带修正一处分类

`Google Play services` 与 `Firebase` 原本归在 `analytics`。它们是**一组**
API（地图 / 认证 / 推送 / Analytics），不是「一个分析 SDK」—— 实测
49af6cnn 里 `gms` 有 4,276 个类，归到 analytics 会让「分析 SDK」那一栏永远
排第一，盖住读者真正想看的 Adjust（211 个）。新增 `platform` 类别。

#### 判据与边界

- **阈值 20 条引用**：真打包进来的 SDK 是几百到几千，配置字符串里提一句的是个位数；
- **边界必须精确**：`L<prefix>/` 或 `L<prefix>;` —— 否则 `com/tencent/mm`
  会吃掉 `com/tencent/mmkv`（有测试钉住）；
- **info 级 + independentCapability**：这是清单，不是风险结论；
- **不提供出厂判定**：目录里没有单段前缀（会把整片包名卷进来），有测试守着。

#### 覆盖率

新增 `android.sdkInventory`：`covered` / `limit` 用**真正读到的 DEX 数**，
`complete` 要求「没有读不出、没有截断」。实测抖音 40/40、飞牛 3/3。

### 第五档：`Assets.car` 索引 —— 能列出图，但不提像素

测试 1,520 → **1,521**（`ipa_parser` 54 → **74**）。

#### 做了什么

新增 `parseAssetsCar`：解析 BOMStore 容器，把每个 `ISTC` 块读成
「rendition 名 + 宽高 + 像素格式 + 压缩方式 + 字节数」。

`IpaIconResolver` 的 `CFBundleIconName` 分支不再只说「需要一个解析器」——
现在**真的读一遍那个容器**，把「里面有什么」说出来：

```
the icon lives inside Assets.car: 3 image(s) with pixel data, but none is
named like AppIcon, ... The pixel data is LZFSE-compressed in any case,
so it could not be previewed without a decoder either
```

#### 明确的边界：不解码像素

测了 5 个系统 `Assets.car`：**一个 PNG/JPEG 都没有**，全是 ARGB/BGRA 原始像素
**再经 LZFSE 压缩**（`bvx2`）。1024×1024 图标未压缩 4,194,304 字节，
`SizeOnDisk` 只有 311,137（13.5:1）。

Dart 侧没有 LZFSE 实现，**所以这一档只交付索引**。要真正取图还需要
LZFSE 解码器（500–700 行）+ PNG 编码器（~200 行）——那是独立的一件事，
写了 `docs/notes/assets-car.md` 留档。

#### 四个实测踩过的坑（都写进了测试）

1. **端序混用**：`BOMStore` 头与块表是**大端**，`RATC` 与 `ISTC` 头是**小端**。
   按大端读 `RATC` 的版本字段会得到 285212672 / 4077060096。
2. **块表条目数不是 `indexOffset` 处的那个 u32**（读出 256，真实是头里的
   `blockCount`）。四种候选布局里只有 `delta=4, stride=8` 能自洽。
3. **4CC 反序存**：文件里 `BGRA` 表示 `ARGB`、`GA8 ` 读出来是 ` 8AG`。
4. **「空壳」rendition**：宽高齐全但块只有 334 字节、内容全 0
   （Music.app 有 5,694 个）。新增 `embedsPixels` 判据把它们与真图分开。

#### 期望值来源

**唯一的独立实现是 macOS 自带的 `/usr/bin/assetutil --info`**，输出 JSON 里有
`PixelWidth`/`PixelHeight`/`Encoding`/`SizeOnDisk`/`RenditionName` ——
正好覆盖本实现的每个字段。夹具 `test/fixtures/car/installer-progress.car`
是系统真实产物（18 KB、4 张图），README 里存了 assetutil 的原始输出。

逐条对照全部一致：`Gray` ↔ `GA8 `、`ARGB` ↔ `ARGB`、字节数逐字节相等。

### 第六档：LZFSE 解码 —— 把「不解码」这条边界推后

测试 1,521 → **1,525**（`ipa_parser` 74 → **98**，+24）。

#### 做了什么

上一档说「要真正取图还需要 LZFSE 解码器（500–700 行）+ PNG 编码器」。
这一档把它们写了，而且是**纯 Dart、零新依赖**：

| 文件 | 行数级 | 职责 |
|---|---|---|
| `packages/ipa_parser/lib/src/lzfse.dart` | ~600 | LZFSE 解码（`bvx2` / `bvx-` / `bvx$`） |
| `packages/ipa_parser/lib/src/png_encoder.dart` | ~200 | 扫描行 → PNG（zlib 走已有的 `package:archive`） |
| `packages/ipa_parser/lib/src/assets_car_extract.dart` | ~250 | 索引 → 解码 → 编 PNG 的整条链 |

`AssetsCarImage` 新增 `payloadOffset`：就是块内 `bvx2` 魔数的绝对偏移 ——
LZFSE 的流以这个魔数开头，从这儿读到块尾即可。

#### 正确性是怎么证明的

**不是「解出来看着像图」，是逐字节比对两个独立实现。**

`test/fixtures/lzfse/` 里 6 个夹具全部由 macOS 自带 `libcompression`
（`COMPRESSION_LZFSE`）**真实压缩**产出，同名 `.bin` 是压缩前原文。
所以「解码 `.lzfse` 得到 `.bin`」这条断言，等价于说
**我们的纯 Dart 实现与 Apple 自己的实现逐字节一致**。

覆盖的路径是刻意挑的：`empty`（只有结束块）、`zeros`（54:1，M 值取到上限
2359）、`incompressible`（走 `bvx-` 未压缩路径，输出比输入还大）、
`pixel-like`（渐变 + 噪声的类 BGRA）、`multi-block`（95 KB，**跨块且回溯跨块**）。

再往上还有一层：同一套解码器解过 `Chess.app` 的 1024×1024 图标
（3 个 LZFSE 块、**2,086,192 字节**），并与 Apple 开源参考实现
（[lzfse](https://github.com/lzfse/lzfse) 编成的 CLI）的输出比对 ——
**IDENTICAL**。那个样本 2 MB，不适合入库。

#### 最贵的一个 bug：回溯可以跨块

我最初按「一个块一个输出缓冲区」写，块内偏移自己算自己的。小夹具全绿，
一到真实图标就崩在第二块：

```
L=4 D=12339 at dst_off=1805271     ← 第一块才 1.0 MB 左右
```

`D=12339` 指向的是**上一块**已经解出来的字节。LZFSE 的匹配距离是整个
输出流的距离，不是块内距离。改成一块共享输出缓冲区、`dst` 用全流偏移之后
才逐字节对上。

这个 bug 的形状值得记住：**「小样本全绿」在这里不是覆盖率不足，是结构不对**。
夹具里 `multi-block.bin` 原本就是这样才被加进去的 —— 单块样本永远碰不到它。

#### 两个格式事实（都写进了 `test/fixtures/lzfse/README.md`）

1. **`packed_fields` 在偏移 8**（`u32 magic` + `u32 n_raw_bytes` 之后，结构体是
   packed）。按 12 算会读出 `header_size=1095911234` 这种值 —— 用
   「`header_size + litpay + lmdpay` 必须等于块长」这条约束反解才确认。
2. **`bvx$` 只有 4 字节**，没有附加的长度字段。把它当 8 字节会让所有末尾块的
   对齐判断错位。

顺带一个和 `Assets.car` 无关的结论：**FSE 频率表是在流里的**，不是外挂的
参数。这一点没有文档可查，是从 `litpay` 的消耗量对齐反推出来的。

#### 通道顺序不是猜的，是 CoreGraphics 说的

`ARGB`（4CC 反转后）对应内存字节 `B,G,R,A`。让 CoreGraphics 自己解释：
用 `kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little` 从 4 个已知
字节 `[10,20,30,255]` 构造 `CGImage`，再画进标准 RGBA 上下文，读回
`[30,20,10,255]` —— 所以 **byte0 = B**。`GA8 ` 同理：`[77,200]` 读回
`[77,77,77,200]`。

这种值**不能靠文档或直觉**：ARGB 这个名字按字面理解会得到相反的顺序，
而错了也「能出图」—— 只是红蓝互换，肉眼在多数图标上看不出来。

#### 说清楚的边界

**不是每个 rendition 的 payload 都是裸像素。** 实测 5 个系统 `Assets.car`：
部分块解码后长度正好等于 `W×H×bpp`（FindMy 里大量这种，`366×104 ARGB`
→ 152,256 字节），这类能直接出图；但**大图标常常不是** —— Chess 的
1024×1024 解出 2,086,192 字节，而 `1024×1024×4 = 4,194,304`。
那些 payload 里还有一层没搞清的封装（90% 是零、有约 1026 字节的周期结构）。

所以提取器对尺寸不匹配的渲染项**明确报 `pixel_size_mismatch`**，并写出
「解出多少 / 期望多少」。不猜、不截断、不拉伸。实测可提取比例：
`installer-progress.car` 2/3、FindMy 11/57。

**两个不支持的块类型是报出来的，不是猜出来的。** `bvx1`（v1 头）没有工具
产出、没有样本；`bvxn`（LZVN）在实测的 951 张真实光栅图里出现 **0** 次。
两者都抛带稳定 code 的异常（`block.unsupported_v1` / `block.unsupported_lzvn`），
而不是写一个没验证过的实现 —— **「能跑但结果是错的」比「明确说不支持」
糟糕得多**。

#### 顺带加的健壮性

解码器面对的是**不可信输入**（IPA 里的字节），所以测试里专门有这几条：

- 输出上限拦住伪造的 `n_raw_bytes`（声明的原始长度不可信）；
- 篡改频率表 → `block.bad_freq`，不做猜测；
- 截断的压缩块 → **抛异常**，而不是返回半截数据；
- 未知魔数 → `block.bad_magic`，并把魔数本身带出来。

### 第七档：`RENDITIONS` 键索引 —— 拿到资产名，并把大图标取出来

测试 1,525 → **1,529**（`ipa_parser` 98 → **112**，+14）。

#### 做了什么

两件事，第二件是意外收获：

1. **资产名**：解析 `RENDITIONS` 的键索引，把每张 rendition 归到资产名
   （`AppIcon` / `BrandMark`）下。这是 `CFBundleIconName` 真正指向的东西 ——
   之前的实现只能看 rendition 名里有没有 `appicon` 字样。
2. **图标真的能显示了**：`IpaIconResolver` 现在按声明的资产名**精确取图**，
   LZFSE 解码 + 编 PNG，作为可预览候选交给界面。

#### 格式（没有文档，三条都是反解出来的）

```
KEYFORMAT 块（"tmfk"，其余字段小端）
  0x08 u32 属性个数 N；0x0C 起 N × u32 属性编号

键签名 = 2 × N 字节：N 个 u16 小端字段，顺序与 KEYFORMAT 一致。
  每个 ISTC 块在**块表里**的前一块就是它自己的键，长度恰为 2N。
  字段 17（kCRThemeIdentifierName）= 资产名哈希。

名字表：一块字符串 + 紧随其后的稀疏键
  稀疏键 = u32 0 + u16 个数 M + M × (u16 属性编号, u16 值)，总长恰 6+4M
```

反解线索：稀疏键的 `03 00` 按大端是 768（不可能）、按小端是 3（字段数）；
`2N` 由「83 个容器里每一个 ISTC 的前一块长度都恰好是 2N」确认；
「前一块是它的键」是**块表顺序**，不是文件偏移顺序。

#### 验证：与 `assetutil` 逐条对齐，不是自证

- `assetutil --info` 的 `Key Format` 名字数组与解析出的编号数组**逐位对应**
  （8 / 11 / 12 / 14 / 17 项都见过），`NameIdentifier` 与键里 17 号字段
  **逐条相等**。
- **83 个容器、25,986 个 ISTC**：除 `PackedImage`（图集成员）
  外**零差异**（按 `(SizeOnDisk, 资产名)` 多重集比对）。
  7,500 个名字、16 位哈希**零碰撞**，但仍按可能碰撞处理（撞了报「不确定」）。
- 夹具 `test/fixtures/car/appicon-ios.car`（28 KB）是 **`actool` 真实编译**
  的 iOS 目录：3 个资产 + 1 个图集 + 2 个 `MultiSized` 空壳。README 里存了
  完整生成命令与 `assetutil` 原始输出。

#### 意外收获：上一轮所有 `pixel_size_mismatch` 的真因

上一轮把「Chess 的 1024 图标解出 2,086,192、期望 4,194,304」归因为
「payload 里还有一层没搞清的封装（90% 零 + 约 1026 字节周期）」。**那是错的。**

真实结构是：**一个 `ISTC` 块里的像素是若干段串接的 LZFSE 流**：

```
[KCBC 头 20B][bvx2 … bvx$][KCBC 头][bvx2 … bvx$]…[bvx2 … bvx$]
```

`actool` 的 1024 图标是 **4 个流**：3 × 1,396,736 + 4,096 = 4,194,304。
只解第一个流，自然「少了 2/3」。`KCBC` 头不是必需的（Chess 的块里流之间
只有 4 字节记录），所以实现是「解完一段，在有界窗口内找下一个流头」，
最终由**总字节数必须精确等于 W×H×bpp** 把关。

修后实测（84 个容器、3,244 张可尝试的图）：**1,428 张出图（44.0%）**，
其中 **191 张是多流的** —— 这 191 张在修复前必定失败。
真实样本：`bi-ying-0828.ipa` 的 1024 图标（507 KB）解出 4 MiB、
编成 458 KB PNG、**95 ms**；`actool` 夹具的 1024 图标 29 ms。

#### 又一处「输出看着正常但结论是错的」

`installer-progress.car` 里 739 字节的 `LowBatteryFlashing.png` 一直被当作
「空壳」的例子写进文档与测试。它其实有 `dmp2` 描述符
（`dmp2 04 01 0a 04 1e 00 48 00`，30×72 与 `ISTC` 声明一致）——
是 deepmap2 压过的真图。新增 `CarCompression.deepmap2`：**有像素，
但我们不解这个码**。改后该容器四张图全部「有像素」（3 张 LZFSE + 1 张
deepmap2），`placeholderOnly` 为空。

#### 边界（都报出来，不猜）

| 失败码 | 84 个容器的实测数量 |
|---|---:|
| `pixel_size_mismatch` | 1,335 |
| `unsupported_deepmap2` | 284 |
| `lzfse_block.unsupported_lzvn` | 109（**后续** chunk 是 LZVN；作为首流实测 0 次） |
| `unsupported_format` | 88 |

`pixel_size_mismatch` 已确认两种成因：payload 是 1 字节/像素（LaunchImage 类），
或解出的比预期**多**（Chess 某个 1024 图层 7,341,104、BrandMark 80×80 44,880）。
不截断、不拉伸、不猜 bpp —— 一张错的图标比「取不到」糟糕得多。

#### 界面侧的变化

`CFBundleIconName` 的「取不到」文案从「需要一个 RENDITIONS 解析器」变成了
可核对的事实：要么给出解码后的尺寸与耗时，要么列出容器里**实际有哪些资产**
并说明「没有叫这个名字的」。取不到时**绝不**改用别的资产 —— 规范的 5.3 一条
都没松。

## 2.4.13 — 2026-10-18

> 阶段 A **收尾** + 阶段 B（六项）。两件事最重要：一是推翻了自己上一轮的结论
> ——「有界解压」当时并不是真的有界；二是给四条此前零测试的路径补上了安全网。
> 取证见 `docs/plans/V2.4.12_PHASE_A_PROGRESS.md` §10–§14。

### 安全修复

- **有界解压现在才是真的有界（推翻 2.4.12 的结论）。**
  `ZipFile.decompress(OutputStream)` 底下是
  `ChunkedConversionSink.withCallback`，它**先把解压结果全部攒起来**再交给
  回调 —— 2.4.12 只挡住了「我们保留多少」，没挡住「解压器分配多少」。
  实测（全零条目、CD 谎报 1024 字节）：256 MiB 条目 / 1 MiB 上限时
  **ΔRSS 72 MiB、耗时 29 ms**，内存随条目大小涨。改为自己按 1 KiB 喂输入给
  `ZLibCodec(raw: true)` + 自定义 `Sink`，同一场景 **ΔRSS 16 KiB、0 ms**。
  新增 `bounded_read_memory_test.dart` 按 ΔRSS 断言（退回旧实现即红）。
- **`readEntryPrefix` 曾返回 0 字节。** zlib 会把一大块输出一次交过来，
  旧实现「超限就整块丢掉」，于是「只读 4 KiB」得到空内容。下游
  `HardeningScanner._readHeader` 因此对**每一个 DEX** 都记「entry could not be
  read」—— 真实样本上凭空多出 55 条加固线索，而文档里那个「29 ms」其实是
  「什么都没读」换来的。现在「填满到 cap 再抛」：抖音 55 DEX 加固扫描 41 ms、
  4 条线索、**0 误报**。
- **`writeStream` 整条物化**：STORE 条目走 `writeBytes(stream.toUint8List())`，
  一次性复制整条，上限完全没拦住。改 64 KiB 分块。
- **新增完整性闸**：产出**少于**声明值 = 截断 → 按 `corrupt` 拒绝。把中央目录的
  `compressedSize` 改小一半时 `archive` 不报错、只是提前结束 —— 「半截内容」
  与「完整内容」在调用方看来一模一样。只判「少」不判「多」（加固包会故意报小）。
- **IPA 侧还有 7 处无界读取**（2.4.12 的文档写「已经没有了」，是错的）：
  Info.plist、`PrivacyInfo.xcprivacy`、图标、证书链、描述文件、`_readEntry`、
  解包落盘，全部改 `readEntryBounded`；`IpaAnalysisReader.analyze` 现在持有一个
  会话账本（此前 `CodeResources` 每次调用自建账本，等于每条目重新领一份配额）。
- **超限被拒时说清原因**：`ApkReader.budgetFailure` / `ZipHelper.lastBudgetViolation`
  → `DetailRenderer.openFailure(..., detail:)`，摘要之外多一行
  「条目 / 阶段 / 观察字节数 / 上限」。文案改成「未解析任何内容，签名状态未知
  —— 这既不是签名验证失败，也不代表已确认恶意」（6 个语言包）。
- **ToolDownloader**：临时目录每次下载都泄漏（建了从不删）；下载把整个归档攒进
  内存再落盘；`Content-Length` 不符不报错（留半截归档）；302 到别的主机静默跟随。
  全部修掉，并补 15 条离线测试（校验和挡住解包 / 404 / 截断 / 协议白名单）。
- **XapkInstaller**：manifest 重复列同一个分包 → 同一路径传给
  `adb install-multiple` 两次 → adb 报错。改为按出现顺序去重，并补 8 条
  调用路径测试（越界条目、取消、同名碰撞、符号链接条目）。
- **JSON 报告曾把三态压成一个 `null`**：`absent` / `failed` / `wrongType` /
  `notRequested` 在 JSON 里全是 `null`，下游无从区分。新增 `fieldStatus`
  （逐字段 status / source / diagnostic），`reportSchemaVersion` 4 → 5。
- **Markdown 报告里权限读失败时整段消失**：`wrongType` 时一个字都没有，
  读者只会以为「这个应用没声明任何权限」。现在没读到就输出一行状态。

### 新增检测

- **`IOS-USAGE-WITHOUT-API`**（info / unknown）：Info.plist 声明了
  `NSPhotoLibrary*` / `NSCamera*` 用途说明，但扫描范围内找不到对应 API 线索 ——
  抓**过度声明**。三条边界：系统选择器（`PHPickerViewController` /
  `PhotosPicker`）算「有实现」；没读到可执行文件不判；**扫描被 16 MiB 预算截断
  不判**（实测 `sun_signed.ipa` 主可执行文件 45 MB，`AVCapture` 在 16 MB 之后，
  不排除截断就会误报）。
- **`SecurityFinding.dataTransform`**：数据流三段（来源 / 中间处理 / 去向）里的
  中间跳，机器可读定位（方法完整签名）。`ANDROID-RULE-C` 在「同一方法体」分支
  填那个方法，整包层面留 `null`（不编造）。报告与发现项卡片都显示三段，
  标签走 i18n（此前是硬编码的 `Source:` / `Sink:`）。

### 质量

- 测试 **1,241 → 1,303**（阶段 A 收尾 +62）。四条此前零测试的路径补上安全网：
  `tool_downloader`、`xapk_installer` 的调用路径、`security_finding_card`、
  `bounded_read` 的内存维度。
- 真实样本回归：抖音 343 MB（55/55 DEX，端到端 **13.5 s**）、
  `49af6cnn-1018.apk`（零填充清单仍可解析）、`sun_signed.ipa`（静态解析
  **222.6 ms**，27 个嵌套 bundle）。
- **仍未验证**：界面目视（本机构建不了任何平台产物）、真实 XAPK 样本、
  联网下载、Windows / Linux。

## 2.4.12 — 2026-10-18

> **⚠️ 本条的「没有任何 `file.content` 调用点」与「峰值内存受预算约束」两句
> 在 2.4.13 被推翻**：IPA 侧当时仍有 7 处无界读取，且解压器会把整条条目
> 物化。详见 2.4.13。

> 阶段 A：**实际解压量限制**。落实 V2.4.11 记为遗留的那一半 —— 峰值内存不再
> 由攻击者决定。取证见 `docs/plans/V2.4.12_PHASE_A_PROGRESS.md`。

### 安全修复

- **解压改成真正的逐块有界。** V2.4.11 只做到「解压完再比长度」，峰值内存
  仍不受限；当时记录的「现有归档库不支持有界流式输出」**是错的** —— 我读的是
  pub.dev 的 `archive 3.6.1`，而本项目实际用的是 git 依赖（`ref cb3a07c`），
  后者有 `ZipFile.decompress(OutputStream)`，是流式的。
  现在给它喂一个**带上限的 `OutputStream`**，超限时在写那一块时抛异常，
  zlib 就地停下。实测（5 MiB 条目、上限 1 MiB）：在 `observed = 1,067,098`
  处抛出，**已产出 1,001,562 字节就中止**，从未物化 5 MiB。
- **三道闸**：声明解压大小 → 声明压缩大小 → **真实产出**。
  单条目 256 MiB / 压缩 512 MiB；一次流程真实产出 1 GiB / 压缩 2 GiB。
- **共享预算**：`BoundedReadLedger` 由一次 `open` 持有一个，嵌套归档共用 ——
  子归档拿不到完整独立配额。
- **消灭了四处无上限的 `file.content`**：`ApkReader.readFile` 之外的
  manifest / arsc、`HardeningScanner._readHeader`（为了看 8 字节把整条 DEX
  解压一遍，343 MB 包实测 30ms → 896ms）、iOS 的 `CodeResources`、
  以及 `ZipGuard.extractToDirectory`（工具下载解包落盘）。
  现在 `lib/` 与两个解析器里**没有任何 `file.content` 调用点**。
- **诊断可追溯**：`BoundedReadFailure{entry, stage, observedBytes, limitBytes}`，
  日志形如 `classes.dex: stopped at inflate after 1067098 bytes (limit 1048576)`。

### 性能

343 MB 样本：读取全部 DEX 916 → 1239 ms（逐块流式的代价）；加固线索扫描
30 → **29 ms**（`_readHeader` 改前缀读取后从 896 ms 回落）；
端到端 13.49 → **13.71 s（+1.6%）**。

### 兼容性

- `49af6cnn-1018.apk`（72.3 MiB 零填充清单）仍能完整读出并解析 ——
  V2.4.10 的「不再仅因高压缩比拒绝」保住了。
- 抖音 55/55 DEX（437.2 MiB）、`sun_signed.ipa` 220/220 条目（81.3 MiB）
  全部正常，无一条被误拒。

## 2.4.11 — 2026-10-18

> 落实 2026-10-18 审计报告里的 **P1-1**（解压预算可被绕过）与 **P1-2**（加固
> 证据半中半英）。取证见 `docs/audit/APPINFOTOOL_COMPLETENESS_AUDIT_2026-10-18.md`
> 与 `docs/plans/V2.4.11_PROGRESS.md`。

### 安全修复（P1-1）

- **解压预算从「只看声明值」改成两道闸。** 审计实测：把 100 MiB 条目的中央
  目录 `uncompressedSize` 改成 1024，`ZipBudget.check` 会放行，而
  `readFile` 仍产出 104,857,600 字节（RSS +201 MiB）—— 因为
  `archive` 包在 IO 平台走 native zlib，**忽略声明尺寸**。
  新增 `ZipBudget.readEntry()`：
  1. **声明值超限 → 不解压就拒绝**；
  2. **实际产出超限 → 丢弃并拒绝**，日志里留下「声明 X 实际 Y」。
  接到三个读取点：`ApkReader.readFile`、`ZipHelper.readFileContent`、
  `ZipHelper.extractFile`（后者防的是「一个几 MB 的包写满磁盘」）。
  **已知局限（如实记录）**：峰值内存仍不受限 —— `archive` 的公开 API 不暴露
  条目的压缩字节，无法在解压过程中按字节中止。真正的解法是换库或自己解析
  local file header 接一个有上限的 `Sink`，见进度文档 §2.3。

### 修复（P1-2）

- **加固证据全部结构化，「覆盖不足」面板不再半中半英。** 此前是
  「容器/解析异常可能影响覆盖完整性：21 elements declare a non-standard
  attributeStart…」—— 中文前缀 + 英文正文。
  现在 `HardeningObservation` 带 `note`（稳定 code + 参数），
  `AxmlLayoutAnomalies.notes()` 产出 4 条，`containerAnomalies` 参数改成
  `List<AnalysisNote>`，**13 条加固/清单证据**各自有本地化模板（6 语言包）。
  实测 `49af6cnn-1018.apk`：诱饵条目、多 DEX 分片、清单布局异常全部显示中文。

### 测试

- `test/archive_open_test.dart`：新增「中央目录撒谎的条目会被拒绝」
  （构造 CD 声明 1024 / 实际 1 MiB 的样本）、「声明超限直接拒绝」、「正常条目
  不受影响」，共 20 条。
- `test/limitation_notes_test.dart`：新增「加固/清单结构异常的证据也是中文」
  与「缺参数时整条回退英文」。
- `test/security_integration_test.dart`：守卫清单补入 13 个新 code
  （四个语言包都能取到、不留占位符）。

## 2.4.10 — 2026-10-18

> 用户报「这个应用怎么解析不了」—— 提示「已拒绝打开：归档超出安全解压上限」。
> 查下来是**安全预算误伤了一类真实的加固包**。取证见
> `docs/plans/V2.4.10_PROGRESS.md`。

### 修复

- **不再按「压缩比」拒绝归档，只看绝对大小。** 样本 `49af6cnn-1018.apk`
  （`澳門新葡京` 的变种）把 `AndroidManifest.xml` 的字符串池**零填充到
  72.3 MiB**（真实 XML 只有末尾 35 KB），压缩比 205:1，于是整个包打不开 ——
  而这类包恰恰是本工具要分析的对象。

  **为什么不能只调阈值**：试过「把 100:1 提到 1000:1，只拒绝纯零填充」，
  行不通 —— 实测 `archive` 包的 deflate 对 17 MiB 纯零只给 **229:1**，
  与被填充的清单（205:1）**几乎一样**。压缩比区分不了「零填充的合法文件」
  和「零填充的炸弹」。

  真正决定风险的是**解压后占多少内存**，也就是两条绝对上限（单条目
  **256 MiB**、总量 **1 GiB**），它们一条都没动。修完后这个包 226ms 解析完成
  （`rich.x4xcirrv.f0dz01x3s5` / `澳門新葡京`，54 权限 / 86 组件 / 100 个诱饵条目）。
- **拒绝时能说清是哪一条了**。原来只有一句「归档超出安全解压上限」，
  排查时毫无帮助。`ZipBudget.check` 现在返回结构化的
  `ZipBudgetViolation`（条目名 + 原因），异常消息里带上它。

## 2.4.9 — 2026-10-17

> 用户问「分析里的覆盖不足是什么原因导致的、能解决吗」，随后又指出 **IPA 侧
> 也有同样的问题**。逐条查下来：**分析结论没错，是这个面板的文案有缺陷**。
> 诊断与实测见 `docs/plans/V2.4.9_PROGRESS.md`。

### 修复

- **「DEX 扫描预算」那条说不出数字。** 它只拿到文件名，于是中文界面上是
  「classes.dex —— 该文件只扫描了部分内容」—— 扫了多少、一共多大、覆盖几成
  全都没有。`DexScanResult.skippedForBudget` 从一句拼好的英文改成结构化记录
  （`DexBudgetSkip`：名字 / 已扫字节 / 总字节 / 覆盖率），界面现在显示
  「只扫描了前 8388608 字节（文件共 17534446 字节，约 47%）」。
  覆盖率**向下取整且部分扫描绝不给 100%** —— 一个只比上限大 22 字节的 DEX
  用 `round()` 会算出 100%，而那恰恰是「未覆盖」的那一条。
- **中文句子里夹着成段的英文**（IPA 侧最明显）：`4 个可执行文件未参与扫描
  （Payload/…/App（bytes not retained (nested budget of 32 MiB reached)））`
  —— 括号里的原因是引擎侧的 `bytesFailure` 英文句子。未扫描清单现在**只列
  路径**；原因在详情页的嵌套清单与解析诊断里仍然能看到。
- **文案里带 `**`（Markdown 语法）**，而界面是纯 `Text` —— 星号原样显示。
  `security.limitation_notes` 里 **8 条（en/zh）/ 10 条（ja/ko）** 全部去掉，
  改用措辞表达强调。
- **一条说明里漏出了代码标识符**：`运行时证据（includesRuntimeEvidence）恒为
  false` 改成「因此不存在任何运行时证据」。**Android 与 iOS 两侧都有**，
  六个语言包全改。

### 说明

- 面板里另有 **5 条容器/解析异常**（诱饵条目、非标准 `attributeStart` /
  `attributeSize` / namespace chunk / 未知 chunk）—— 那是**加固包的特征**，
  正文是加固扫描器产出的英文证据。要本地化需要把加固证据也改成结构化数据
  （`code` + 参数），属下一轮的工作，本轮**未做**（见进度文档 §3）。
- **DEX 扫描预算没有上调**：实测加固包提到 32 MiB 只多 0 条线索，抖音从
  48→256 MiB 多 8 秒只多 3 条。更优方向是改扫 `string_ids` 字符串池，下一轮。

## 2.4.8 — 2026-10-17

> 用户提的五项界面问题 + 版本跟进。取证见 `docs/plans/V2.4.8_PROGRESS.md`。

### 修复

- **版本对比左侧槽位没有图标。** 根因是**生命周期**：`CurrentApkInfo.update/
  reset` 在换文件时会 `dispose()` 上一个 `ApkInfo`，而 `ApkInfo.dispose()`
  会把图标候选的 `ui.Image` 一起释放。`parsedFileCacheProvider` 里存的正是
  同一个实例 —— 于是**先解析的那个包**（左侧）图标消失，只有当前那个（右侧）
  还活着。新增 `parsedFileIconsProvider`：解析完成时给图标留一份
  `ui.Image.clone()` 副本（共享像素、各自计数，不受原对象 dispose 影响）。
  iOS 侧不受影响（图标是从 `IpaAnalysis` 的字节现解的），所以只有 Android
  需要这一份。`AppShell` 启动时必须读它一次 —— 否则进差异页才第一次建，
  那时两个包都已经被 dispose 过了。
- **分析页四个 Tab 的标题被逐字折断**（`uiMod` / `e 设备` / `类型`）。
  标题列宽度用的是设置里的 `title_width`，而滑块下限只有 40 —— 那个宽度下
  一个 16px 的中文标签连一个字都放不下。现在：宽度夹到 **96–200**（旧配置
  存 40 也按 96 排），标题**绝不换行**（`softWrap: false` + 省略号），完整
  标题交给 tooltip。

### 调整

- **详情卡片的标题统一成「淡色小字」**（`bodySmall` + hint 色），此前是
  16px 常规字重、与 14px 的值同色，扫一眼分不出哪个是标签。设置页的
  「标题宽度」预览改用**同一个样式函数**（此前它写死 16px，只是恰好与卡片
  一致）。
- **概览页「详细信息」不再重复 Hero 已经显示过的三项。** 文件名、版本、
  构建号在 Hero 上都有（应用名 / 包名 / `v1.4.1 (14102)` / 完整路径），
  网格再列一遍纯属占位。空出来的三格换成「Hero 上没有、但一眼想知道」的：
  **ABI、权限数、组件数**（iOS 侧是设备类型、可执行文件、嵌套包数）。
  计数类字段读不到时**不渲染**，不会显示成 0。
- **应用图标的尺寸与圆角全应用统一**（新增 `PackageIconMetrics`）。此前三处
  各写各的：概览页 92/76、分析页 Hero 卡片 **72 + 固定 16px 圆角**、版本对比
  48。现在一处定义、三处取用，圆角一律按边长 22.4% 算 —— 固定像素的圆角在
  改尺寸时不会跟着变。分析页的图标因此从 72 长到 **92**，与概览页一致。

## 2.4.7 — 2026-10-17

> 用户提的五项：侧边栏应用名与版本号的位置、详细信息项数、**大 APK 解析慢**、
> ICP 备案号、版本跟进。实测数字与取证见 `docs/plans/V2.4.7_PROGRESS.md`。

### 优化

- **大 APK 的解析速度：端到端 64.1 秒 → 13.5 秒（4.75×）。**
  实测样本 `抖音-v40.7.0.apk`（343 MB、55 个 DEX、4.7 万条目）。
  基线拆分后定位到**唯一的热点**：安全审计里的「方法引用与调用点遍历」一项
  就占 60.6 秒（92%），而它慢在**每个调用点都重新跑一遍 23 个标记的子串匹配**
  —— 287 万条 `method_ids` + **1586 万个调用点**，共 1870 万次匹配。

  两处改动（都**不改变任何结论**）：
  1. `invoke-*` 指令的操作数就是 `method_idx`，而它指向的正是刚看过的同一条
     `method_ids` 条目 —— 于是调用点**不必重新拼字符串、重新匹配**，按索引
     查表即可。60.6 → 12.9 秒。
  2. `matchCodeMarkers` 里 23 个标记中有 16 个的字面量既不含 `/` 也不含 `.`，
     而归一化只把 `/` 换成 `.` —— 对它们**比一次就够**，每个文本少跑 16 次
     子串搜索。12.9 → 10.5 秒。

### 新增

- **ICP 备案号（`京ICP备16016397号-49A` 这种）会显示在分析页「概览 → 应用信息」
  里，没有的就不显示。** `AndroidManifest.xml` 里**没有**标准字段放它，各家
  写在各处，因此从 `resources.arsc` 的**字符串池**里扫（那是唯一不依赖各家
  实现的位置）。实测：抖音的池里有一条 `京ICP备16016397号-49A`，飞牛 /
  澳門上葡京 / 181 / 214 都没有 —— 后者界面上不出现这一行，而不是显示空值。
  **已知局限**：只覆盖字符串池，写在 DEX 里或运行时下发的看不到；也不做
  「备案号是否真实/过期」的合规判定。

### 调整

- **侧边栏：应用名回到 logo 右边，版本号回到左下角底栏。** V2.4.6 把两者都
  去掉了（理由：窗口标题栏上已经有应用名），用户要求放回来 —— 但副标题
  「应用包分析工具」仍然不显示（纯噪音，还占一行高度）。
- **概览页「详细信息」只显示 6 项**（此前最多 8 项）。选的是打开一个包时最常
  被复制走的那几项：文件名 / 版本 / 构建号 / 最低系统 / SHA-256，以及各自平台
  最有用的第 6 项（Android 是 targetSdk、iOS 是可执行文件名）。**去掉的是
  SHA-1 与 MD5** —— SHA-256 是现在的通用口径，另两个在分析页与导出的报告里
  仍然都在。少两项还让网格从 3 行变 2 行，把高度还给底部的「最近文件」。

## 2.4.6 — 2026-10-17

> 用户提的五项界面问题 + 版本跟进。取证与实测数字见
> `docs/plans/V2.4.6_PROGRESS.md`。

### 调整

- **侧边栏收窄：240 → 200px。** 导航项只有四个、标签最长两个字，240px 里
  近一半是空白，而右侧内容区为此少 40px。宽度抽成 `kSidebarWidth` 常量，
  免得「240」散落在注释与测试的换算里。
- **导航项「版本对比」→「对比」。** 窄栏里四字标题会把图标挤到贴边。页面
  正文的标题仍是「版本对比」—— 那里有足够的空间，也仍是它的正式名字。
- **侧边栏不再显示应用名与版本号**，窗口标题栏也不再带版本号
  （`AppInfoTool v2.4.5` → `AppInfoTool`）。同一件事此前在三个地方各说一遍，
  而版本号在设置页仍有一份。标题栏那一行三平台共用（`window_manager`），
  **Windows 一并生效**。
- **分析页「概览」：应用信息排到文件信息之前。** 用户打开一个包，第一眼要找
  的是「这是哪个应用、什么版本」，而不是「它在磁盘上的路径」——后者是排查时
  才需要的。Android 侧顺带补上「文件信息」分组标题（此前只有 iOS 有）。
- **应用信息卡显示 32 / 64 位。** 与概览页 Hero 共用同一份判定
  （`architectureLabelOf`，依据是 Mach-O 镜像的段位数 / 容器里的 ABI 名）。
  三种结果都要能出来：只 64 位、只 32 位、**两者都有**——最后一种是「这个包
  能不能装在老设备上」的答案。取不到时**不显示**，不猜。
- **重命名对话框统一成一份实现。** 概览页的 Hero 与分析页的「文件」行此前
  各写一个长得不一样的 `AlertDialog`（默认名规则、确认按钮、提示文案都不同），
  现在共用 `showRenameFileDialog`，版式与「导出报告」对话框对齐（标题带图标、
  上方一个只读的「当前文件」框、动作用取消 + 实心确认）。默认名逐级退化，
  取不到应用名时退回**原文件名**（此前会拼出 `--.apk`）。
- **版本对比的两侧槽位显示真实应用图标与平台标签。** 两个版本的包名常常长得
  极像（`xxx-1.4.1.apk` / `xxx-1.4.2.apk`），图标是分辨左右最快的一眼。

### 修复

- **侧边栏的紧凑模式（窗口 < 800px 时收成 64px）此前是死代码。** 判据用的是
  `LayoutBuilder` 的约束，而侧边栏是 `Row` 的非弹性子项、`Row` 在主轴不设
  上限 —— `constraints.maxWidth` 恒为 `Infinity`，`< 800` 永远为假（实测
  探针看到的是 `0.0<=w<=Infinity`）。改用 `MediaQuery` 的窗口宽度。
  当前最小窗口是 900px，因此**用户看不到差别**；修的是「写了却没生效」。
- **重命名校验改用与「打开文件」同一份判定**（`isSupportedPackagePath`）。
  此前手抄了一份 `.apk/.xapk/.apkm/.apks/.ipa` 清单，于是下载渠道加的
  `.apk.1` 后缀**能打开、却改不回去**。

## 2.4.5 — 2026-10-16

> 用户提的四项：Hero 区显示文件路径并支持重命名、解析速度优化、最近文件显示
> 真实应用图标与平台信息、版本号跟进。本文里的每个数字都是本机实测，
> 取证与复现命令见 `docs/plans/V2.4.5_PROGRESS.md`。
>
> **同时收进上一轮（V2.4.2）未提交的改动**：那轮是测试与国际化补齐，生产行为
> 零改动（只加了可见性注解与语言包），因此没有独立的版本号。它的可见成果是
> **日语 / 韩语从 279 键补到 726 键**（`coverage` / `diff` / `ios_info` /
> `security` 四组 447 键），此前这四组在日韩文下整段回退成英文。详见
> `docs/plans/V2.4.2_PROGRESS.md`。

### 新增

- **概览页 Hero 区直接显示文件路径，并可就地重命名。** 路径挂在「当前文件」
  那一行上（等宽字体、单行省略、悬停看全文），右侧是复制与重命名两个入口。
  重命名走与详情页同一套三级回退（就地改名 → 复制+删除 → 保存对话框）——
  macOS 下前两条会以 `EPERM` 失败，只有保存对话框能拿到目标路径的写权限。
  此前路径只出现在「详细信息」网格里，而网格在矮窗口下会**整块收起**：
  「这个包在磁盘上哪儿、我要改个名」这个最常见的诉求，恰好在最需要它的尺寸下
  看不见。现在它常驻，且**不占额外高度** —— 挂在已有那一行上，不是新开一行。
- **最近文件显示真实应用图标与平台信息。** 每个条目左边是 32px 的真实应用
  图标（解析成功那一刻顺手编码成 96px PNG 缓存下来，不是列表按需去开归档），
  右边是平台**文字**标签（Android / iOS）+ 体积 + 时间。此前只有一个 16px 的
  通用平台图标，平台靠认图标猜 —— 现在每个包图标各不相同，不写文字就分不出来。
  缓存缺失、被外部删除、或平台不支持缓存目录时，一律退回通用图标，不影响记录。

### 优化

- **解析速度：三种哈希改为三个 isolate 并行。** MD5 / SHA-1 / SHA-256 之间没有
  任何依赖，串行只是实现上的顺手。实测（`sun_signed.ipa`，40.5 MB，10 核）：
  单跑 192.9 / 221.5 / 292.2 ms，**串行 622.5 ms → 并行 272.8 ms（2.28×）**。
  代价是文件被读三遍，但三遍都命中页缓存，瓶颈本来是摘要的 CPU 计算而不是 IO。
- **图标候选收集的存在性判断从 `List.contains` 换成 `Set`。** 候选路径有几十个、
  条目列表动辄几千条，逐个比对是纯浪费。
- **`scanHardeningSignals()` 在成功路径上只算一次**（此前算两遍，每次都要遍历
  整张条目表）。

### 说明

- 上面三项优化只动了「重复计算」与「串行改并行」，**没有改任何解析语义**：
  哈希值用系统工具（`md5` / `shasum`）独立核对，小文件与大文件（跨分块、
  非分块整数倍）各一组。

## 2.4.1 — 2026-10-16

> 2.4.0 发布后用户报告的 3 项问题：导出报告全部失败、四个页面头部版式不一、
> 版本号跟进。根因与取证见 `docs/plans/V2.4.0_PROGRESS.md` §20。

### 修复

- **导出报告全部失败（`ENTITLEMENT_REQUIRED_WRITE`）。** 概览页与版本对比页的
  「导出报告」点下去只弹一句 `PlatformException(ENTITLEMENT_REQUIRED_WRITE, ...)`，
  **保存面板根本不出现**。根因不在 Dart 侧：`file_picker`(>=10) 的 macOS 端在弹
  面板**之前**就用 `SecTaskCopyValueForEntitlement` 检查
  `com.apple.security.files.user-selected.read-write`，值为 true 才继续。本应用
  刻意不开沙箱（重命名要在用户选中的文件旁边写文件，沙箱只授予那一个文件、不含
  它所在的目录），于是这个键从来没声明过 —— 而 user-selected 这一族授权在
  **非沙箱进程里是惰性的**：声明了不生效，不声明反而会被插件判成「没有权限」。
  两个 entitlements 文件补上该键（**不引入** `app-sandbox`，沙箱的开关只有它
  一个）。同一处检查也在 `pickFiles` 上，「打开文件」按钮本来也受影响。
  `test/macos_entitlements_test.dart` 解析 plist 钉住这两个键的取值，防止下次
  有人「顺手清理」掉它们而界面毫无征兆。
- **「用户取消保存」被报成「导出失败」。** 两个导出对话框各自把「面板返回
  null」与「写盘抛异常」混成一类处理，调用方只能靠 `null` / `true` / 异常对象
  三态去猜。弹面板 + 写盘收成一份 `ReportExporter`，结果做成**三态类型**
  （saved / cancelled / failed），取消不再报错；entitlement 类失败翻译成一句
  可操作的中文，而不是复述错误码。两个对话框原先各写一遍的实现随之删掉。

### 调整

- **四个页面共用同一个 `PageHeader`。** 此前四种做法：概览页没有页头（标题只在
  Hero 里显示当前包名）、分析页是 `AppBar` 里的标题 + 四个图标动作、版本对比页
  是页面内联的一个 `Row`、设置页是 `AppBar` 里一个孤立的标题。现在统一成
  **左边标题 + 副标题、右边操作**（就是版本对比页原来的做法），四页只差标题
  文字。分析页与设置页的 `AppBar` 一并去掉 —— 窗口拖动靠的是系统标题栏，
  Flutter 的 `AppBar` 并不提供 macOS 的拖动区，另两页本来就没有它。
- **概览页的三个动作（打开文件 / 查看详情 / 导出报告）移到页头右上角**，与版本
  对比页的「导出对比报告」同一个位置。原先它们竖排在 Hero 右侧，那一列比左侧
  文字列还高，Hero 因此多占约 56px。宽窗口用带文字的紧凑按钮，窄窗口只留图标
  （带 tooltip）—— 三个带文字的按钮在 660px 内容区里会把标题列挤到几十像素、
  标题一个字一行地竖排下去。
- **`PageHeader` 的标题与副标题各占一行**（窄窗口省略号截断）。副标题折行会把
  页头从 58px 撑到 78–98px，而概览页是固定一屏布局，多出来的每一像素都要从
  底部「最近文件」里扣。
- **概览页窄窗口的纵向间距收紧**（页头下 12→8、Hero 与统计之间 14→10、Hero
  内边距 18→16）：补上 58px 页头之后，最小窗口（内容区 660×600）正好差十几像素。

### 已知限制

- **本机无法构建 macOS 产物**（`flutter build macos` 在 SPM 解析那一步被沙箱
  拒绝，而且**退出码是 0**，只能靠产物时间戳判断成败）。三个平台的产物由 CI
  在打 tag 后构建 —— 本次的 entitlement 修复因此**只在 CI 产物上可验证**。

## 2.4.0 — 2026-10-16

> V2.4.0 的五个阶段（任务书与逐阶段取证见
> `docs/plans/V2.4.0_PROGRESS.md`）全部完成，另加三项计划外补强。
> 自 v2.3.7 起共 41 次提交；本地根测试 1067 通过 / 14 跳过，
> 四个 package 共 150 条；配真实样本后 1080 通过 / 1 跳过。

### 新增

- **版本对比（阶段 5，全新能力）。** 侧边栏新增「版本对比」页：选两个**已解析**的包，
  逐字段、逐集合地比较，三态呈现（新增 / 删除 / 变更）。字段级覆盖应用身份、
  SDK 区间、签名结论等 20 项，集合级覆盖权限、组件、原生符号、ABI、语言、
  屏幕密度、网络域名 / IP。可导出**独立的** Markdown 与 JSON 对比报告
  （两边的原始状态都带上，`hasChanges` 与「说不清」分开计数）。
  与单文件报告同一条原则：**机器 id 进 JSON，本地化名字进界面与 Markdown**。
- **iOS 签名材料加深（阶段 2）。** 新增解析 `CodeResources`（密封清单条目数）
  与 CMS 证书链的公开字段（条目数、证书、签名值、摘要）。仍**只做静态提取、
  不做验证** —— 与 `codesign` 的结论并列而不是合并，材料存在不等于签名有效。
- **iOS 隐私审计覆盖嵌套 Bundle（阶段 2）。** 用途说明审计原来只看主应用，
  现在嵌套 Bundle 的 `Info.plist` 与 Mach-O 也纳入，按 Bundle 汇总覆盖。
- **报告「技术摘要」段（阶段 4）。** 按八部分结构补齐，与既有各段并列。
- **报告 schema 升到 v4（阶段 4）。** `findings[]` 补 `messageCode` /
  `recommendationCode` / `relationshipCode` / `limitationCode`，`evidence[]` 补
  `detailCode` / `locationCode` —— 只增不改，老消费者忽略新字段即可。
- **证据可读化（阶段 4）。** 证据位置把类型描述符还原成类名、偏移标上单位，
  不再是一串 `Lcom/foo/bar;` 与 `+0x1a2b`。
- **覆盖维度名与全部发现项文案本地化（阶段 1.3 + B11）。** 15 个覆盖维度、
  33/33 条 Android/iOS 发现项、36 条结果级说明、以及关系的关联说明与局限
  全部改成「稳定 code + 英文回退」结构，中英日韩韩五语可用。
  「无法确认」与「低风险」不再混在一起。
- **解析诊断的本地化（第一批，计划外）。** 详情页「解析诊断」与报告里的
  诊断行，已迁移的 14 类改成中文框架 + 机器标识；**其中 4 条 `android.*`
  原先写的是中文**，英文 / 日文 / 韩文报告里会混进中文，现已改为英文回退。

### 修复

- **真实样本测试会因「目录里没有 APK」崩在 null-check 上**（阶段 1）。
  改为五种情况分别给出可理解的跳过原因，配 / 不配样本、只有 APK / 只有 IPA
  都能跑；CI 新增 job 执行包级测试与自包含夹具测试（实测 run#46 通过）。
- **UI 测试靠「把视口拉到 40000 高」让卡片进 widget 树**（阶段 1）——
  详情页是懒构建的 `ListView`，真实样本一长就失效。改为真实滚动定位。
- **覆盖率「受限」与「未覆盖」曾经显示成同一份绿色**（阶段 1）。
  覆盖度改为结构化输出（逐维度状态 + 覆盖量 + 说明），界面、Markdown、JSON
  读同一份数据。
- **Android 详情页一批字段读的是裸字段、用 `?? ""` 兜底**（阶段 1）——
  「文件里没有」与「我们没读到」在界面上长得一模一样，而结论相反。
  剩余 12 个字段改走统一模型，全库详情页 `?? ""` 归零。
- **`SetDiff` 把「我们没读到权限」算成「左边的权限全被删了」**（阶段 5.1
  自查发现并修正）。集合维度现在带 `comparable`，不可比时 `added`/`removed`
  一律为空 —— 与字段级刚立的「说不清不是差异」原本自相矛盾。
- **`tester.drag` 驱动不了满是 `SelectableText` 的详情页**（计划外）。
  触摸拖拽落在可选中的文本上时，文本选择的手势识别器赢得竞技场，列表一动不动；
  真实样本上的表现是「滚到 MD5 卡住，后面的 SHA-1 / SHA-256 永远看不到」。
  测试改为直接驱动 `ScrollPosition`（**产品代码未动**：桌面端 Flutter 默认
  不吃鼠标拖拽，滚轮与触控板走的是另一条通道）。
- **Android 包的签名结论写着「非 macOS」**（计划外）。`notChecked` 被映射到了
  iOS 专属的 codesign 文案，而它实际上只出现在 Android；改为平台中立措辞。
- **字段值的诊断说明是硬编码英文**（计划外）。`FieldValue` 补 `diagnosticCode`
  / `diagnosticArgs`，四处渲染收成一份实现；中文下现在是
  「aapt2 不报 maxSdkVersion」「设置里关闭了哈希计算」。

### 调整

- **Android 安全规则从硬编码 if 链抽成可配置规则表**（阶段 3），与 iOS 对齐；
  现有 finding 数量与等级不回归，有测试逐条驱动。
- **跨方法关联的措辞与置信度有测试钉住**（阶段 3）：「同方法内同现」与
  「跨方法」分开陈述，且**不因此抬高等级**。
- **Android 权限目录收口**（阶段 2）：版本条件说明、`EXPIRED` / `INERT` 状态、
  Android 15/16 的版本条件都在。
- **README / docs 标注过时**（阶段 1.6）：两个文档开头加「已过时」提示，
  不改正文；README 的功能清单补上「版本对比」。

### 已知限制

- **本机无法构建 macOS 产物**（`flutter build macos` 在 SPM 解析那一步被
  沙箱拒绝，而且**退出码是 0**，只能靠产物时间戳判断成败）。三个平台的产物
  由 CI 在打 tag 后构建。
- **`AnalysisDiagnostic` 的诊断文案只迁了第一批**：57 类里还有 43 类是英文
  （其中 12 类的文案来自其他层，要改结构）。未迁移的照旧显示英文原文。
- **差异报告不含发现项差异**：只比较字段与集合。
- **版本对比没有真实的两版本样本**：样本目录里只有一个真实 APK 与一个 IPA，
  端到端只验证到「同一个包与它自己」。

## 2.3.1 — 2026-10-15

> 本轮由用户报告的 6 项问题驱动，实现与取证过程见
> `docs/audit/2026-10-15-overview-drop-and-ui-fixes.md`。

### 修复

- **概览页的「统计」与「最近文件」恒为空。** `RecentFilesManager.load()` 在
  列表为空时返回 `const []`，而 `add()` 紧接着对它做 `removeWhere` 去重 ——
  不可变列表直接抛 `UnsupportedError`。调用点写的是 `unawaited(...)`，
  异常被彻底吞掉，于是**全新安装后第一次分析成功就炸**，界面上表现为
  「统计永远是 0、最近文件永远是空的」，而日志里一行都没有。
  `test/` 下此前完全没有最近文件的测试，这个缺陷因此长期无人发现。
- **一次拖放触发两次解析。** `IndexedStack` 会构建并布局**所有**子页
  （只画选中的那个），概览页与分析页的 `DropTarget` 渲染盒完全重叠；
  而 `desktop_drop` 的通道是全局扇出的，每个 target 再各自判「在不在界内」，
  重叠的盒子全都判定为在界内。拖一个文件到概览页会同时触发概览页的
  `pendingOpenRequest` 和分析页自己的 `openApk`，同一个文件解析两遍。
  改为 `enable: Visibility.of(context)`，让不可见的那一页把 target 关掉。
- **拖拽高亮可能永远擦不掉。** 复位只依赖 `onDragExited`，而这个回调平台
  并不保证送达。改为把 `onDragUpdated` 当心跳，配 5 秒看门狗自愈。
- **孤儿解析任务不取消。** 切换文件时代际变化只 `break` 出事件循环，
  没有取消 worker —— 它会继续把整个解析做完（真样本上是几秒 CPU 与几十 MB
  内存），而结果只会被丢掉。iOS 与 Android 两侧都补上了取消。
- **解析还没出结果时误报平台。** `FileState.platform` 派生自已到位的解析
  结果（这是刻意的），但 Hero 区在平台未知时一律渲染成 `Android`、
  应用名为空时渲染成「未加载文件」。

### 调整

- **概览页 Hero 区可展示的信息从 3 项增至 13 项**，且每一项都有复制入口：
  四个状态卡片（平台 / 大小 / 签名 / 安全）的值可复制，另新增「详细信息」
  网格（文件名 / 文件路径 / 版本 / 构建号 / 最低系统或最低 SDK / 目标 SDK /
  可执行文件 / SHA-256 / SHA-1 / MD5），哈希的 tooltip 会显示完整值。
  网格按可用高度自适应并内部滚动，列数由可用宽度决定 —— 这一页是固定一屏
  布局，Hero 长高了必须有东西让位。
- **复制入口下沉到 `TitleValueLayout`（`copyable` 默认 true）**与新增的
  `CopyIconButton`，两个详情页因此自动一致。顺带清掉三处因此重复的
  复制按钮、与 Tab 名重复的分组标题，以及飘在 Hero 卡片外面的那个复制按钮。
- **设置页与另两页对齐**：顶栏不再用 `inversePrimary`（不再是一片紫色），
  卡片圆角 8 → 12，分组标题改用 `titleSmall` + w600。

### 工程

- 测试从 **873** 增至 **910**（1 项跳过）。新增 `recent_files_test.dart`（9 例）、
  `drop_target_ownership_test.dart`（8 例）、`overview_layout_test.dart`（8 例）。
  新增用例全部做过反向验证：把修复去掉、确认测试真的变红，再恢复。
- `main()` 装上 `FlutterError.onError` 与 `PlatformDispatcher.onError` 的
  日志兜底，只记日志、不改渲染行为 —— 让 `unawaited` 里抛出的异常留下痕迹。
- **macOS 应用在本机跑不起来**（`flutter build` 被系统级 `sandbox-exec`
  拒绝），本轮所有取证靠渲染快照与单元测试完成，真实拖放未能复现。

## 2.3.0 — 2026-10-15

> 本版本的实现依据是 `docs/audit/2026-10-15-v2.3-baseline-audit.md`（先审计、
> 再修改），验收结果见 `docs/audit/2026-10-15-v2.3-release-acceptance.md`。

### 新增：安全检测的三层取证

**DEX 结构级解析**（此前只有字符串扫描）

- **结构**：DEX 头部与六个 id 段的解析 + 边界校验（`file_size` / `header_size`
  / `endian_tag` / 段越界 / adler32 校验和）。结构不可信时「没发现线索」
  这个结论不再成立，会明确说出来。
- **方法引用**：`method_ids` / `type_ids` 的流式遍历。`method_ids` 的条目只可能
  来自字节码 invoke 指令、方法签名或方法句柄，**不会**来自字符串字面量 ——
  因此「代码引用了」与「字符串里提到了」从此分开陈述。
- **调用点**：`class_defs → class_data_item → code_item` 的指令遍历
  （含指令宽度表与 switch / fill-array-data 载荷识别），能回答「在哪个方法的
  哪个偏移调用」，并识别「同一方法内同时出现多个标记」。

**原生库符号**（此前只统计文件名）

- Android：ELF 头 / 节表 / `.dynsym` / `.symtab`，提取导入与导出符号。
- iOS：Mach-O `LC_SYMTAB`（`nlist_64`），fat 二进制的切片偏移按规范处理。
- 按**精确符号名**匹配导入符号（`system` / `popen` / `dlopen` / `ptrace` /
  `socket` …），并给出 p3 级发现项。措辞守住「有能力 ≠ 调用过」。

### 新增：资源表与归档边界

- **`uiMode`（夜间模式）**：`ResTable_config` 的偏移 29，只有 `0x20` 算夜间。
- **资源引用环检测**：显式栈 DFS（不用递归，资源表可有几十万条目）。
  实测 `aapt2` 会接受环状颜色别名，因此环只说明「这些资源解析不了」，
  **不**作为篡改证据。
- **归档边界**：单条目解压上限 256 MiB、跨多层累计预算（`ZipBudgetTracker`）、
  EOCD 条目数与实际条目数一致性。
- **分包一致性校验**：抽检包名与 `versionCode`，截断时如实报告抽检了多少。

### 新增：iOS 规则补齐

- **规则 A / B / E**（此前只有 C / D / F），与 Android 侧同构。
- **`UIBackgroundModes` / `CFBundleURLTypes`** 两个 Info.plist 字段。
- **按 Bundle 的扫描覆盖率**：扫描范围从主可执行文件扩到「主 + 全部嵌套
  可执行文件」，并输出「覆盖了 N 个中的 M 个」，未覆盖的逐条列出。

### 新增：结构化覆盖率与报告

- **`AnalysisCoverage`**：四态（已覆盖 / 部分覆盖 / 未覆盖 / 本次不适用）
  + 覆盖量与上限 + 说明。UI、Markdown、JSON 读**同一份**数据。
  `notApplicable` **不算缺口**（「本次不适用」与「没查到」结论相反）。
- **报告八部分**：新增「网络端点」一节（域名与 IP 分两组）。
- **JSON**：`coverage.entries` 结构化、新增 `network` 一级字段、
  `application.permissions`、`signatureSummary` 的平台详情。
  `reportSchemaVersion` 1 → 3。

### 修复

- **分包安装包（XAPK / APKM / APKS）此前完全不跑安全审计** —— 审计的唯一调用点
  在只被内置引擎使用的 worker 里，因此分包路径的 `securityResult` 恒为 `null`。
- **`ApkReader.structureAnomaly` 在生产路径上永远不会被设置**：EOCD 校验只写在
  `openBytes` 里，而内置引擎走的是流式 `open`。该防护此前等于不存在。
- **Android 侧从不传 `diagnostics`**：详情页的「解析诊断」卡片与导出报告里
  永远是空的。与 iOS 侧此前修过的是同一个缺陷。
- **`renderIcon` 的 XML 分支要求 aapt2 存在**，把「有 arsc 就能渲染」那条能力
  挡死了 —— 没装 aapt2 的机器上 XML 图标静默画不出来且不留说明。
- **Android 详情页字段状态与统一模型不一致**：`unsupported` / `failed` 被渲染成
  `-`，等于把「我们没读到」说成「文件里没有」。
- **JSON 报告的导出范围不生效**（「仅安全检测」只影响建议文件名）。
- `.gitignore` 的 `*.apk` 把测试夹具一起忽略：本地全绿、CI 找不到文件。

### 工程

- 测试从 **602** 增至 **873**（11 项因未设置 `APPINFOTOOL_SAMPLES` 跳过）。
- 新增 `test/acceptance_test.dart`（样本矩阵 / 夹具完整性 / 性能基线）与
  `test/readme_consistency_test.dart`（中英文 README 结构一致性）。
- 测试夹具全部由公开工具真实产出（`aapt2` / `javac`+`d8` / NDK `clang` /
  macOS `clang`），期望值取自 `aapt2 dump` / `dexdump` / `llvm-readelf` /
  `llvm-nm` / `otool` / `nm`。

## 2.2.0 — 2026-10-15

- 概览页改为一屏响应式布局。
- 修复概览页若干「点了没反应」的入口。
- 重写关于页与中英文 README。

## 2.1.0 — 2026-10-15

- Hero 区改为「当前文件状态面板」。
- 修复三处「点了没反应」。
- 导入文件后不解析、入口重复、界面未国际化。
- 全新应用标识。

## 2.0.1 — 2026-10-14

- 补齐最后几处未国际化的文案。
- 修复 CI 版本同步：只在打 tag 时运行（此前 main 推送会把 pubspec 的版本
  改写成 `main`，三个平台的构建全部失败）。

## 2.0.0 — 2026-10-14

- 全新界面：侧边栏导航、Tab 详情页与平台专属视觉。
- 应用名统一为 AppInfoTool。
- 修复 APK 重命名失败，并支持 IPA 重命名。


## 1.1.0 — 2026-10-14

### 新增：安全检测引擎（V1.1）

- **Android 权限审计**：解析 `AndroidManifest.xml` 中的全部权限声明，包括 `maxSdkVersion` 版本条件与 `uses-permission-sdk-23` 特殊权限，逐项对照规则目录定级（P0–P3 / INFO / UNKNOWN）。
- **DEX 字符串线索扫描**：从 `classes.dex` 中提取可打印 ASCII 字符串，匹配 21 类标记（OCR、截图、媒体读取、上传、网络库、后台任务、第三方 SDK 等），并提取域名与 IP 地址。支持单文件 8 MiB、总计 48 MiB 的预算截断，超限部分如实记入覆盖不足。
- **iOS 隐私审计**：读取 `Info.plist` 的用途说明键、`PrivacyInfo.xcprivacy` 隐私清单，并扫描主 Mach-O 可执行文件的 API 符号线索。区分 `PHPickerViewController`（系统照片选择器，不需完整授权）与 PhotoKit（完整照片库），避免误报。
- **关联分析与风险定级**：
  - 相册 + OCR → P2（可能）
  - 相册 + OCR + 上传 → P1（疑似数据链路，未证实流）
  - 明文流量 + 敏感线索 → P1
  - 后台任务 + 敏感数据 + 回传 → P1
  - 未发现上传特征时显式产出 INFO，并说明「这不表示应用不存在上传行为」
- **六语言界面**：安全检测卡片、设置开关、报告导出支持 `en` / `zh-CN` / `zh-HK` / `zh-TW` / `ja` / `ko`。
- **报告导出**：Markdown 报告新增「安全检测」章节；新增 JSON 结构化安全报告导出（含 `ruleId`、`severity`、`confidence`、`evidence`、`limitations`）。
- **设置开关**：「启用安全检测」默认开启，可随时关闭。

### 数据模型

- 新增平台中立 `SecurityFinding` / `SecurityAnalysisResult` / `SecuritySeverity` / `SecurityConfidence` 等模型（`analysis_model` 包，零依赖）。
- `PackageAnalysisResult` 新增 `security` 字段，`AnalysisBuilder` 双平台均支持挂载。

### 测试

- 新增 10 项安全模型测试、7 项 DEX 扫描器测试、19 项 Android 安全审计测试、15 项 iOS 隐私审计测试、10 项应用层集成测试。
- 全量测试 593 通过 / 11 跳过。

## 1.0.0 — 2026-04-01

### 初始发布

- Android 包解析：APK / XAPK / APKM / APKS，支持 aapt2 与内置 Dart 解析器双引擎。
- iOS 包解析：IPA，支持 Info.plist、Mach-O、签名材料静态提取、图标解码（含 Apple CgBI）。
- 文件哈希：MD5 / SHA-1 / SHA-256。
- 签名验证：Android（apksigner）、iOS（codesign，macOS 专属）。
- 加固线索检测：容器结构异常、DEX 头部、AXML 布局异常等。
- 报告导出：Markdown 格式分析报告。
