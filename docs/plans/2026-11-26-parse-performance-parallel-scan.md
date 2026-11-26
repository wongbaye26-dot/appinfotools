# 打开一个包的等待时间：并行扫描与工具路径缓存

> **日期**：2026-11-26｜**环境**：macOS arm64（M 系列），Flutter 3.47.7
> **样本**：`217_0919155004.apk`（9.2 MB，单个 16.9 MB DEX）、
> `狐⤷狸⊻视⭏频⧙8-v3.20.apk`（9.6 MB）、
> 68.8 MB 历史样本（`2026-11-04-crypto-theft-performance-baseline.md` 的基线）
> **工具**：`tool/perf_probe_getapk_test.dart`（新增）、
> `tool/perf_probe_apk_test.dart`（既有）
>
> **⚠️ 本机没有 Windows**：下面的数字全部来自 macOS。Windows 上的改动是
> **按机制推断**的（进程启动、`PATH` 探测、文件 IO 都更贵），没有实测数字。
> 要验证请看第 5 节。

---

## 1. 问题

用户反馈：同一个包在 macOS 上打开很快，Windows 上明显慢。

先测量再改。9.2 MB 样本上 `getApkInfo` 全链路 **374 ms**，其中 worker 内部
**294 ms**，其余是图标渲染（28 ms）与 isolate 启动 + 结果传输（52 ms）。

worker 内部原本只有 `total` 一个数，无法定位。补上分段计时后：

```
[PERF] getApkInfo(builtin): total=374ms | icon=28ms | worker=294ms
  [open=17 parse=36 dex=44 resources=12 facts=6 methodScan=36 seal=72 audit=70]
  | spawn+transfer=52ms
```

其中 `audit=70` 里还藏着**第二遍** DEX 字符串扫描（`audit` 内部自己算）。

---

## 2. 改了什么

### 2.1 三段独立扫描并行（主要改动）

`parse_task.dart` 的 worker 里，这三段输入相同、输出互不依赖：

| 段 | 输入 | 输出 | 68.8 MB 样本耗时 |
|---|---|---|---:|
| 方法扫描 | DEX 字节 | `DexMethodScanResult` | 605.8 ms |
| 字符串线索扫描 | DEX 字节 | `DexScanResult` | 682.8 ms |
| v2/v3 内容摘要 | 文件路径 + 签名块 | `SealCheck` | 461 ms |

串行合计约 **1.75 s**，是「打开一个包要等多久」里最大的一块。并行后由
`Future.wait` 收口，再一起交给 `audit`（新增 `clueScan` 参数）。

**语义完全不变**：同一批函数、同样的参数、同样的返回值，只是换个 isolate 跑。
`audit(clueScan: …)` 与内部自算的结论由测试逐条比对
（`test/android_security_audit_test.dart` 的「预扫描结果复用」组）。

### 2.2 退回串行的门槛

```
parallelIsolates = numberOfProcessors >= 3 && DEX 总字节 >= 4 MiB
```

理由：每个子 isolate 都要**复制一份 DEX 字节**（跨 isolate 传 `Uint8List`
是复制不是共享），再付一次启动开销。9.2 MB 样本实测净收益只有 40 ms，
再小就变成负的。

### 2.3 工具路径缓存

`CommandTools.findAapt2Path()` 此前**每次调用**都走一遍
`ToolPaths.findSystemTool` → `findInPath`：`PATH` 的每个目录 × `PATHEXT`
的每个扩展名各一次**同步** `File.existsSync()`。40 个目录 × 6 个扩展 =
240 次 stat。

而 `ApkInfo.renderIcon` 是**为每个图标候选调一次**
（`apk_info.dart` 的 `renderIcon` 里 `CommandTools.findAapt2Path()` 在循环内）。
一个包十来个候选 = 十几次全扫。

macOS 上单次 stat 是微秒级，这件事看不出来；Windows 上单次就到毫秒级，
而 `PATH` 里只要有一条**连不通的网络路径**（企业环境常见），每次探测都可能
卡上数秒 —— 这条路径会把它乘十几倍。

改法：
- 按 `工具名 | source | manualPath | downloadDir | appSupportDir` 缓存；
- `builtin` 档且内置工具确实存在时**不探测系统环境**（结论本来就是内置路径）；
- 下载完成后由 `downloadDependencies` 调 `invalidateCache()`
  （文件系统变化不在键里）。

`appSupportDir` 进键是为了处理 `ToolPaths.init()` 之前/之后数据目录会变的
情况 —— 否则初始化前的解析结果会被一直沿用。

### 2.4 跨 isolate 的隐患

`Isolate.run` 的闭包会连同**所在作用域**一起被发送。worker 的作用域里有
`ApkReader`（持归档与 `RandomAccessFile`），内联闭包写法会抛
`Illegal argument in isolate message`。

这个错误是在 `perf_probe_apk_test.dart` 里**真实踩到**的（那里的作用域还有
`e2eReader`）。并行段因此改为**顶层函数**，作用域里只有参数。
生产代码当时只是恰好没被共享上下文波及 —— 这种「恰好」不能留。

---

## 3. 实测（macOS arm64）

样本 `217_0919155004.apk`（9.2 MB，单 DEX 16.9 MB），连跑三次：

| | 改前 | 改后 |
|---|---:|---:|
| `getApkInfo` 全链路 | 374 ms | **335 / 332 / 373 ms** |
| worker | 294 ms | 259 / 255 / 296 ms |
| 方法扫描 + 封签 + 字符串扫描 | 130 ms（串行） | **85–95 ms**（并行） |
| `audit` | 70 ms | 51 ms（字符串扫描已移出） |

`scan` 这一段的墙钟低于三段之和，但也没有到「最慢那段」—— 因为三个子
isolate 的**启动开销**（约 30 ms）算在里面。

> 小包上的收益有限是预期内的：三段本来就只有 130 ms，isolate 启动吃掉一半。
> 大包（68.8 MB 样本）上三段合计 1.75 s，同一套机制才有量级上的差别 ——
> 但那个样本本机已不在，**没有复测数字**。

峰值 RSS 从 241 MB 升到 273 MB（多一份 DEX 的复制）。DEX 扫描预算上限
48 MiB，因此最坏情况约 +100 MB。

---

## 4. 没做的事（以及为什么）

- **没有动三种哈希**：`computeFileHashes` 用 3 个 isolate 各读一遍文件，
  实测 40.5 MB 上并行 272 ms vs 串行 622 ms（`file_hash.dart` 有记录）。
  它是 CPU 密集而非 IO 密集，Windows 上并行大概率仍然更快。
  **没有 Windows 实测，不改。**
- **没有把 `arscResources` 的跨 isolate 传输优化掉**：`spawn+transfer` 在
  9.2 MB 样本上是 52 ms，其中包含 5081 条资源对象的深拷贝。要省掉它得把
  图标渲染搬进 worker（`dart:ui` 在后台 isolate 的可用性各平台不一致），
  风险大于收益。
- **没有把封签与审计并行**：`audit` 需要 `seal` 作为输入（`seal:` 参数），
  顺序依赖是真实的，不是实现上的顺手。
- **没有按 DEX 拆更细**：`DexClueScanner` / `DexMethodScanner` 的累加器是
  跨 DEX 共享的（域名上限、地址上限、样本去重、预算顺序），按 DEX 拆开
  合并会改变边界语义。误报比漏报更糟，不动。

---

## 5. 怎么在 Windows 上验证（下一步）

1. 设置页打开「调试日志」；
2. 打开一个真实的、足够大的 APK（≥ 50 MB，多 DEX 更能体现并行收益）；
3. 日志文件在 `<数据目录>/debug.log`，把 `[PERF] getApkInfo(builtin)` 那一行
   发出来。

这一行同时给出 total / icon / worker 分段 / spawn+transfer，可以直接回答：

- `spawn+transfer` 大 → isolate 启动或结果传输（Windows 上启动更贵）；
- `dex` / `parse` 大 → 解压（`archive` 的纯 Dart inflate，跨平台一样慢）；
- `scan` 大且 `parallelIsolates=0` → 核数或 DEX 总量没到门槛；
- `audit` 大 → 规则层本身；
- `icon` 大 → `dart:ui` 渲染（Windows 上的光栅化路径与 Metal 不同）；
- `total` 远大于 `worker + icon` → 还有 worker 之外的环节（哈希 / 签名）。

## 6. 复现

```bash
cd /Users/wangbaye/Projects/AppInfoTool
export PATH="$HOME/development/flutter/bin:$PATH"
# 用户实际等待（含图标、哈希、封签）
NO_PROXY=127.0.0.1,localhost,::1 PERF_APK=/path/to/big.apk \
  flutter test tool/perf_probe_getapk_test.dart
# worker 内部分段（引擎各段单独计时）
NO_PROXY=127.0.0.1,localhost,::1 PERF_APK=/path/to/big.apk \
  flutter test tool/perf_probe_apk_test.dart
```
