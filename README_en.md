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
| iOS | IPA | Bundle ID, version and build, minimum OS, device family, executable, nested bundles and frameworks, URL schemes, device capabilities, Mach-O architectures, and the **`Assets.car` asset catalog** |

### iOS icons: actually decoding `Assets.car`

On iOS 11+ the app icon lives in `Assets.car`, an undocumented private asset catalog,
not in `Info.plist`. This project decodes it end to end:

| Step | What it does |
|---|---|
| Index | Parses the BOMStore container and lists every rendition's name / dimensions / pixel format / compression |
| Asset names | Parses the `RENDITIONS` key index to map renditions back to asset names (`AppIcon` etc.). Verified entry-by-entry against 25,986 renditions across 83 real containers, with zero differences |
| Decoding | **LZFSE implemented in pure Dart**, byte-for-byte identical to Apple's own `libcompression`; handles multiple concatenated streams inside one block |
| Rendering | ARGB / BGRA / GA8, plus **palette-indexed colour** (including banded large images, each band carrying its own palette) |

Roughly 50% of renditions render. The remainder are deepmap2 multi-plane variants which
**were investigated and deliberately left unimplemented**: four different reconstruction
approaches were probed against known-pixel samples and none held up, so a decoder written
on guesswork would produce images that look plausible but have the wrong colours.
Those cases are reported as "this decoder does not implement that mode", never as "corrupt data".

### Security audit

| Capability | Description |
|---|---|
| Permission review | Per-permission severity, purpose and rationale. Version conditions such as `maxSdkVersion` and `uses-permission-sdk-23` are preserved rather than dropped |
| OCR / sensitive-data clues | Scans DEX strings for document scanning, screenshots, photo-library access and similar capabilities |
| Code-level evidence | Three DEX layers: **structure → method references → call sites**. "Code references it" is kept separate from "a string mentions it", and call sites can name the method and instruction offset |
| Native library symbols | Reads ELF `.dynsym` and Mach-O `LC_SYMTAB`, matching imported system capabilities by **exact symbol name** (`system` / `dlopen` / `ptrace` / `socket` …) |
| Native hardening | Per-`.so` checks of `PT_GNU_STACK` (executable stack), `PT_GNU_RELRO`, and `DT_FLAGS` / `DT_FLAGS_1` (BIND_NOW), de-duplicated by ABI |
| Disguise detection | A `lib/<abi>/*.so` whose contents are actually DEX — loaded at runtime via `DexClassLoader`, so static conclusions do not cover it |
| Signing schemes | Parses the APK Signing Block **and the v1 pair under `META-INF`**, distinguishing unsigned / v1-only / v2 / v3 / v3.1 — "signed", "v1 only" and "not signed at all" are three different facts |
| Manifest configuration | `debuggable`, `allowBackup`, exported components, and `networkSecurityConfig` (**the XML is actually expanded**, rather than skipped because the attribute is overridden) |
| Third-party SDKs | 25 service-oriented package prefixes (push / analytics / attribution / payments / maps / captcha / fraud / crash reporting …), indexed via DEX `string_ids` instead of byte scanning |
| Data transmission analysis | Detects network libraries, upload endpoints and domains/IPs, labelled **confirmed / suspected / capability only** |
| Privacy manifests | On iOS, checks `Info.plist` usage descriptions, `PrivacyInfo.xcprivacy` declarations, and cross-checks "declared but never used" against "used but not declared" |
| Analysis coverage | Per-dimension status: covered / partially covered / not covered / not applicable. The UI, Markdown and JSON all read the same data |
| Risk grading | P0–P3 / INFO / **UNKNOWN** — "cannot determine" is kept strictly separate from "low risk", so limited coverage is never shown as green |

There are 19 security rules on Android (8 of them cross-field combinations) and 25 on iOS. Severity is scaled by **how rare the source is**
rather than defaulting to high: device identifiers, location and clipboard are P3 because nearly every
app has them, while contacts / SMS / microphone combined with upload are P2.

### Interface

- **Overview** — everything on one screen: current file status, four status cards (platform / size / signature / security), statistics and recent files
- **Detail page** — six tabs (Overview / Application / Permissions / Structure / Signature / Security) with identical semantics for APK and IPA
- **Version comparison** — structured diff between two analysed packages (field level plus collections such as permissions, components, native symbols and domains), shown as added / removed / changed while keeping "we could not read it" strictly apart from "not present in the file"; exports a Markdown / JSON comparison report
- **Drag and drop** — dropping a file starts the analysis immediately
- **File association** — registers `.apk` / `.ipa` / `.xapk` / `.apks` / `.apkm` as candidate handlers for this app.
  On Windows the app writes the registry itself (`HKCU`, no admin rights needed); on macOS it explains
  how to set it in Finder's *Get Info → Open with*, because macOS has no such settings pane and this
  project does not pretend otherwise
- **Export** — analysis report (Markdown / JSON), app icons (PNG / SVG / original file)
- **Rename** — rename by app name, or name + version
- **Light/dark themes** and a multilingual UI

### Windows: real app icons in File Explorer

`.apk` / `.ipa` files can show their own app icon in File Explorer instead of the generic
file icon.

**Off by default.** Turn it on once under Settings → System file icons. The feature
writes a thumbnail-handler registration under the registry (per-user `HKCU`), which is
installing something into your system — it should not happen behind your back.
Disabling it removes exactly the two keys this app wrote; it does not touch other
handlers or change the default app for `.apk`.

The design is an in-proc COM thumbnail handler plus an out-of-process parser. Explorer
loads the handler into itself, so the parsing must **not** run there — a crash would take
the whole desktop down. The DLL only launches the child process (killed after 1.5 s) and
decodes the result into a bitmap with WIC.

Known boundaries, stated up front:

- **Adaptive icons (`<adaptive-icon>` XML) are not supported**; such APKs fall back to the
  file icon. It deliberately does not fall back to the foreground layer — that would show
  a half-complete icon, which is worse than none.
- WebP icons depend on the system decoder (built into Windows 11; Windows 10 needs the
  WebP Image Extension from the Store). When decoding fails it falls back to the file icon.
- Thumbnail views only (large / medium icons). List, details and small-icon views still
  show the generic file icon.
- **Runtime behaviour has not been verified on real hardware yet.** CI proves it compiles,
  ships in the installer, and that the self-test binary links — but "the icon actually
  shows up in Explorer" needs a human on Windows. Checklist:
  `docs/plans/V2.5.0-windows-manual-acceptance.md`.

### UI languages

Four languages are **fully covered**: English / 简体中文 / 繁體中文 (Taiwan) / 繁體中文 (Hong Kong).

日本語 and 한국어 are **partially covered** (each missing about 10% of the strings), with the gaps
falling back to English. They were added early and later strings were never backfilled — so they are
not listed as fully supported, which would set the wrong expectation.

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

### Making `.apk` / `.ipa` open in this app

| Platform | How |
|---|---|
| Windows | **Nothing to do.** On every launch the app registers `.apk` / `.ipa` / `.xapk` / `.apks` / `.apkm` as candidate handlers (writes `HKCU`, no admin rights needed). The app then shows up under *Open with → Choose another app* |
| macOS | There is no "Default apps" pane. In Finder, right-click any `.apk` → *Get Info* → expand *Open with* → pick AppInfoTool → click *Change All…* |

> On Windows the app does **not** silently take over as the default handler: defaults are governed by
> `UserChoice`, which carries a hash the app cannot legally rewrite. Whether to make it the default is your call.

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
- **Pure-Dart parsers** — AXML, `resources.arsc`, binary plists, Mach-O, DEX, ELF, the APK Signing Block, `Assets.car` and **LZFSE** are all parsed/decoded in-house, so most fields are available without external tools
- **Optional external tools** — `apksigner` / `codesign` for signature verification, `adb` for install assistance, `aapt2` as an alternative parsing engine. When a tool is missing, the UI reports "cannot determine" rather than claiming the signature is invalid
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
  app_icon_extractor/ Headless icon extraction (zero Flutter dependency, AOT-compilable)
windows/thumbnail/  Shell thumbnail provider (in-proc COM DLL)
tool/               Build, icon generation, fixture generation and performance probes
test/fixtures/      Fixtures (all produced by public tools or real artifacts; never hand-assembled)
docs/               Audit reports and format research notes
```

The Android and iOS parsers do not depend on each other; they share only `analysis_model` and `archive_safety`.

### Quality and verification

- **1,549 root tests + 357 package tests** (`analysis_model` / `archive_safety` / `apk_parser` / `ipa_parser` / `app_icon_extractor`), `flutter analyze --fatal-infos --fatal-warnings` clean and `dart format` clean; CI runs the same gate on all three platforms
- **Expected values always come from an independent implementation**, never from this project's own parser:
  `aapt2` for the manifest and resources, `apksigner` / `codesign` for signatures, `assetutil` for iOS asset catalogs,
  `libcompression` (Apple's system library) for LZFSE, and `actool` (bundled with Xcode) to generate asset-catalog fixtures
- **Fixtures are real artifacts**, never hand-assembled bytes — a hand-built sample carries the same wrong assumptions as the parser, which makes the test self-confirming

## Known limitations

These are boundaries this project **has deliberately investigated and decided not to paper over**.
When they are hit, the tool says so plainly instead of producing something that looks like a conclusion.

| Limitation | Detail |
|---|---|
| `Assets.car` decodes about half | The rest are deepmap2 multi-plane variants (mode `0x02` / `0x03`). Four reconstruction approaches were probed against known-pixel samples and none held up, so they are not implemented |
| Asset names need the key index | Containers without a `KEYFORMAT` (older storage format) yield no asset names, only rendition names — the report says "this container has no key index" |
| `bvx1` / `bvxn` unsupported | No tool emits `bvx1`; `bvxn` (LZVN) appeared zero times across 951 real raster images. Both raise exceptions with stable error codes rather than guessing at an implementation |
| Static analysis cannot see runtime-loaded code | Anything loaded via `DexClassLoader` is not in the archive, so conclusions do not cover it. It lands in "limited coverage", never "checked" |
| Large packages are scanned within a budget | Dimensions that exceed the budget are marked `partial` **with the ratio** (e.g. "266 unique native libraries, 24 scanned"), never reported as "24/24 covered" |
| Signature verification depends on external tools | Without `apksigner` / `codesign` the result is "cannot determine", which is **not** the same as an invalid signature |
| 日本語 / 한국어 are incomplete | See "UI languages" above |

## Design principles

A few decisions that shape the whole project:

- **Never present "couldn't find it" as "nothing wrong"**. Missing fields are distinguished as `absent` / `wrongType` / `failed` / `unsupported`; in risk grading, `UNKNOWN` is kept apart from `P3`.
- **Don't guess**. Malformed input yields diagnostics plus whatever was successfully read — never an exception or a placeholder value.
- **Signature verdicts come only from trusted tools' explicit conclusions**. "Tool unavailable" is not "signature invalid".
- **Validate bounds before using untrusted input**. The archive layer enforces a decompression budget; parsers enforce depth limits and cycle detection.
- **"Runs but produces wrong output" is worse than "explicitly unsupported"**. Unsupported formats always raise a stable error code instead of a best-effort guess — an icon with the wrong colours is something the user cannot tell is wrong.

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
