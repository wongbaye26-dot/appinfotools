# AppInfoTool 2.11.0 发布后审计（2026-11-28）

- 审计对象：`wongbaye26-dot/appinfotools` @ `cfcbaa5`，tag `v2.11.0`（已发布）
- 审计范围：功能完整度、工程质量、发布与流程、安全与隐私、文档一致性
- 方法：仓库静态检查 + 全量门禁实跑 + CI 记录核对 + 发布页产物核对
- 结论摘要：**功能 92/100，工程质量 88/100，交付就绪 72/100**

---

## 1. 硬指标（本次实测）

| 项目 | 数值 | 证据 |
| --- | --- | --- |
| 版本 | `2.11.0` | `pubspec.yaml:7` |
| 主分支 | `main` 停在 `2.10.6`（`5c4db5a`，2026-11-26） | `git log origin/main -1` |
| 领先 main | **38 个提交**，无 PR | `git rev-list --count origin/main..HEAD` |
| tag | `v2.11.0`（重打 3 次后指向 `cfcbaa5`） | `git tag --list 'v2.11*'` |
| 发布 | Release v2.11.0，5 个产物，非预发布 | GitHub Releases API |
| 代码量 | `lib/` 144 文件 / 80,487 行；`packages/` 176 文件 / 55,158 行 | `find` + `wc -l` |
| 测试文件 | 244 个 `*_test.dart` | `find` |
| 根测试 | **2005 通过 / 20 跳过** | `flutter test` |
| 包测试 | 777 通过 / 1 跳过（148+306+25+40+258） | 各包 `flutter test` |
| analyze | 0 issue | `flutter analyze` |
| format | 0 文件需改（521 文件） | `dart format --set-exit-if-changed` |
| i18n | en / zh-CN / zh-HK / zh-TW 各 **1689** 键；ja / ko 各 **1543** 键 | 键集对比 |
| 资源 | `assets/` 2.7 MB；macOS 包 87.7 MB | `du` / 构建日志 |
| 发布物 | Linux AppImage 12.6 MB；macOS DMG 35.4 MB；Windows Setup 15.7 MB；Windows ZIP 17.9 MB；缩略图自检 3.1 MB | Release API |

CI（`46123792627`，tag 运行）：Quality、macOS、Windows、Linux、External samples、create-release **全部 success**；`publish-scoop` / `publish-homebrew` 按设计只在 `huanfeng/ApkInfoTool` 跑，fork 永远 skipped（`.github/workflows/build.yml:1153`、`:1211`）。

---

## 2. 结论：可以发布，但有两处「自己给自己开了例外」

### P0-1 主分支没有这次发布的内容

- 事实：`origin/main` 仍是 2.10.6；2.11.0 从 `feature/2.11.0` 直接发版，38 个提交、无 PR（open PR = 0）。
- 后果：`main` 的 CI 从未验证 2.11.0；下一个 hotfix 或 2.11.x 若从 `main` 切，会丢掉整版功能；GitHub 的默认分支页面与实际发布物不一致。
- 建议：开 PR 把 `feature/2.11.0` 合并进 `main`（squash 或 merge 都行），再从 `main` 重打 `v2.11.0`（允许强推，产物无需变）或发 2.11.1。

### P0-2 发布绕过了仓库自己写的 NO-GO 门禁

- 事实：`docs/audit/APPINFOTOOL_2.11.0_RELEASE_ACCEPTANCE.md:154` 与 `:161` 明确写着「发布结论仍为 **NO-GO**：Windows/Linux 实机、CI 样本门禁、全量手工验收仍未完成」。
- 本次发版通过新增的 `.github/allow-no-samples` 豁免了 `external-samples`（`.github/workflows/build.yml:200`），Release 正文由 `:1103` 自动标注「真实样本未验证」。
- 评价：豁免本身透明、可回滚、有警告，**但档案里仍写着 NO-GO**，两者矛盾；且豁免文件留在仓库里，后续所有 tag 默认继续跳过样本门禁。
- 建议：
  1. 更新验收文档，写明「2.11.0 在样本未验证下发布，理由与豁免机制」；
  2. 样本配好后删除 `.github/allow-no-samples`，用 2.11.1 做一次带真实样本的正式验收；
  3. 在此之前，把「样本未验证」当成已知风险而不是已解决项。

---

## 3. 功能完整度（92/100）

### 已完整

| 模块 | 状态 | 说明 |
| --- | --- | --- |
| Android 解析 | 完整 | APK/XAPK/APKM/APKS/AAB；清单、资源、DEX、原生库、分包、OBB |
| iOS 解析 | 完整 | IPA 容器、Info.plist、框架、Assets.car、代码签名材料 |
| 安全审计 | 完整 | 40 个 Android 规则 id + 44 个 iOS 规则 id；P0–P3/INFO/UNKNOWN |
| 权限说明 | 完整 | 1102 条 protectionLevel + 24 标志位 + 33 条语义规则，六语言 |
| 签名 | 读完整 / 验受限 | v1 PKCS#7 + v2/v3/v3.1；本地读证书 11 字段；装 apksigner 才真验签 |
| 库识别 | 完整 | LibChecker 3053 条/123 正则，19 条上游 fixture 全过；支持离线导入 |
| 概览/清单/对比/安装 | 完整 | V4 界面；安装支持 Android（adb）与 iOS（libimobiledevice） |
| 导出 | 完整 | Markdown / JSON / HTML，schema v11（权限分级、库识别、证书字段） |

### 缺口（按影响排序）

1. **AAB 只读一半**：组件、权限、`uses-feature`、`debuggable`、compileSdk 未解析（`_getAabInfo` 路径），AAB 页已隐藏签名/库识别。属诚实留空，但「Android 解析完整」这句话对 AAB 不成立。
2. **iOS 安装无真机 E2E**：`lib/utils/ios_install_service.dart` 只跑了单测（12 条），真实 `ideviceinstaller` 路径从未验证；不支持无线安装、卸载、进度。
3. **IPA 在安装页没有元数据**：`lib/pages/install_page.dart` 对 `.ipa` 跳过解析，文件条只有文件名与大小，没有应用名/版本/图标。
4. **`Assets.car` deepmap2 约 50% 出图率**（README 已注明不解）。
5. **对比页无 DEX 数量行**（保留集合差异导致比原型长，有测试依赖该节）。

---

## 4. 工程质量（88/100）

### 好

- 门禁齐：format / analyze / 根测试 / 整包 `flutter build bundle` / 包级 analyze+test / 平台构建；fork 的 CI 跑得比多数个人项目严。
- 测试密度：244 个测试文件、2782 个通过用例；`test/support/sample_directory.dart` 支持样本目录自动探测，跳过原因会列出探测过的路径。
- 诚实降级：`FieldValue` 三态（extracted/absent/unsupported/failed）贯穿到 UI 与导出；AAB、签名、iOS 能力都是「读不到就说读不到」。
- 依赖克制：只有 `flutter_svg` 是这轮新增；LibChecker 数据、权限元数据、图标全部离线内置。

### 待改

1. **ja / ko 缺 146 个键**（`analysis_diagnostic.*` 为主）：`test/i18n_coverage_test.dart:358` 已承认「security / report / field_diagnostic / analysis_diagnostic 等组仍未补齐」。ja/ko 用户会在诊断面板看到英文。
2. **Windows 产物未签名**：workflow 没有 signtool 步骤，SmartScreen 会拦；macOS 只有 ad-hoc（`security find-identity` 为 0 张 Developer ID），公证无解。
3. **性能没有基准**：与 Rust 版对比只是架构推断，没有同包 A/B 数据；`parse_task.dart` 的 Isolate 上限、DEX 扫描的 96 MiB 预算都缺压测。
4. **无死代码/复杂度门禁**：`dart analyze --fatal-infos` 有，但没有圈复杂度或包依赖方向检查。

---

## 5. 发布与流程（交付就绪 72/100）

| 项 | 状态 | 说明 |
| --- | --- | --- |
| Release 产物 | ✅ | 5 个文件齐全，下载正常 |
| Release 说明 | ✅ | CHANGELOG 段落 + git log 分类 + 豁免警告 |
| 版本号一致 | ✅ | pubspec / tag / Release 均为 2.11.0 |
| 主分支同步 | ❌ | main 落后 38 个提交（P0-1） |
| 样本门禁 | ⚠️ | 被文件豁免，NO-GO 档案未更新（P0-2） |
| Windows/Linux 实机 | ❌ | 只有 CI 构建 + 启动冒烟，无人工验收 |
| macOS 公证 | ❌ | 外部阻塞：无证书 |
| Homebrew/Scoop | — | fork 设计上跳过，需在 README 说明，避免用户等不到 |

---

## 6. 安全与隐私

- 分析全程本地；唯一网络出口是「设置 → 工具路径」显式下载 aapt2/apksigner（`lib/utils/tool_downloader.dart:48-62`，源为 dl.google.com / GitHub / Adoptium）与 `url_launcher` 打开发行页（3 处）。README 说了外部工具可选，但没写「可以应用内下载」，建议补一句。
- 报告导出含证书公钥指纹等公开信息，不含用户私钥；`securityOnly` 模式不输出库识别，语义正确。
- **本轮对话里出现过两个密钥**（`sk-…`、`ghp_…`，均已失效）。虽然不在仓库里，仍建议在各自平台吊销，并检查本机 shell history（`~/.zsh_history` 里有这条 `ghp_`）。

---

## 7. 文档一致性

| 文档 | 问题 |
| --- | --- |
| `docs/audit/2026-11-28-functional-audit.md:84` | 仍写「IPA 安装…尚未实现」，本轮已实现 |
| `docs/audit/APPINFOTOOL_2.11.0_RELEASE_ACCEPTANCE.md` | 结论 NO-GO，与实际发布冲突 |
| `docs/audit/APPINFOTOOL_2.11.0_STAGE*.md` | 对应 11-27 的旧计划（6 个 stage），与今天发布的 38 个提交不是同一批内容，容易误读 |
| README | 规则数、图标、schema 已在 P2-1 校正；「网络」一节未提应用内工具下载 |

---

## 8. 建议顺序（按投入产出）

1. **合并 + 重立基线（30 分钟）**：PR 合并 `feature/2.11.0` → `main`，从 `main` 重打 tag 或发 2.11.1。解决 P0-1。
2. **更新验收档案（30 分钟）**：把 NO-GO 改成「有条件发布」，写明豁免与补测计划。解决 P0-2 的一半。
3. **真实样本进 CI（1–2 小时，需样本）**：配置 `APPINFOTOOL_SAMPLES` 或 archive URL + manifest，删豁免文件，跑 2.11.1 验收。解决 P0-2 的另一半。
4. **ja/ko 补 146 键（半天）**：诊断组优先，用户可见。
5. **IPA 安装页接解析（半天）**：应用名/版本/图标，成本低、观感提升明显。
6. **AAB 组件/权限（1–2 天）**：把「AAB 只读一半」补成完整。
7. **签名与真机（外部依赖）**：Windows 代码签名证书、macOS Developer ID、Windows/Linux 实机。
8. **性能基准（1 天）**：同一批 APK/IPA 对比 2.10.6 与 2.11.0，确认 Isolate/DEX 预算没有退化。

---

## 附录：本次复现命令

```bash
flutter analyze
dart format --output=none --set-exit-if-changed lib test packages tool
flutter test
for p in packages/*/; do (cd "$p" && flutter test); done
git rev-list --count origin/main..HEAD
curl -s https://api.github.com/repos/wongbaye26-dot/appinfotools/releases/tags/v2.11.0
```
