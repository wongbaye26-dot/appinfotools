# 评估：支持「安装应用」（APK / IPA）

> 状态：**评估稿，未实现**
> 日期：2026-10-21

## 结论先行

1. **APK 安装已经做完了**，而且做得比多数同类工具细（多设备、降级/覆盖/测试包、
   XAPK 分包、可中断）。缺的不是功能，是**没被当成「已完成」对待**。
2. **IPA 的「安装」按钮现在是个坏的入口**：`_buildActions` 不分平台，
   IPA 文件也会显示「安装」，点了执行 `adb install xxx.ipa`，必然失败。
   这是当前**唯一**需要立刻处理的 bug。
3. iOS 安装**技术上可行**，但门槛不在代码，在三件事：**包得是签好的**、
   **电脑得有工具**、**设备得信任这台电脑**。
4. 拿 12 个真实 IPA 统计过：**8 个企业签（任意设备可装）、2 个有效 Ad-Hoc、
   2 个描述文件已过期**。也就是说这个功能对现有样本是有真实价值的，不是摆设。
5. **不建议做重签名**。那是另一个产品（Sideloadly / AltStore 的领域），
   涉及证书、Apple ID、7 天有效期，风险与维护成本都不在一个量级。

---

## 一、现状盘点

### APK：已完成

| 能力 | 位置 | 状态 |
|---|---|---|
| 设备枚举 | `adb devices -l`（`install_dialog.dart:121`） | ✅ |
| 单/多设备安装 | `adb -s <id> install` | ✅ |
| 安装选项 | `-d` 降级 / `-r` 覆盖 / `-t` 测试包 | ✅ |
| XAPK 分包 | `xapk_installer.dart`（380 行，含分包选择） | ✅ |
| 中断 | `Process.start` + `_currentProcess` | ✅ |
| 工具来源 | 内置 / 系统环境 / 自定义 + 下载 | ✅ |

APK 侧真正缺的只有两点，都是打磨级别：

- **无线调试**：`AdbDevice.isWireless` 已经识别 `ip:port`，但没有配对的 UI
  （`adb pair`）。
- **卸载 / 降级到已装版本**：只有 install，没有 `adb uninstall`。

### IPA：入口是坏的

`lib/pages/info_page.dart:1395` 的「安装」按钮没有任何平台判断：

```dart
IconButton(
  icon: const Icon(Icons.install_mobile),
  tooltip: t.install.apk,
  onPressed: fileState.filePath == null ? null : () {
    showDialog(builder: (context) => InstallDialog(
      apkPath: fileState.filePath!,          // ← .ipa 也走这里
      isXapk: fileState.apkInfo?.isXapk ?? false,
    ));
  }),
```

打开 IPA 后点它 → `adb install /path/to/x.ipa` → `Failure [INSTALL_FAILED_INVALID_APK]`。
用户看到的是「安装失败」，而不是「iOS 包不能这样装」。

**这一条建议无论做不做 iOS 安装，都先修。**

### iOS 侧代码现状

全仓 **0 处**涉及 iOS 设备交互：没有 `ideviceinstaller`、没有 `devicectl`、
没有 `usbmuxd`。`install_dialog.dart` 里的 `AdbDevice` 是 Android 专用模型。

但**已经有大量可复用的前置能力**（见第五节）—— 这是这个项目做这件事的最大优势。

---

## 二、iOS 安装难在哪

Android 的 `adb install` 是「把文件推过去，系统自己校验」。iOS 反过来：
**安装器只负责搬运，能不能装是签名决定的**。三道门槛，缺一不可：

### 门槛 1：包必须是「为这台设备签的」

| 分发方式 | 能不能装到任意设备 | 说明 |
|---|---|---|
| 开发签名（Development） | ❌ 只有登记 UDID 的机器 | 描述文件里 `ProvisionedDevices` 限定 |
| Ad-Hoc | ❌ 同上 | 同上，最多 100 台/年 |
| **企业签名（In-House）** | ✅ 任意设备 | `ProvisionsAllDevices = true`；**证书随时可能被 Apple 吊销** |
| App Store | ❌ | 没有 `embedded.mobileprovision`，且二进制 FairPlay 加密 |
| 砸壳包（decrypted） | ❌ | 签名必然失效，必须先重签 |
| 越狱设备 + AppSync | ✅ | 绕过签名校验，但要求设备越狱 |

**这条决定了产品的边界**：我们只能装「已经签好、且签名覆盖目标设备」的包。
App Store 包、砸壳包、过期描述文件的包，一律装不上 —— 而且**必须在点安装之前
就说清楚**，不能让用户等 30 秒拿到一句 `ApplicationVerificationFailed`。

### 门槛 2：电脑上要有工具

| 工具 | 平台 | 依赖 | 说明 |
|---|---|---|---|
| `ideviceinstaller` | macOS / Linux / Windows | libimobiledevice | 走 `com.apple.mobile.installation_proxy`，**不需要开发者模式**，最贴近 `adb` 的体验 |
| `xcrun devicectl` | 仅 macOS | Xcode 15+ | 走 CoreDevice，**要求设备开启开发者模式**；接受的是解包后的 `.app`，不是 `.ipa` |
| `pymobiledevice3` | 全平台 | Python 3 | 功能最全，但要么内嵌 Python 运行时（体积 +100 MB 量级），要么要求用户自己装 |
| `ios-deploy` | macOS / Linux | Node | 老旧，主要面向调试场景 |

本机实测：`devicectl` 有（Xcode 642.16），`ideviceinstaller` / `ios-deploy` /
`cfgutil` 都没有。

### 门槛 3：设备要信任这台电脑

- 首次连接必须在手机上点「信任」，并保持解锁；
- 没配对时 `idevice_id -l` **返回空**，和「没插设备」无法区分；
- Windows 还要求装 **Apple Mobile Device Support**（iTunes 或「Apple 设备」App 带的），
  否则连设备枚举都做不到。

「没有找到设备」是这条路最常见的失败，且**原因有四五种**。UI 必须能分辨，
否则用户只会认为软件坏了。

---

## 三、真实样本的可装性（12 个 IPA）

用 `embedded.mobileprovision` 逐个解出来核对：

| 样本 | 签名类型 | 描述文件到期 | 可装性 |
|---|---|---|---|
| `77-v8.5.5.ipa` | 企业 | 2026-11-05 | ⚠️ 15 天后过期 |
| `Ptv_signed.ipa` | 企业 | 2027-05-18 | ✅ |
| `Ptv_signed_v3.ipa` | 企业 | 2027-07-27 | ✅ |
| `jincaizb_signed.ipa` | 企业 | 2027-09-27 | ✅ |
| `sun_signed.ipa` | 企业 | 2027-04-29 | ✅ |
| `wnsr_signed.ipa` | 企业 | 2027-07-14 | ✅ |
| `月光_signed_v3.ipa` | 企业 | 2027-03-04 | ✅ |
| `皇冠-v6.9.63.ipa` | 企业 | 2027-01-15 | ✅ |
| `hongjun_2mfffq.ipa` | Ad-Hoc（11 台） | 2027-09-16 | ⚠️ 仅登记设备 |
| `sun_nosigned.ipa` | Ad-Hoc（16 台） | 2027-09-15 | ⚠️ 仅登记设备 |
| `33-v8.5.5.ipa` | Ad-Hoc（3 台） | 2026-08-29 | ❌ **已过期** |
| `Ptv_nosignet.ipa` | Ad-Hoc（3 台） | 2026-08-29 | ❌ **已过期** |

**8 个企业签 + 2 个有效 Ad-Hoc = 10/12 名义可装；2/12 描述文件已过期，装不上。**

这个分布说明：这类工具的目标用户手里，**企业签包是主流**，所以「安装」对他们
是有意义的。同时也说明「装前体检」不是锦上添花 —— 12 个里就有 2 个注定失败。

> 注：企业证书被吊销是常态，`ProvisionsAllDevices` 只是「描述文件不限设备」，
> 不等于「证书还有效」。安装失败信息里的 `ApplicationVerificationFailed` /
> `A valid provisioning profile ... was not found` 要能翻译成人话。

---

## 四、建议方案

### 阶段 A：修入口 + APK 收尾（0.5–1 天）

- IPA 页的「安装」按钮：先做**能力判断**，不支持时禁用并给理由，而不是让它失败。
- APK：补 `adb uninstall`、无线调试配对（可选）。

### 阶段 B：iOS 安装 MVP —— 只做 macOS（3–4 天）

- 设备枚举：`idevice_id -l`（缺工具时给明确的安装指引，不报「没有设备」）。
- 安装：`ideviceinstaller -i <ipa>`，解析它的输出映射成人话。
- 工具解析沿用现有三档：**系统环境 → 自定义路径 → 引导安装**，
  与 `aapt2` / `adb` / `apksigner` 完全同构（`ToolPaths.findSystemTool` 那套）。
- 失败信息分类：`ApplicationVerificationFailed`（签名/证书）、
  `already installed`（版本冲突）、`device locked`、`not paired`、`no space`。

**不做**：Windows、重签名、越狱设备特殊处理。

### 阶段 C：Windows 上的 iOS（2–3 天，风险最高）

- 依赖 `Apple Mobile Device Support` + `ideviceinstaller.exe`。
- 二进制来源没有 Google SDK 那样的官方索引，只能自己托管或用 GitHub Releases
  —— 与 `ToolDownloader` 现在「解析 Google `repository2-3.xml`」的模式不同，
  要新写一套分发链路，**这是这条路上最大的不确定项**。
- 建议：先只做「检测 + 引导用户装 Apple 设备 / iTunes」，不自带二进制。

### 阶段 D：装前体检（1–2 天）—— 真正的差异化

在用户点「安装」之前，用**我们已经解析好的数据**回答「这个包装得上吗」：

| 检查项 | 数据来源 | 现状 |
|---|---|---|
| 有没有描述文件 | `IosSignatureMaterials.hasEmbeddedProvision` | ✅ 已有 |
| 描述文件过期没 | `IosProvisioningProfile.expirationDate` | ✅ 已有 |
| 企业签还是 Ad-Hoc | `ProvisionsAllDevices` / `ProvisionedDevices` | ❌ **需补两个字段** |
| 目标设备 UDID 在不在白名单 | 上面 + `idevice_id -l` | ❌ 需补 |
| 签名是否有效 | `codesign` 结论 | ✅ 已有 |
| 主二进制是否加密（砸壳） | `MachOCryptId` | ✅ 已有 |
| bundle id 与描述文件是否一致 | `compareIosAuthorization` | ✅ 已有 |

**七项里五项的数据已经在手**，只差描述文件的设备列表。这是竞品做不到的：
Sideloadly 之类是「先试着装，失败了再告诉你为什么」；我们可以**先说为什么**。

### 阶段 E：重签名（不建议，1–2 周 + 长期维护）

需要证书管理、Apple ID 登录、7 天重签、设备 UDID 注册、Anisette 数据……
做进去就是另一个产品，而且会把「分析工具」的定位搞模糊。**明确不做。**

---

## 五、为什么这个项目做这件事比从零做便宜

已具备、可直接复用的能力：

| 能力 | 位置 | 对本功能的用途 |
|---|---|---|
| IPA 解包到临时目录 | `IpaBundleExtractor`（512 MiB 预算、条目数上限、symlink 物化） | `devicectl` 路线需要 `.app` 目录；安装前预检也要解包 |
| 描述文件解析（CMS + plist） | `ios_signature.dart` | 判断企业/Ad-Hoc/过期 |
| 签名材料 + `codesign` 结论 | `IosCodeSignAnalyzer` | 预检「签名是否有效」 |
| 加密标志 | `macho_crypt_id.dart` | 预检「是不是砸壳包」 |
| 外部工具三档解析 | `ToolPaths.findSystemTool` + 设置页 UI | iOS 工具直接套同一套 |
| 依赖下载 / 校验 / 解包 | `ToolDownloader`（859 行，带预算与镜像） | 若决定自带二进制，链路是现成的 |
| 可中断子进程 | `Aapt2Task` / `CancellableTask` | 安装可能跑几十秒，必须能取消 |
| 安装对话框骨架 | `install_dialog.dart`（697 行） | 设备列表 + 逐台状态 + 中断，改造成本低 |

**结论：真正的新代码主要是「iOS 设备枚举 + 安装命令 + 输出翻译」，
大约 400–600 行，其余都是接线。**

---

## 六、风险与不可行边界

| 风险 | 影响 | 应对 |
|---|---|---|
| 用户没有 `ideviceinstaller` | 功能形同虚设 | 三档工具解析 + 明确安装指引（brew / 官网） |
| Windows 上缺 Apple Mobile Device Support | 连设备都看不到 | 启动时检测并引导，不要报「没有设备」 |
| 企业证书被吊销 | 安装失败，用户以为软件坏了 | 把 `ApplicationVerificationFailed` 翻译成「证书可能已被吊销」 |
| 设备未信任 / 未解锁 | 枚举为空 | 区分「未配对」「已配对但锁定」「无设备」三种 |
| 安装耗时（大包几十秒） | 界面卡死 | 复用 `CancellableTask`，进度 + 可取消 |
| 安全软件拦截 | 无法枚举 | 说明需要允许 usbmuxd 通信 |

**明确的不可行项**（要写进 UI，不能让用户试）：

- App Store 下载的 IPA（无描述文件 + 加密）—— 永远装不上；
- 描述文件已过期的包；
- Ad-Hoc 包装到未登记的设备；
- 未越狱设备装未签名/砸壳包。

---

## 七、工作量汇总

| 阶段 | 内容 | 估时 | 风险 |
|---|---|---|---|
| A | 修入口 + APK 收尾 | 0.5–1 天 | 低 |
| B | iOS 安装 MVP（macOS） | 3–4 天 | 中 |
| D | 装前体检 | 1–2 天 | 低（数据都在） |
| C | Windows 上的 iOS | 2–3 天 | **高**（二进制分发链路） |
| E | 重签名 | 1–2 周 | 不做 |

**建议的 MVP = A + B + D ≈ 5–7 天**，先把「macOS 上能装 + 装前说清楚能不能装」
做扎实；Windows 单独评估。

---

## 八、待确认的问题

1. **目标用户主要在哪台电脑上操作？** 如果 Windows 占多数，阶段 C 的风险要前置
   验证（拿一台 Windows 实测 `ideviceinstaller` + Apple 设备），否则做完了可能
   大部分用户用不上。
2. **是否接受「自带 libimobiledevice 二进制」？** 这会引入第三方二进制分发与
   升级维护，与现在「从 Google 官方 SDK 索引下载」的模式不同。
3. **要不要做 `devicectl` 路线？** 它要求开发者模式，对普通用户是额外门槛；
   但它不需要额外装任何东西（有 Xcode 就行）。
