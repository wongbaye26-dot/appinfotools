 <p align="center">
  <img src="docs/assets/icon_512.png" width="120" alt="AppInfoTool Logo">
</p>

<h1 align="center">AppInfoTool</h1>

<p align="center">
  <strong>跨平台移动应用包信息分析工具</strong><br>
  从 Android APK 到 iOS IPA，让应用信息查看更简单。
</p>

<p align="center">
  <a href="https://github.com/wongbaye26-dot/appinfotools">项目主页</a>
  ·
  <a href="https://github.com/wongbaye26-dot/appinfotools/issues">问题反馈</a>
  ·
  <a href="https://github.com/huanfeng/ApkInfoTool">原始开源项目</a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Flutter-Dart-blue?style=flat-square" alt="Flutter">
  <img src="https://img.shields.io/badge/Platform-Windows%20%7C%20macOS%20%7C%20Linux-blue?style=flat-square" alt="Platforms">
  <img src="https://img.shields.io/badge/Android-APK%20Analysis-3DDC84?style=flat-square" alt="Android">
  <img src="https://img.shields.io/badge/iOS-IPA%20Roadmap-lightgrey?style=flat-square" alt="iOS IPA roadmap">
  <img src="https://img.shields.io/badge/License-MIT-green?style=flat-square" alt="MIT License">
</p>

<p align="center">
  <strong>简体中文</strong> · <a href="README_en.md">English</a>
</p>

---

## 📖 项目简介

**AppInfoTool** 是一个基于 Flutter 开发的跨平台移动应用包信息查看工具，致力于让 Android 应用包的解析、信息查看、图标预览和安装辅助操作更加简单直观。

本项目基于开源项目 [ApkInfoTool](https://github.com/huanfeng/ApkInfoTool) 继续开发，在保留原有技术基础与功能方向的同时，持续进行产品品牌、用户界面、解析能力和跨平台体验方面的改进。

项目的长期目标是逐步扩展至 Android APK 与 Apple iOS IPA 两类应用包，提供统一的应用信息查看体验。

## ✨ 功能亮点

### Android APK 分析

* 📦 **多格式应用包**：支持 APK、XAPK、APKM、APKS 等格式，具体能力以当前版本实现为准。
* 🔍 **应用信息解析**：查看应用名称、包名、版本、SDK 信息、权限和组件等元数据。
* 🧩 **内置解析引擎**：采用纯 Dart 实现的 APK 解析能力，减少对外部解析工具的依赖。
* 🎨 **应用图标预览**：支持常见图标资源及自适应图标的解析、预览和导出。
* 📋 **分包信息查看**：查看支持格式中的 Split APK 与 OBB 相关信息。
* 🔐 **签名信息分析**：在相应工具可用的情况下，查看签名及证书相关信息。
* 🚀 **ADB 安装辅助**：为支持的 Android 应用包提供设备安装辅助能力。
* 📝 **文件管理**：为支持的格式提供文件信息查看及重命名等操作。

### 🍎 iOS IPA 分析

iOS IPA 分析是本项目的后续开发方向，计划逐步加入：

* 应用名称、Bundle ID、版本号及 Build 号。
* 最低 iOS 系统版本及相关设备信息。
* 应用图标和资源文件查看。
* Mach-O 可执行文件与架构信息。
* Framework、动态库和 App Extensions 清单。
* 代码签名材料、证书、Provisioning Profile 和 Entitlements 信息。

**说明：** 以上 IPA 功能为规划方向，不代表当前版本已经全部实现。具体支持情况以实际发布版本、测试结果和功能文档为准。

## 🖥️ 支持平台

项目采用 Flutter 开发，目标平台包括：

| 平台      | 说明                |
| ------- | ----------------- |
| Windows | 桌面应用              |
| macOS   | 桌面应用              |
| Linux   | 桌面应用，具体兼容性以实际测试为准 |

不同操作系统下，文件访问、外部工具调用和签名验证能力可能有所差异。

## 📸 界面预览

项目界面截图将在后续版本中持续更新。

欢迎通过 [Issues](https://github.com/wongbaye26-dot/appinfotools/issues) 提交建议、问题和界面改进意见。

## 📥 获取与运行

### 从源码运行

确保本机已安装 Flutter SDK 和对应平台的开发环境。

```bash
git clone https://github.com/wongbaye26-dot/appinfotools.git
cd appinfotools

flutter pub get
dart run build_runner build
flutter run
```

如果项目当前版本不需要重新生成代码，可以按照仓库现有构建流程执行。

### 构建桌面版本

```bash
flutter build windows
flutter build macos
flutter build linux
```

请在对应操作系统环境下构建目标平台版本，并根据实际构建结果确认兼容性。

### 下载发布版本

项目正式发布的安装包将通过本仓库的 [Releases](https://github.com/wongbaye26-dot/appinfotools/releases) 页面提供。

在本项目发布对应平台安装包之前，请优先使用源码构建方式，不要将原始项目的安装包误认为本项目的独立发行版本。

## 🛠️ 技术栈

* **Flutter / Dart**：跨平台桌面应用开发。
* **内置 APK 解析器**：解析 Android 二进制 XML、资源表等信息。
* **Android SDK 工具**：根据功能需要使用 ADB、aapt2、apksigner 等工具。
* **跨平台 UI**：统一的应用信息查看和操作体验。

后续将根据 IPA 分析需求，评估适合的 Property List、Mach-O 和代码签名信息解析方案。

## 🗺️ 后续规划

* [ ] 持续完善 APK 解析器的兼容性和异常处理。
* [ ] 提升加固 APK 的信息提取能力，并明确无法解析的字段。
* [ ] 完善签名与证书信息展示。
* [ ] 增强大文件处理、解析安全性和自动化测试。
* [ ] 新增 IPA 容器与 Info.plist 解析。
* [ ] 新增 IPA 图标、Mach-O、Framework 和扩展信息查看。
* [ ] 增加 IPA 签名材料与 Entitlements 分析。
* [ ] 完善 Windows、macOS、Linux 平台的构建与回归测试。
* [ ] 持续优化应用界面和多语言体验。

以上为开发规划，完成情况以仓库实际代码和发布记录为准。

## 🤝 参与贡献

欢迎提交问题反馈、功能建议和代码贡献。

1. Fork 本仓库。
2. 创建功能分支。
3. 提交清晰、可审查的代码变更。
4. 补充必要的测试与文档。
5. 提交 Pull Request。

对于解析器、文件格式和安全性相关的改动，建议同时提供可复现的测试样本与验证结果。

## 🙏 原项目与致谢

本项目特别感谢 **[huanfeng](https://github.com/huanfeng)** 开源的 [ApkInfoTool](https://github.com/huanfeng/ApkInfoTool)。

原项目为 Android 应用包信息解析、图标渲染、分包处理和跨平台桌面应用开发提供了重要的技术基础。AppInfoTool 在此基础上继续探索产品体验、解析能力和跨平台应用信息分析方向。

我们尊重原作者的技术成果与开源贡献，并感谢原作者及开源社区对相关技术的持续投入。

* 原始项目：[huanfeng/ApkInfoTool](https://github.com/huanfeng/ApkInfoTool)
* 本项目：[wongbaye26-dot/appinfotools](https://github.com/wongbaye26-dot/appinfotools)
* 原项目许可证：请以原始仓库中的 [LICENSE](https://github.com/huanfeng/ApkInfoTool/blob/main/LICENSE) 为准。

本项目保留原项目的来源说明，并根据实际代码来源、许可证要求及后续独立修改情况维护相关版权和致谢信息。

## 📄 开源协议

本仓库包含基于原始开源项目继续开发的内容。

请同时查看：

* [本仓库 LICENSE](https://github.com/wongbaye26-dot/appinfotools/blob/main/LICENSE)
* [原始项目 LICENSE](https://github.com/huanfeng/ApkInfoTool/blob/main/LICENSE)

分发或再利用代码时，请遵守相应许可证的版权声明、许可条件和其他适用要求。

---

<p align="center">
  AppInfoTool
</p>

<p align="center">
  让 Android 与 iOS 应用信息分析更简单。
</p>
