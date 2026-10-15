<p align="center">
  <img src="docs/assets/icon_512.png" width="120" alt="AppInfoTool Logo">
</p>

<h1 align="center">AppInfoTool</h1>

<p align="center">
  <strong>Cross-platform Android / iOS package inspector</strong><br>
  Parse the structure, review the risks — all in one window.
</p>

<p align="center">
  <a href="https://github.com/wongbaye26-dot/appinfotools/releases/latest">Download</a>
  ·
  <a href="https://github.com/wongbaye26-dot/appinfotools/issues">Report an issue</a>
  ·
  <a href="https://github.com/huanfeng/ApkInfoTool">Original project</a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Flutter-Dart-blue?style=flat-square" alt="Flutter">
  <img src="https://img.shields.io/badge/Platform-Windows%20%7C%20macOS%20%7C%20Linux-blue?style=flat-square" alt="Platforms">
  <img src="https://img.shields.io/badge/Android-APK%20%7C%20XAPK%20%7C%20APKM%20%7C%20APKS-3DDC84?style=flat-square" alt="Android">
  <img src="https://img.shields.io/badge/iOS-IPA-000000?style=flat-square" alt="iOS">
  <img src="https://img.shields.io/badge/License-MIT-green?style=flat-square" alt="MIT License">
</p>

<p align="center">
  <a href="README.md">简体中文</a> · <strong>English</strong>
</p>

---

## Overview

**AppInfoTool** is a Flutter desktop tool for inspecting Android and iOS application packages. It answers "what is this package, what's inside it, and is anything risky" in a single drag-and-drop.

It builds on the open-source [ApkInfoTool](https://github.com/huanfeng/ApkInfoTool), keeping its parsing foundation while reworking the interface, completing iOS support, and adding a security audit engine.

## Features

### Package parsing

| Platform | Formats | What you get |
|---|---|---|
| Android | APK / XAPK / APKM / APKS | App name (all locales), package ID, version, SDK range, screens & densities, ABIs, permissions, components (Activity/Service/Receiver/Provider with exported state), split APKs and OBB, file structure (DEX / native libs / top-level dirs) |
| iOS | IPA | Bundle ID, version and build, minimum OS, device family, executable, nested bundles and frameworks, URL schemes, device capabilities, Mach-O architectures |

### Security audit

| Capability | Description |
|---|---|
| Permission review | Per-permission severity, purpose and rationale. Version conditions such as `maxSdkVersion` and `uses-permission-sdk-23` are preserved rather than dropped |
| OCR / sensitive-data clues | Scans DEX strings for document scanning, screenshots, photo-library access and similar capabilities |
| Code-level evidence | Three DEX layers: **structure → method references → call sites**. "Code references it" is kept separate from "a string mentions it", and call sites can name the method and instruction offset |
| Native library symbols | Reads ELF `.dynsym` and Mach-O `LC_SYMTAB`, matching imported system capabilities by **exact symbol name** (`system` / `dlopen` / `ptrace` / `socket` …) |
| Data transmission analysis | Detects network libraries, upload endpoints and domains/IPs, labelled **confirmed / suspected / capability only** |
| Privacy manifests | On iOS, checks `Info.plist` usage descriptions and `PrivacyInfo.xcprivacy` declarations |
| Analysis coverage | Per-dimension status: covered / partially covered / not covered / not applicable. The UI, Markdown and JSON all read the same data |
| Risk grading | P0–P3 / INFO / **UNKNOWN** — "cannot determine" is kept strictly separate from "low risk", so limited coverage is never shown as green |

### Interface

- **Overview** — everything on one screen: current file status, four status cards (platform / size / signature / security), statistics and recent files
- **Detail page** — six tabs (Overview / Application / Permissions / Structure / Signature / Security) with identical semantics for APK and IPA
- **Version comparison** — structured diff between two analysed packages (field level plus collections such as permissions, components, native symbols and domains), shown as added / removed / changed while keeping "we could not read it" strictly apart from "not present in the file"; exports a Markdown / JSON comparison report
- **Drag and drop** — dropping a file starts the analysis immediately
- **Export** — analysis report (Markdown / JSON), app icons (PNG / SVG / original file)
- **Rename** — rename by app name, or name + version
- **Light/dark themes** and six UI languages (English / 简体中文 / 繁體中文 ×2 / 日本語 / 한국어)

## Download

Get the latest build from [Releases](https://github.com/wongbaye26-dot/appinfotools/releases/latest):

| Platform | File |
|---|---|
| macOS | `AppInfoTool-<version>-macOS-universal.dmg` (Intel + Apple Silicon) |
| Windows | `AppInfoTool-<version>-Windows-x86_64-Setup.exe` (installer) / `.zip` (portable) |
| Linux | `AppInfoTool-<version>-Linux-x86_64.AppImage` |

> **macOS note**: release builds are ad-hoc signed. If Gatekeeper blocks the first launch, right-click → Open, or run:
> ```bash
> xattr -dr com.apple.quarantine "/Applications/AppInfoTool.app"
> ```

## Running from source

Requires the Flutter SDK (stable) and the toolchain for your platform.

```bash
git clone https://github.com/wongbaye26-dot/appinfotools.git
cd appinfotools

flutter pub get
dart run build_runner build --delete-conflicting-outputs
flutter run -d macos    # or windows / linux
```

### Release builds

```bash
flutter build macos --release
flutter build windows --release
flutter build linux --release
```

On macOS, the bundled script handles build, signature verification and DMG packaging in one step:

```bash
tool/build_macos.sh
```

## Tech stack

- **Flutter / Dart** — cross-platform desktop app
- **Pure-Dart parsers** — AXML, `resources.arsc`, binary plists and Mach-O are parsed in-house, so most fields are available without external tools
- **Optional external tools** — `apksigner` / `codesign` for signature verification, `adb` for install assistance. When a tool is missing, the UI reports "cannot determine" rather than claiming the signature is invalid
- **Riverpod** — state management
- **slang** — type-safe internationalization

### Project layout

```
lib/                Application layer (pages, providers, widgets)
packages/
  analysis_model/   Platform-neutral data models (zero dependencies)
  archive_safety/   Safety primitives for untrusted ZIPs (budget, structure checks)
  apk_parser/       Android parsing
  ipa_parser/       iOS parsing
tool/               Build and icon-generation scripts
```

The Android and iOS parsers do not depend on each other; they share only `analysis_model` and `archive_safety`.

## Design principles

A few decisions that shape the whole project:

- **Never present "couldn't find it" as "nothing wrong"**. Missing fields are distinguished as `absent` / `wrongType` / `failed` / `unsupported`; in risk grading, `UNKNOWN` is kept apart from `P3`.
- **Don't guess**. Malformed input yields diagnostics plus whatever was successfully read — never an exception or a placeholder value.
- **Signature verdicts come only from trusted tools' explicit conclusions**. "Tool unavailable" is not "signature invalid".
- **Validate bounds before using untrusted input**. The archive layer enforces a decompression budget; parsers enforce depth limits and cycle detection.

## Contributing

Issues, feature requests and pull requests are welcome.

1. Fork the repository
2. Create a feature branch
3. Make focused, reviewable changes
4. Add the necessary tests and documentation
5. Open a pull request

For changes to parsers or security logic, please include a reproducible sample and the verification results.

## Acknowledgements

Special thanks to **[huanfeng](https://github.com/huanfeng)** for the open-source [ApkInfoTool](https://github.com/huanfeng/ApkInfoTool), which provided the technical foundation for Android package parsing, icon rendering and cross-platform desktop development.

- Original project: [huanfeng/ApkInfoTool](https://github.com/huanfeng/ApkInfoTool)
- This project: [wongbaye26-dot/appinfotools](https://github.com/wongbaye26-dot/appinfotools)

## License

[MIT License](LICENSE), inherited from the original project (Copyright © 2024 huanfeng).

When redistributing or reusing the code, please comply with the license's copyright notice and conditions.

---

<p align="center">
  AppInfoTool · Package analysis made simple
</p>
