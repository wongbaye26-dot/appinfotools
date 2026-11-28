# AppInfoTool 2.11.1 第四阶段验证记录

日期：2026-11-28
范围：第四阶段「验证与性能」中**本机可验证**的部分；需要真机/实机的项单列在「未验证项」。

本记录只写实测数字与命令，不做推断。所有数字来自同一台机器（Apple Silicon / macOS 26.2）、
同一批文件、同一段 harness。

## 1. 解析耗时与峰值内存：2.10.6 vs 2.11.1

### 方法

- 代码：`tool/bench/bench_parse_test.dart`（本仓库）。
- 对照组：`git worktree add /tmp/ait-2106 5c4db5a`（`chore(release): 2.10.6`），
  复制同一份 harness，`dart run slang` 生成缺失的 `lib/gen/strings.g.dart`。
- 夹具：`~/Downloads/217_0919155004.apk`（9.2 MB）、`~/Downloads/狐⤷狸⊻视⭏频⧙8-v3.20.apk`（9.7 MB）。
  两份都是真实第三方 APK，不是合成夹具。
- 口径：每文件热身 2 次、计时 7 次取中位数；走**内置解析器**，不安装 aapt2 / apksigner，
  避免外部进程把噪声带进来；峰值内存取 `ProcessInfo.maxRss`（进程级、单调）。
- 命令：

  ```bash
  FILES="…217.apk:…fox.apk"
  BENCH_FILES="$FILES" BENCH_OUT=/tmp/bench_x.json flutter test tool/bench/bench_parse_test.dart
  ```

### 结果

| 版本 | 文件 | 中位耗时 | 最快 | 最慢 | 进程峰值 RSS |
| --- | --- | --- | --- | --- | --- |
| 2.10.6 | 217_0919155004.apk | 181 ms | 176 ms | 187 ms | 313 MiB |
| 2.10.6 | 狐⤷狸⊻视⭏频⧙8-v3.20.apk | 238 ms | 186 ms | 268 ms | 316 MiB |
| 2.11.1 | 217_0919155004.apk | 183 ms | 179 ms | 249 ms | 306 MiB |
| 2.11.1 | 狐⤷狸⊻视⭏频⧙8-v3.20.apk | 241 ms | 185 ms | 267 ms | 328 MiB |

同一版本重复跑过 3 轮，单轮中位数波动约 ±3%，峰值 RSS 波动约 ±25 MiB
（flutter_tester 的 JIT 基线占大头，首轮普遍偏高）。上表是最后一轮。

### 结论与限制

- **耗时无回退**：中位数差 +2 ms / +3 ms，落在重复跑的波动范围内。
- **内存无回退（在噪声范围内）**：峰值差 −7 MiB / +12 MiB，与重复跑的波动同量级。
- 限制 1：RSS 是**含 JIT 的 flutter_tester 进程**峰值，不是发布包（AOT）的实际占用，
  不能直接当作「应用占用多少内存」对外说。
- 限制 2：只量了 2 份真实 APK，未覆盖超大包（>200 MB）、XAPK/APKS 组合包、
  AAB 与 IPA；本机没有对应的大样本。
- 限制 3：未测 UI 全链路（打开 → 切 Tab → 导出报告），只测解析函数本身。

## 2. ZIP 安全与 DEX 预算「不回退」

新增 `test/budget_guard_test.dart`（8 条断言），把散落在三个包里的阈值**钉住**：

| 断言 | 值 |
| --- | --- |
| `ZipBudgetLimits.maxSingleEntryCompressed` | 512 MiB |
| `ZipBudgetLimits.maxTotalCompressed` | 2 GiB |
| `ZipBudgetLimits.maxSessionOutputBytes` | 1 GiB |
| 产出上限 < 压缩总量上限 | 1 GiB < 2 GiB |
| `SdkInventoryScanner.maxDexBytes` | 64 MiB |
| `DexLibraryScanner.maxClasses` | 400 000 |
| `DexClueScanner.maxBytesPerDex` / `maxTotalBytes` / `maxStringKeep` | 8 MiB / 48 MiB / 200 |
| `AndroidLoadGraphScanner.defaultMaxEdges` / `maxStringsPerDex` | 5 000 / 500 000 |
| `ApkSealCheck.maxEntries` / `maxEntryBytes` | 64 / 8 MiB |
| `AndroidArtifactInventoryScanner.defaultMaxEntries` | 2 000 |
| 线索扫描总量 < 64 MiB，且库识别窗口 > 线索窗口 | 48 MiB < 64 MiB |

调大任何一条都必须同时改这份测试，否则 CI 红。

## 3. AOT 发布包内存（macOS，新增）

上面的抓取发生在 `flutter_tester`（JIT、带调试栈），与用户实际运行的 AOT 包不是一回事。
本节在**发布构建**上重新采样。

### 方法

- 脚本：`tool/bench/measure_release_rss.sh <App.app> <sample> [idle-seconds]`。
  用 `open -n` 启动、`open -a <App> <sample>` 触发 Finder open-file（与双击包等价），
  每 200 ms 采一次 `ps -o rss=`（共 100 次），输出 `idle_rss_kb / peak_rss_kb / delta_kb`；
  `delta` 即「打开这个包带来的增量」。
- 每次测量前 `pkill -f <CFBundleExecutable>`，并等到进程真的消失、且确认只剩 1 个实例，
  避免复用已解析状态或采到旧进程。
- 对照组：`git worktree add /tmp/ait-2106b 5c4db5a` 构建 2.10.6。
  **坑**：首次 `flutter build macos --release` 报
  `The setter 'state' isn't defined for the type 'PendingOpenRequest'` —— riverpod 的
  `*.g.dart` 未生成；先 `dart run build_runner build --delete-conflicting-outputs`（14 s）
  再构建成功（82.9 MB / 2.11.1 为 87.9 MB）。

### 结果（同机、同文件，各 3 次）

| 包 | 版本 | idle (MiB) | peak (MiB) | delta (MiB) | delta 中位 |
| --- | --- | --- | --- | --- | --- |
| 狐视频 10.09 MB | 2.10.6 | 148.1 | 218.6 | 63.9 / 65.3 / 73.8 | **65.3** |
| 狐视频 10.09 MB | 2.11.1 | 199.1 | 268.7 | 73.0 / 51.9 / 68.0 | **68.0** |
| F-Droid 11.90 MB | 2.10.6 | 146.7 | 256.4 | 100.4 / 106.0 / 103.6 | **103.6** |
| F-Droid 11.90 MB | 2.11.1 | 188.1 | 282.7 | 105.3 / 106.8 / 83.9 | **105.3** |

### 结论与限制

- **解析增量没有回退**：狐视频 +2.7 MiB、F-Droid +1.7 MiB，都在同版本自身 ±10 MiB 的
  波动范围内（三次测量里同版本极差 21–22 MiB）。
- **但 idle 基线抬高了约 40–50 MiB**（148→199、147→188 MiB）。这是真实差异，不是噪声；
  原因未隔离 —— 2.10.6 与 2.11.1 的界面与启动路径不同（V4 外壳、启动期加载的权限元数据
  与 LibChecker 规则），本轮没有逐项拆解，**列为本阶段观察项**，不写成「已定位」。
- 限制：只有 macOS AOT；Windows/Linux 发布包未测；样本只有 2 个（1 个第三方加固包 +
  1 个 F-Droid 包）；`ps` 的 RSS 含共享页，绝对值偏大，横向对比同机同口径才有意义。
- 原计划的第三个样本 `~/Downloads/217_0919155004.apk` 在测量期间被移出 Downloads
  （此前两次 delta 为 51.8 / 80.5 MiB），因此未进入最终表格。

## 4. 未验证项（本机无法完成）

| 项 | 原因 | 影响 |
| --- | --- | --- |
| iOS 真机安装 E2E | 本机无 `ideviceinstaller`、无 iOS 设备 | `.ipa` 安装链路只有单测与注入替身，真实 USB 安装未跑过 |
| Windows 实机验收 | 无 Windows 机器 | 只有 CI 构建 + 冒烟；缩略图、文件关联、安装器注册未实机验证 |
| Linux 实机验收 | 无 Linux 机器 | 只有 CI 构建 + AppImage 冒烟 |
| 真实样本矩阵 | `samples/` 为空 | 20 个真实样本测试 skip；`external-samples` job 在 CI 里只是「通过但跳过」 |
| macOS 公证 | 无 Developer ID 证书 | 发布包仍是 ad-hoc 签名 |
| 发布包（AOT）内存 | Windows/Linux 未测 | macOS AOT 已测（见第 3 节）；另发现 idle 基线抬高约 40–50 MiB，原因未隔离 |

## 5. 本阶段判定

- 本地可验证部分：**PASS**（耗时与解析增量在噪声范围内无回退，预算阈值有守卫测试；
  AOT idle 基线抬高 40–50 MiB 已记录为观察项，不影响「解析未回退」的结论）。
- 整阶段：**PARTIAL** —— 真机与实机验收项仍未完成，必须在最终验收文档里作为
  未解决风险列出，不能因为「CI 绿」就写成已完成。
