<p align="center">
  <img src="docs/assets/icon_512.png" width="120" alt="AppInfoTool Logo">
</p>

<h1 align="center">AppInfoTool</h1>

<p align="center">
  <strong>跨平台 Android / iOS 应用包分析工具</strong><br>
  解析包结构、检视安全风险，一个窗口看完。
</p>

<p align="center">
  <a href="https://github.com/wongbaye26-dot/appinfotools/releases/latest">下载</a>
  ·
  <a href="https://github.com/wongbaye26-dot/appinfotools/issues">问题反馈</a>
  ·
  <a href="https://github.com/huanfeng/ApkInfoTool">原始开源项目</a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Flutter-Dart-blue?style=flat-square" alt="Flutter">
  <img src="https://img.shields.io/badge/Platform-Windows%20%7C%20macOS%20%7C%20Linux-blue?style=flat-square" alt="Platforms">
  <img src="https://img.shields.io/badge/Android-APK%20%7C%20XAPK%20%7C%20APKM%20%7C%20APKS-3DDC84?style=flat-square" alt="Android">
  <img src="https://img.shields.io/badge/iOS-IPA-000000?style=flat-square" alt="iOS">
  <img src="https://img.shields.io/badge/License-MIT-green?style=flat-square" alt="MIT License">
</p>

<p align="center">
  <strong>简体中文</strong> · <a href="README_en.md">English</a>
</p>

---

## 简介

**AppInfoTool** 是一个基于 Flutter 的桌面工具，用于查看 Android 与 iOS 应用包的内部信息。它把「这个包是什么、里面有什么、有没有风险」压缩到一次拖放里。

项目基于开源项目 [ApkInfoTool](https://github.com/huanfeng/ApkInfoTool) 继续开发，在保留其解析能力的基础上，重做了界面、补齐了 iOS 支持，并加入了安全检测引擎。

## 功能

### 包解析

| 平台 | 格式 | 能力 |
|---|---|---|
| Android | APK / XAPK / APKM / APKS | 应用名（多语言）、包名、版本、SDK 区间、屏幕与密度、ABI、权限、组件（Activity/Service/Receiver/Provider 及其导出状态）、分包与 OBB、文件结构（DEX / 原生库 / 顶层目录）|
| iOS | IPA | Bundle ID、版本与 Build、最低系统版本、设备族、可执行文件、嵌套 Bundle 与 Framework、URL Scheme、设备能力、Mach-O 架构、**`Assets.car` 资产目录** |

### iOS 图标：从 `Assets.car` 里真的取出图

iOS 11+ 的应用图标不在 `Info.plist` 里，而在 `Assets.car` —— 一个没有公开文档的
私有资产目录。本项目的做法：

| 步骤 | 说明 |
|---|---|
| 索引 | 解析 BOMStore 容器，列出每张 rendition 的名字 / 宽高 / 像素格式 / 压缩方式 |
| 资产名 | 解析 `RENDITIONS` 键索引，把 rendition 归到资产名（`AppIcon` 等）。83 个真实容器、25,986 个条目逐条核对无差异 |
| 解码 | **纯 Dart 实现 LZFSE**，与 Apple 自己的 `libcompression` 逐字节一致；支持一个块内多段串接的流 |
| 出图 | ARGB / BGRA / GA8，以及**调色板索引色**（含大字图分块、每块独立调色板）|

出图率约 50% —— 其余是 deepmap2 的多平面变体，**查清后决定不实现**：
用已知像素的样本探测过四种还原方式都不成立，硬解只会得到「看起来像图但颜色错」的结果。
这类情况会明确报「本实现不解这个模式」，而不是报「数据损坏」。

### 安全检测

| 能力 | 说明 |
|---|---|
| 权限审计 | 按权限逐条给出风险等级、用途与判定依据；`maxSdkVersion` 与 `uses-permission-sdk-23` 等版本条件不会被丢弃 |
| OCR / 敏感数据线索 | 扫描 DEX 中的字符串标记，提示证件识别、截图、相册读取等能力 |
| 代码级取证 | DEX 三层递进：**结构 → 方法引用 → 调用点**。「代码引用了」与「字符串里提到了」分开陈述，调用点还能回答「在哪个方法的哪个偏移」 |
| 原生库符号 | 读取 ELF `.dynsym` 与 Mach-O `LC_SYMTAB`，按**精确符号名**匹配导入的系统能力（`system` / `dlopen` / `ptrace` / `socket` …）|
| 原生库加固 | 逐个 `.so` 检查 `PT_GNU_STACK`（可执行栈）、`PT_GNU_RELRO`、`DT_FLAGS` / `DT_FLAGS_1`（BIND_NOW），并按 ABI 去重 |
| 伪装检测 | `lib/<abi>/*.so` 的内容若实际是 DEX —— 运行时会 `DexClassLoader` 加载，静态分析的结论对那部分不成立 |
| 签名方案 | 解析 APK Signing Block **与 `META-INF` 的 v1 两件套**，区分「未签名 / 只有 v1 / v2 / v3 / v3.1」—— 「有签名」「只有 v1」与「根本没签」是三件不同的事 |
| 清单配置 | `debuggable`、`allowBackup`、导出组件、**ContentProvider 专项**（authorities / `grantUriPermissions` / `readPermission`+`writePermission` 是否只护住一个方向）、`networkSecurityConfig`（**真的展开那份 XML**，不因属性被忽略就跳过）|
| 第三方 SDK | 25 个服务类包名前缀（推送 / 统计 / 归因 / 支付 / 地图 / 验证码 / 风控 / 崩溃上报 …），按 DEX `string_ids` 精确索引而非字节扫描 |
| 数据回传分析 | 识别网络库、上传接口与域名 / IP，标注「已确认 / 疑似 / 仅具备能力」 |
| 隐私清单 | iOS 侧检查 `Info.plist` 用途说明、`PrivacyInfo.xcprivacy` 声明（含**必需理由 API** `NSPrivacyAccessedAPITypes`），以及「声明了权限但没调用 API」的双向对照 |
| 权限请求 | iOS 侧从 `__TEXT,__objc_methname` 的**选择子表**读「代码真的会申请哪些权限」—— 比用途说明强一档；Android 侧区分 signature 级权限（声明了也拿不到） |
| 分析覆盖 | 逐维度给出「已覆盖 / 部分覆盖 / 未覆盖 / 本次不适用」，界面、Markdown 与 JSON 读同一份数据 |
| 风险分级 | P0–P3 / INFO / **UNKNOWN** —— 「无法确认」与「低风险」严格分开，覆盖不足不会被显示成绿色 |

Android 侧 19 条规则（其中 7 条是跨字段的组合规则）+ 28 条逐权限条目、iOS 侧 29 条；分级按**来源稀有度**而非一律高危 ——
设备标识 / 定位 / 剪贴板这类几乎每个应用都有的能力给 P3，通讯录 / 短信 / 录音 + 上传才给 P2。
组合规则 C 的等级**跟着证据强度走**：同一方法体内两个调用点给 P1，只有整包层面共现给 P2。

### 界面

- **概览页**：一屏看完 —— 当前文件状态、平台/大小/签名/安全四个状态卡、统计与最近文件
- **详情页**：六个 Tab（概览 / 应用 / 权限 / 结构 / 签名 / 安全），APK 与 IPA 语义一致
- **版本对比**：选两个已解析的包做结构化差异（字段级 + 权限 / 组件 / 原生符号 / 域名等集合级），
  三态呈现，且把「我们没读到」与「文件里没有」严格分开；可导出 Markdown / JSON 对比报告
- **拖放即用**：拖入文件自动解析
- **文件关联**：把 `.apk` / `.ipa` / `.xapk` / `.apks` / `.apkm` 登记为本程序的候选打开方式。
  Windows 由程序自己写注册表（`HKCU`，无需管理员），macOS 提示在 Finder 的「显示简介 → 打开方式」里设置
  —— 系统里没有对应的设置面板，所以不会假装能跳过去
- **导出**：分析报告（Markdown / JSON）、应用图标（PNG / SVG / 原始文件）
- **重命名**：按应用名或「名称+版本」批量命名
- **明暗主题** + 多语言界面

### Windows：资源管理器里显示每个包的真实图标

`.apk` / `.ipa` 可以在资源管理器里显示各自应用的真实图标，而不是统一的文件图标。

**默认关闭**，需要在「设置 → 系统文件图标」里点一次「启用」——这项功能要往注册表写
缩略图处理器登记项，那是往系统里装东西，不该在用户不知情时发生。「停用」只删本项目
写的那两个键，不碰其它应用，也不改 `.apk` 的默认打开方式。

实现是一个 in-proc COM 缩略图处理器 + 一个独立进程的解析器：DLL 由 `explorer.exe`
加载，因此**不能**在里面跑解析逻辑——那会把崩溃风险带进桌面进程。DLL 只负责起子进程
（1.5 秒超时即杀）并把结果用 WIC 解码成位图。

已知边界，写在这里以免预期落空：

- **自适应图标（`<adaptive-icon>` XML）不支持**，这类 APK 回退到文件图标。
  不会退而取前景层——那会显示一个缺了一半的图标，比没有更糟。
- WebP 图标依赖系统解码器（Windows 11 内置；Windows 10 需 Store 里的 WebP 扩展），
  解不了时回退文件图标。
- 只有缩略图视图（大/中图标）生效；列表、详细信息、小图标视图仍是统一的文件图标。
- **运行时行为尚未在真机上验收。** CI 验证了编译、产物打包与自检程序，但「图标真的
  出现在资源管理器里」需要 Windows 上人工确认。清单见
  `docs/plans/V2.5.0-windows-manual-acceptance.md`。

### 界面语言

四种语言**完整覆盖**：简体中文 / 繁體中文（台灣）/ 繁體中文（香港）/ English。

日本語与한국어为**部分覆盖**（各缺约 10% 的文案），缺失部分回退到英文。
这两种是早期加入的，后续新增的文案没有补齐 —— 所以这里不把它们算作「完整支持的语言」，
以免给出「切过去全是母语」的错误预期。

## 下载

从 [Releases](https://github.com/wongbaye26-dot/appinfotools/releases/latest) 获取最新版本：

| 平台 | 文件 |
|---|---|
| macOS | `AppInfoTool-<版本>-macOS-universal.dmg`（Intel + Apple Silicon） |
| Windows | `AppInfoTool-<版本>-Windows-x86_64-Setup.exe`（安装版）/ `.zip`（免安装） |
| Linux | `AppInfoTool-<版本>-Linux-x86_64.AppImage` |

> **macOS 说明**：当前发布包为 ad-hoc 签名。首次打开若被 Gatekeeper 拦截，请右键 →「打开」，或执行：
> ```bash
> xattr -dr com.apple.quarantine "/Applications/AppInfoTool.app"
> ```

### 让 `.apk` / `.ipa` 双击打开本程序

| 平台 | 做法 |
|---|---|
| Windows | **不需要手动操作**。程序每次启动都会把 `.apk` / `.ipa` / `.xapk` / `.apks` / `.apkm` 登记为候选打开方式（写 `HKCU`，不需要管理员权限）。之后在文件的「打开方式 → 选择其他应用」里就能看到本程序 |
| macOS | 系统没有「默认应用」设置页。在 Finder 里右键任一 `.apk` →「显示简介」→ 展开「打开方式」→ 选 AppInfoTool → 点「全部更改…」 |

> Windows 上**不会**自动抢成默认程序：默认程序由带哈希校验的 `UserChoice` 决定，
> 程序无法合法改写。是否设为默认由你在系统里决定。

## 从源码运行

需要 Flutter SDK（stable）与对应平台的开发环境。

```bash
git clone https://github.com/wongbaye26-dot/appinfotools.git
cd appinfotools

flutter pub get
dart run build_runner build --delete-conflicting-outputs
flutter run -d macos    # 或 windows / linux
```

### 构建发布版

```bash
flutter build macos --release
flutter build windows --release
flutter build linux --release
```

macOS 还可以用仓库里的脚本一步完成构建、签名校验与 DMG 打包：

```bash
tool/build_macos.sh
```

## 技术栈

- **Flutter / Dart** —— 跨平台桌面应用
- **纯 Dart 解析器** —— 自行实现 AXML、`resources.arsc`、二进制 plist、Mach-O、DEX、ELF、APK Signing Block、`Assets.car`、**LZFSE** 的解析，不依赖外部工具即可读出大部分字段
- **外部工具（可选）** —— `apksigner` / `codesign` 用于签名验证，`adb` 用于安装辅助，`aapt2` 可作为备用解析引擎；未安装时如实显示「无法确认」而不是报「签名无效」
- **Riverpod** —— 状态管理
- **slang** —— 类型安全的国际化

### 项目结构

```
lib/                应用层（页面、Provider、UI 组件）
packages/
  analysis_model/   平台中立的数据模型（零依赖）
  archive_safety/   不可信 ZIP 的安全原语（预算、结构校验）
  apk_parser/       Android 解析
  ipa_parser/       iOS 解析
  app_icon_extractor/ 无界面图标提取（零 Flutter 依赖，可 AOT 成独立 exe）
windows/thumbnail/  Shell 缩略图处理器（in-proc COM DLL）
tool/               构建、图标生成、夹具生成与性能探针
test/fixtures/      夹具（全部由公开工具或真实产物生成，不入手拼字节）
docs/               审计报告与格式调研笔记
```

Android 与 iOS 解析器互不依赖，只共享 `analysis_model` 与 `archive_safety`。

### 质量与验证

- **1,607 个根测试 + 372 个包内测试**（`analysis_model` / `archive_safety` / `apk_parser` / `ipa_parser` / `app_icon_extractor`），`flutter analyze --fatal-infos --fatal-warnings` 零问题，`dart format` 干净；CI 在三个平台各跑一遍同款门禁
- **期望值一律来自独立实现**，不取自本项目解析器：
  `aapt2` 核对清单与资源、`apksigner` / `codesign` 核对签名、`assetutil` 核对 iOS 资产目录、
  `libcompression`（Apple 系统库）核对 LZFSE、`actool`（Xcode 自带）生成资产目录夹具
- **夹具用真实产物**，不手拼字节 —— 手拼样本会带着与解析器相同的错误假设，等于自证

## 已知局限

这些是本项目**明确查过、并且决定不模糊处理**的边界 —— 遇到时会如实报出来，
而不是给一个看起来像结论的东西。

| 局限 | 说明 |
|---|---|
| `Assets.car` 只解约一半 | 剩余是 deepmap2 的多平面变体（模式 `0x02` / `0x03`）。四种还原方式都用已知像素的样本探测过，均不成立，因此不实现 |
| `Assets.car` 资产名需要键索引 | 容器里没有 `KEYFORMAT`（旧存储格式）时拿不到资产名，只列 rendition 名 —— 会明说「本容器没有键索引」 |
| `bvx1` / `bvxn` 不支持 | `bvx1` 没有工具产出；`bvxn`（LZVN）在实测的 951 张真实光栅图里出现 0 次。两者都抛带稳定错误码的异常，而不是猜一个实现 |
| 静态分析看不到运行时加载的代码 | `DexClassLoader` 加载的内容不在归档里，结论对那部分不成立。这类情况进「覆盖不足」而不是「已检查」 |
| 大包扫描有预算上限 | 超出预算的维度标为 `partial` 并给出**比例**（例如「266 个唯一原生库，只扫了 24 个」），不会写成「24/24 已覆盖」 |
| 签名验证依赖外部工具 | 未安装 `apksigner` / `codesign` 时显示「无法确认」，**不等于**签名无效 |
| 日本語 / 한국어 未补齐 | 见上文「界面语言」 |

## 设计原则

几条贯穿整个项目的取舍：

- **不把「没查到」说成「没问题」**。字段缺失分 `absent` / `wrongType` / `failed` / `unsupported`，界面上各有各的呈现；安全等级里的 `UNKNOWN` 与 `P3` 严格分开。
- **不猜**。解析畸形文件时记录诊断并保留已读到的部分，而不是抛异常或填占位值。
- **签名验证只认受信任工具的明确结论**。工具不可用 ≠ 签名无效。
- **不可信输入先验边界**。归档层有解压预算，解析器有深度上限与环检测。
- **「能跑但结果是错的」比「明确说不支持」更糟**。所以不支持的格式一律报错误码，不做「尽力而为」的猜测 —— 一张颜色错的图标，用户看不出来是错的。

## 参与贡献

欢迎提交问题反馈、功能建议与代码贡献。

1. Fork 本仓库
2. 创建功能分支
3. 提交清晰、可审查的变更
4. 补充必要的测试与文档
5. 提交 Pull Request

对于解析器与安全性相关的改动，请同时提供可复现的测试样本与验证结果。

## 致谢

本项目特别感谢 **[huanfeng](https://github.com/huanfeng)** 开源的 [ApkInfoTool](https://github.com/huanfeng/ApkInfoTool)。原项目为 Android 包解析、图标渲染与跨平台桌面开发提供了重要的技术基础。

- 原始项目：[huanfeng/ApkInfoTool](https://github.com/huanfeng/ApkInfoTool)
- 本项目：[wongbaye26-dot/appinfotools](https://github.com/wongbaye26-dot/appinfotools)

## 开源协议

[MIT License](LICENSE)，继承自原始项目（Copyright © 2024 huanfeng）。

分发或再利用代码时，请遵守许可证的版权声明与许可条件。

---

<p align="center">
  AppInfoTool · 让应用包分析更简单
</p>
