# Android 平台元数据

三份只读数据，用于「应用概览 / 权限 / 语言」标签页；不含应用自身信息。

| 文件 | 内容 | 条目 |
| --- | --- | --- |
| `protection.json` | 权限的 AOSP `protectionLevel` 原始位掩码 | 1102 |
| `autonyms.json` | 语言代码 → 该语言的自称（`zh-CN` → `中文`） | 459 |
| `text.<locale>.json` | 权限标题/说明、硬件特性说明、语言/地区/文字名称 | 每种 143 权限 + 118 特性 + 928/311/42 名称 |

`protection.json` 的 `source` 是生成时使用的 Android 平台版本（`android-37.0`）。

## 来源与许可

- 权限保护级别：[AOSP `frameworks/base/core/res/AndroidManifest.xml`](https://android.googlesource.com/platform/frameworks/base/)（Apache-2.0）。
- 权限标题/说明、语言名称、硬件特性说明：Android SDK 平台资源与 [ICU](https://unicode-org.github.io/icu/) 数据（Apache-2.0 / Unicode License）。
- 数据结构与参考实现 [ApkInfoPlus](https://github.com/huanfeng/ApkInfoPlus)（MIT，同作者）一致。

## 重新生成

数据由参考实现的 `scripts/gen-android-data.py` 生成后按本目录结构落盘；
若平台版本升级，用同一脚本重新导出并更新上表条目数。

## 注意

- `protection.json` 的低 4 位才是「基础级别」（1 dangerous、2 signature、
  3 signatureOrSystem、4 internal、其余 normal），高位是标志位，不能当枚举。
- 只有 143 项权限带官方文案；其余权限是第三方/厂商自定义权限，界面应显示
  「无官方说明」而不是「自定义权限」。
