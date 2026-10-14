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
| Android | APK / XAPK / APKM / APKS | 应用名（多语言）、包名、版本、SDK 区间、屏幕与密度、ABI、权限、组件（Activity/Service/Receiver/Provider 及其导出状态）、分包与 OBB、文件结构（DEX / 原生库 / 顶层目录） |
| iOS | IPA | Bundle ID、版本与 Build、最低系统版本、设备族、可执行文件、嵌套 Bundle 与 Framework、URL Scheme、设备能力、Mach-O 架构 |

### 安全检测

| 能力 | 说明 |
|---|---|
| 权限审计 | 按权限逐条给出风险等级、用途与判定依据；`maxSdkVersion` 与 `uses-permission-sdk-23` 等版本条件不会被丢弃 |
| OCR / 敏感数据线索 | 扫描 DEX 中的字符串标记，提示证件识别、截图、相册读取等能力 |
| 代码级取证 | DEX 三层递进：**结构 → 方法引用 → 调用点**。「代码引用了」与「字符串里提到了」分开陈述，调用点还能回答「在哪个方法的哪个偏移」 |
| 原生库符号 | 读取 ELF `.dynsym` 与 Mach-O `LC_SYMTAB`，按**精确符号名**匹配导入的系统能力（`system` / `dlopen` / `ptrace` / `socket` …） |
| 数据回传分析 | 识别网络库、上传接口与域名 / IP，标注「已确认 / 疑似 / 仅具备能力」 |
| 隐私清单 | iOS 侧检查 `Info.plist` 用途说明与 `PrivacyInfo.xcprivacy` 声明 |
| 分析覆盖 | 逐维度给出「已覆盖 / 部分覆盖 / 未覆盖 / 本次不适用」，界面、Markdown 与 JSON 读同一份数据 |
| 风险分级 | P0–P3 / INFO / **UNKNOWN** —— 「无法确认」与「低风险」严格分开，覆盖不足不会被显示成绿色 |

### 界面

- **概览页**：一屏看完 —— 当前文件状态、平台/大小/签名/安全四个状态卡、统计与最近文件
- **详情页**：六个 Tab（概览 / 应用 / 权限 / 结构 / 签名 / 安全），APK 与 IPA 语义一致
- **拖放即用**：拖入文件自动解析
- **导出**：分析报告（Markdown / JSON）、应用图标（PNG / SVG / 原始文件）
- **重命名**：按应用名或「名称+版本」批量命名
- **明暗主题** + 六种界面语言（简体中文 / 繁體中文 ×2 / English / 日本語 / 한국어）

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
- **纯 Dart 解析器** —— 自行实现 AXML、`resources.arsc`、二进制 plist、Mach-O 的解析，不依赖外部工具即可读出大部分字段
- **外部工具（可选）** —— `apksigner` / `codesign` 用于签名验证，`adb` 用于安装辅助；未安装时如实显示「无法确认」而不是报「签名无效」
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
tool/               构建与图标生成脚本
```

Android 与 iOS 解析器互不依赖，只共享 `analysis_model` 与 `archive_safety`。

## 设计原则

几条贯穿整个项目的取舍：

- **不把「没查到」说成「没问题」**。字段缺失分 `absent` / `wrongType` / `failed` / `unsupported`，界面上各有各的呈现；安全等级里的 `UNKNOWN` 与 `P3` 严格分开。
- **不猜**。解析畸形文件时记录诊断并保留已读到的部分，而不是抛异常或填占位值。
- **签名验证只认受信任工具的明确结论**。工具不可用 ≠ 签名无效。
- **不可信输入先验边界**。归档层有解压预算，解析器有深度上限与环检测。

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
