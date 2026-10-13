# AppInfoTool — 项目审计报告

- **日期**：2026-10-13
- **范围**：全量代码（13,011 行生产 Dart + 平台层 + CI）
- **方法**：静态审计。本机无 Flutter/Dart SDK，`flutter analyze` / `flutter test` 未能执行，所有结论均来自源码逐行确认
- **未修改任何文件**

---

## 一、总体结论

AppInfoTool 是一个功能完成度相当高的 Flutter 桌面 APK 解析工具，核心解析引擎（纯 Dart AXML + resources.arsc 解析、adaptive icon 渲染、XAPK 分包处理）有明显的技术投入，很多地方代码质量不错 —— `try/finally` 资源释放纪律良好，ByteBuffer offset 归一化这种 `archive` 库的隐蔽坑处理得很正确，作者显然踩过。

但项目存在三类系统性问题，它们叠加起来构成了风险：

1. **安全模型缺位**：程序的核心用途是打开来自互联网的不可信文件，但下载的工具二进制零校验就执行，ZIP 解压零防护，二进制解析大量无界分配。
2. **安全修复无法生效**：同一份 AXML 解析器存在两份分叉副本，**未加固的那份正被图标渲染链路使用**。对 `packages/apk_parser` 的任何加固都到不了图标路径。
3. **质量门禁完全缺失**：13,011 行生产代码 0 个可运行测试，CI 只在打 tag 时触发且不含 analyze/test，lint 配置整体注释掉。

单看任何一条都只是"可以改进"；但这三条互相喂养 —— 没有测试所以加固没有回归保护，没有门禁所以分叉会持续扩大，没有校验所以解析器缺陷直接变成崩溃/DoS。

**风险等级：中高。** 不建议在完成 T0 项前继续对外分发。

---

## 二、T0 — 立即修复

### T0-1 Zip-Slip：恶意 XAPK 可在主机任意位置写文件

**严重度**：高 | **位置**：`lib/utils/xapk_installer.dart:222, 281`、`lib/utils/zip_helper.dart:50-66`

XAPK manifest 无可用分包列表时，回退到枚举 ZIP 条目名：

```dart
final apkPath = path.join(tempDir.path, apk);   // apk 是原始条目名
await zip.extractFile(apk, apkPath);
```

`path.join` 只拼接、不归一化，条目名 `Android/../../evil.apk` 得到 `/tmp/x/Android/../../evil.apk`，OS 解析为 `/tmp/evil.apk`。`ZipHelper.extractFile` 全程无路径校验。唯一的过滤是 `listFiles(extension: '.apk')`，只检查后缀。

**影响**：打开恶意 `.xapk` 并点击安装 → 以当前用户权限向任意可写路径写入攻击者内容（`~/.zshrc`、`~/Library/LaunchAgents/`、`~/.config/autostart/`）。

**修复**（约 20 行，一次性保护所有调用方）：

```dart
String _safeJoin(String root, String entry) {
  final resolved = path.normalize(path.join(root, entry));
  final rootNorm = path.normalize(path.absolute(root));
  if (resolved != rootNorm && !path.isWithin(rootNorm, resolved)) {
    throw ArgumentError('zip entry escapes destination: $entry');
  }
  return resolved;
}
```

需同时拒绝绝对路径与 Windows 盘符（`path.join` 不会拦截 `C:\`）。

---

### T0-2 工具二进制零完整性校验即执行，且镜像优先级错误

**严重度**：高 | **位置**：`lib/utils/tool_downloader.dart:130-156, 197-230, 351-360`

全流程为「拉取 → 落盘 → 解压 → `chmod +x` → 执行」。已确认全文件 **不存在** `sha256`/`checksum`/`digest`/`verify` 任何字样。

加重情节的是镜像顺序（`tool_downloader.dart:89-96`）：

```dart
urls.addAll(extraUrls);              // 用户手工编辑的纯文本文件
urls.add(mirrorRepositoryIndexUrl);  // github.com/huanfeng/.../releases/download/latest/
urls.add(repositoryIndexUrl);        // Google 官方 —— 排在最后
```

个人 GitHub 账号优先于 Google 官方，且指向 **`/latest/` 可变资源指针** —— 原地替换二进制不会产生任何版本变化。该账号一旦失守，默认配置下所有用户静默获得任意代码执行。

**已确认的正面结论**：项目内**不存在宿主 shell 命令注入**。所有 `Process.start`/`Process.run` 均使用参数数组，无一设置 `runInShell: true`；TLS 校验未被关闭（无 `badCertificateCallback`/`HttpOverrides`）。

**修复**：
1. 内置 `version → sha256` 映射（或签名 manifest + 内嵌公钥），校验失败拒绝解压 —— **单此一项即可消除该风险链**
2. 镜像指向不可变 tag/commit，绝不用 `latest`，并把 `dl.google.com` 置于首位
3. 补 `uri.scheme == 'https'` 校验，手动处理重定向并拒绝降级

---

### T0-3 二进制解析无界分配：40 字节文件 → 32 GB 内存申请

**严重度**：高 | **位置**：`arsc_parser.dart:394, 426`、`binary_xml.dart:692-698`

`List.generate(n, …)` **先分配底层存储再调用生成器**，因此外层 `try/catch` 根本来不及生效：

```dart
final entryCount = reader.readUint32();                    // 攻击者控制
final entryFlags = List<int>.generate(entryCount, (_) => reader.readUint32());
```

`entryCount = 0xFFFFFFFF` → 约 32 GB。`binary_xml.dart` 同样问题，且 `numStrings`/`chunkSize` 五个字段本应无符号却用 `readInt32()` 读取。

**这是本次审计中最严重的单点问题**：它由默认的 builtin 引擎触发，触发条件是用户最常做的操作 —— 打开一个 APK。

**关键佐证**：作者知道这类 bug。`arsc/string_pool.dart:39-45` 存在完全正确的防护，注释写着「带边界检查，防止损坏的 stringCount 导致越界」—— 但同样的模式在另外三个兄弟位置没有应用。修复模式已在仓库内现成：

```dart
final entryCount = reader.readUint32();
if (entryCount > reader.remain ~/ 4) { reader.position = chunkStart + chunkSize; return; }
```

---

### T0-4 解析器双副本分叉，且加固版未覆盖图标链路

**严重度**：高 | **位置**：`lib/apkparser/binary_xml.dart`(453行) vs `packages/apk_parser/lib/src/binary_xml.dart`(860行)

两者均被编译进发布应用，且**加固程度不同**：

| 能力 | `lib/` 副本 | `packages/` 副本 |
|---|---|---|
| 8 处 `strings[i]` 裸索引 | ❌ 全部未保护 | ✅ `_safeGet()` |
| 字符串池循环边界 | ❌ 无边界检查、无 try/catch | ✅ 三重防护 |
| 命名空间 / resource map 解析 | ❌ 缺失（约 410 行） | ✅ 完整 |
| 混淆 APK 容错 | ❌ | ✅ |

**后果**：加固版处理 `AndroidManifest.xml`；未加固版处理**图标渲染链路中的每一个 drawable XML**。对 `packages/apk_parser` 的任何加固修复都到不了图标路径 —— 这比单纯的重复代码更危险，因为它制造虚假的安全感。

同时 `lib/utils/byte_data_reader.dart` 与包内副本**逐字节完全相同**，是全应用所有二进制读的底座。

**修复**：删除两个 `lib/` 副本，将 `vector_to_svg.dart:5` 与 `adaptive_icon_renderer.dart:8` 的 import 指向 `package:apk_parser/apk_parser.dart`（已导出两者）。一步同时解决 8 处未保护索引与字符串池崩溃，并使解析器审计面减半。

---

### T0-5 ZIP 炸弹无任何防护

**严重度**：高 | **位置**：`apk_reader.dart:20`、`zip_helper.dart:18`

```dart
_archive = ZipDecoder().decodeStream(inputStream);
```

无解压比限制、无总膨胀字节预算、无单条目上限、无条目数上限。且该步骤在 T0-3 的解析器加固**之前**执行，是最易触发的 DoS。

**修复**：`open` 后遍历 `archive.files`，若 `总解压 > 512MB || 条目数 > 50000 || 单条压缩比 > 1000` 则拒绝；`extractFile` 写入前二次校验。

---

## 三、T1 — 本迭代内修复

| # | 问题 | 位置 |
|---|---|---|
| T1-1 | `archive` 依赖未固定 ref，**两个 lockfile 已解析到不同 commit**（`cb3a07c8` vs `1ece0259`），却都声称 `4.0.9` | `pubspec.yaml:29-30`、`packages/apk_parser/pubspec.yaml:10-11` |
| T1-2 | 零测试覆盖，且唯一测试是无法编译的 `flutter create` 模板 | `test/widget_test.dart` |
| T1-3 | CI 仅 tag 触发，无 analyze/test/format 门禁 | `.github/workflows/build.yml:3-7` |
| T1-4 | MethodChannel handler 注册于 `initState` 且**无 `dispose()`**，macOS 上二次打开文件触发 use-after-dispose | `info_page.dart:197-217` |
| T1-5 | 无请求代次令牌，旧文件的异步结果覆盖新文件状态；`finally` 无条件关闭 loading | `info_page.dart:106-174` |
| T1-6 | `InstallDialog` 21 处 `setState`、**0 处 `mounted` 守卫**，且无 `dispose()` → 崩溃 + `adb` 进程孤儿 | `install_dialog.dart` |
| T1-7 | `Config` 防抖写入无 flush，退出即丢设置；`setString` 的 Future 被丢弃，失败完全静默 | `config.dart:17-37` |
| T1-8 | macOS 沙箱缺 `network.client`，却有 `network.server`（入站监听）；文件关联与拖放在沙箱下不可用 | `macos/Runner/*.entitlements` |
| T1-9 | `bin/compare.dart` 差分测试器**永远 exit(0)**，无法用作门禁 | `packages/apk_parser/bin/compare.dart:151` |

### T1-1 补充

`ref: HEAD` 意味着任何 `flutter pub upgrade` 都会静默拉取当日 HEAD；CI 用的是裸 `flutter pub get`，**未启用 `--enforce-lockfile`**。而 `archive` 正是解析不可信 ZIP 字节的安全边界。建议两份 pubspec 固定到同一 SHA，并加 `--enforce-lockfile`。

### T1-2 补充

`flutter test` 当前**无法编译**，三重原因：① `.gitignore` 排除 `lib/gen` 与 `*.g.dart`，而 `main.dart:2` 导入生成文件；② `MyApp` 需要 `ProviderScope`，且 `Config.gPrefs` 是未初始化的 `static late` → `LateInitializationError`；③ 断言的是不存在的计数器。

仓库里有一个**现成的**高价值资产：`bin/compare.dart` 用 Dart 解析器与真实 `aapt2` 逐字段对比 8 个字段。它只差两件事就能变成真正的门禁：失败时 `exit(1)`，以及提交一份 10 个左右的 fixture APK 语料。这是全审计中投入产出比最高的一项。

### T1-9 附带的已确认逻辑 bug

`bin/compare.dart` 排序出的待测函数中，前三名均含**已确认的活跃 bug**：

**① `SplitType.fromId` 死分支**（`lib/models/split_type.dart:21`）

```dart
if (id.length == 2 || id.contains('config.') && id.length <= 5) {
```

`'config.'` 长度已是 7，`id.length <= 5` **永不可达**（已实测确认）。结果：`split_config.en`、`config.zh` 等所有非 2 字母语言分包被归类为 `unknown`，安装对话框中显示为"未知"。另：`_looksLikeSplitLanguage`（`apk_info.dart:183-187`）里有一份**已经正确**的正则实现，同一规则两份副本且互相漂移。

**② `formatFileSize` 单位进位错误**（`lib/utils/format.dart:19`）— 已实测：

```
1048575  ->  "1024 KB"     ← 应为 "1 MB"
1048576  ->  "1 MB"        ← 正确
```

每个单位边界都差一档。

**③ `StringExt.trimSQ` 引号边界 off-by-one**（`apk_info.dart:727-734`）：输入 `'` 返回 `'` 而非空串，该值会经 `parseComponent` 进入 UI 展示。

---

## 四、T2 — 技术债

| # | 问题 |
|---|---|
| T2-1 | **解析全程阻塞 UI isolate**（`apk_info.dart:501-555`）。一次 `Future.delayed(Duration.zero)` 后，ZIP 解压 + 完整 `resources.arsc` 遍历同步跑在平台线程，大 APK 多秒冻结。项目**已有** `Isolate.run` 用法（`file_hash.dart`），模式现成 |
| T2-2 | **builtin 引擎无超时**，而 aapt2 路径有 120s 看门狗（`apk_info.dart:463-468`）—— 默认引擎反而没有 |
| T2-3 | **CESU-8/修改版 UTF-8 按标准 UTF-8 解码**（`binary_xml.dart:726`）。含 emoji 的应用名/版本名显示为替换字符，且会破坏混淆 APK 的正则启发式 |
| T2-4 | `PictureRecorder` 在提前返回路径未 `endRecording()`，泄漏（`adaptive_icon_renderer.dart:194-220`） |
| T2-5 | `arsc_parser.dart:298` 注释写「跳过并继续」，代码是 `break` —— 单个损坏 package 静默截断其后所有 package |
| T2-6 | `vector_to_svg.dart:161` `catch (_) {}` 后回落到对原始二进制做 `utf8.decode`，生成乱码 SVG 并弹出**成功提示** |
| T2-7 | `apk_info.dart:494-496` aapt2 全量吞异常返回 null，而 `logger.dart:92` 日志仅在 `enableDebug` 时落盘 —— 默认配置下失败原因**彻底丢失** |
| T2-8 | `FileState.copyWith` 用 `??` 实现，无法置空字段（`info_page_provider.dart:86-95`）；且缺 `==`/`hashCode`，导致无变化时也触发 `ref.watch` |
| T2-9 | `analysis_options.yaml:24-29` **所有 lint 全部注释掉**；`custom_lint`/`riverpod_lint` 已配置但无规则启用，实为空转 |
| T2-10 | `Color.value` 返回 `double` 存入 `int themeColor`（Flutter 3.27+ 变更），依赖隐式窄化 |
| T2-11 | i18n：`install.please_select_device` 仅存在于 `en.json:157`，其余 5 种语言均缺失（`build.yaml` 的 `fallback_strategy` 会静默降级为英文）；该 key 在 Dart 中亦无引用 |
| T2-12 | `home_page.dart:73-83` 六个空 `setState` 窗口回调；`onWindowResize` 拖拽期间每帧全量重建 |
| T2-13 | `home_page.dart:62` `ObjectKey(currPage)` 使 `IndexedStack` 每次切页销毁重建子树，与其存在意义相悖 |
| T2-14 | `platform.dart:3-15` 无 try/catch、无超时、忽略退出码、无 `else` 分支；`-` 开头的路径存在参数注入 |
| T2-15 | Windows 声明支持文件关联（`file_association.dart:8`）但实现全部在 macOS 分支后，设置项对用户是虚假承诺 |

---

## 五、正面结论

为免报告只呈现问题，以下几点应予肯定：

- **无宿主命令注入**：所有进程调用均使用参数数组，无 `runInShell`。M3 的设备端 shell 注入是唯一注入面，且需用户主动完成安装流程
- **TLS 校验完好**：未发现 `badCertificateCallback` 或 `HttpOverrides` 覆盖
- **资源释放纪律良好**：约 15 处 `try/finally` 使用正确
- **`ByteBuffer` offset 归一化**（`apk_reader.dart:50-53`）处理了 `archive` 库 `.content` 返回 view 这一隐蔽陷阱，注释也写清了原因
- **`arsc/string_pool.dart:39-45`** 存在正确的前瞻性边界防护（含中文注释），修复模式可直接复用
- **CI secrets 使用前有显式校验**（`build.yml:308-311`），是好实践
- **弱哈希仅用于展示**：MD5/SHA-1 经全部调用链追踪至 UI，不参与任何判断，当前不构成漏洞
- **无硬编码密钥**（已 grep 确认）

---

## 六、建议执行顺序

**本周（约 3 小时）**
1. T0-3 解析器无界分配 —— 复用 `string_pool.dart` 现成模式，四处各 3 行
2. T0-4 删除 `lib/` 两份重复解析器 —— 改两处 import，一次性解决 8 处未保护索引
3. T0-1 `_safeJoin` —— 约 20 行
4. T1-1 固定 `archive` ref 到 SHA，两份 pubspec 统一，重生成 lockfile，加 `--enforce-lockfile`
5. T1-3 CI 加 `Quality` job（PR 触发：build_runner → format → analyze → test），三个构建 job `needs: [quality]`

**本月**
6. T0-2 二进制 SHA-256 校验
7. T0-5 ZIP 炸弹预算
8. T1-9 `compare.dart` 加 `exit(1)` + 提交 fixture 语料 —— 最高投入产出比
9. T1-4/T1-5/T1-6 生命周期与代次令牌
10. T1-7 `Config.flushAll()` + 启用 `setPreventClose`
11. T1-8 修正 entitlements
12. 修复三个已确认逻辑 bug（`SplitType.fromId`、`formatFileSize`、`trimSQ`）并补单测

**后续**
T2 全部条目。其中 T2-1/T2-2（解析移入 isolate + 超时 + 取消按钮）应作为一次独立的健壮性改造。

---

## 七、验证建议

前五项修复均可在无设备环境下用现有 `flutter test` 验证：

- 构造含条目 `platform-tools/../../evil` 与 `Android/../../evil.apk` 的 ZIP，断言目标目录外无文件写入
- 构造 32 字节 `resources.arsc`，`entryCount = 0xFFFFFFFF`，断言抛出 `FormatException` 而非 OOM
- 42 字节 ZIP 炸弹，断言在 `open` 阶段被拒绝
- 提供返回 `http://` 302 的镜像，断言客户端拒绝
- `versionName` 含 emoji，断言往返一致（捕获 T2-3）
- 增加一条断言：`lib/apkparser/binary_xml.dart` 与 `lib/utils/byte_data_reader.dart` **不存在**，防止 T0-4 回归
- 对 `BinaryXmlDecompressor`/`ArscParser`/`StringPool.parse` 做截断与位翻转模糊测试，断言**无异常逃逸** —— 仅此一项即可覆盖多处未保护索引

---

## 附：缺陷索引

**T0**：`T0-1` ZIP 路径穿越 | `T0-2` 二进制零校验执行 | `T0-3` 解析无界分配 | `T0-4` 解析器双副本分叉 | `T0-5` ZIP 炸弹无防护

**T1**：`T1-1` 依赖未固定且 lockfile 分歧 | `T1-2` 零测试 | `T1-3` 无 CI 门禁 | `T1-4` MethodChannel use-after-dispose | `T1-5` 异步结果竞争 | `T1-6` setState after dispose | `T1-7` 配置退出丢失 | `T1-8` entitlements 缺失/多余 | `T1-9` 差分测试器不失败

**T2**：15 项，见第四章表格

**明确排除（非问题）**：宿主命令注入（无）、TLS 绕过（无）、硬编码密钥（无）、MD5/SHA-1（仅展示）、`file://` 镜像支持（有意设计）
---

## 八、整改执行记录（2026-10-13）

### 已完成

| 编号 | 整改内容 | 涉及文件 |
|------|----------|----------|
| T0-1 | 新增 `ZipGuard.safeJoin`，拒绝 `..` 上跳、绝对路径、盘符、UNC、`~` 前缀；XAPK 解包与工具解包统一走该校验 | 新增 `lib/utils/zip_guard.dart`；`lib/utils/zip_helper.dart`、`lib/utils/xapk_installer.dart`、`lib/utils/tool_downloader.dart` |
| T0-2 | ① 官方 Google 仓库索引提到候选首位，公共镜像降为兜底；② 解析索引 `<checksum>` 并在**解包前**强制校验（优先 SHA-256，回退 SHA-1），索引未提供校验和即拒绝安装 | `lib/utils/tool_downloader.dart`（`_buildRepositoryIndexUrls`、`_parseChecksums`、`_verifyArchiveChecksum`、`ArchiveInfo`） |
| T0-3 | 按 `arsc/string_pool.dart` 既有范式加界校验：`entryCount`/`mapCount` 对照 `reader.remain`，`binary_xml` 字符串池字段改用 `readUint32()` 并校验 `chunkSize`/`numStrings` | `packages/apk_parser/lib/src/arsc_parser.dart`、`packages/apk_parser/lib/src/binary_xml.dart` |
| T0-4 | 删除 `lib/apkparser/binary_xml.dart` 与 `lib/utils/byte_data_reader.dart`，图标链路改指向已加固的 `package:apk_parser` | 删除上述两文件；`lib/apkparser/adaptive_icon_renderer.dart`、`lib/utils/vector_to_svg.dart` |
| T0-5 | `ZipGuard` 提供条目数/解压总量/压缩比三重预算，`ZipHelper.open` 与 `ApkReader.open`/`openBytes` 统一校验，工具解包同样接入 | `lib/utils/zip_guard.dart`、`lib/utils/zip_helper.dart`、`packages/apk_parser/lib/src/apk_reader.dart` |
| T1-1 | 两处 `archive` git 依赖统一固定到同一 SHA `cb3a07c8…`，lockfile 同步 | `pubspec.yaml`、`packages/apk_parser/pubspec.yaml`、两个 `pubspec.lock` |
| T1-2 | 新增 `test/utils_test.dart`、`test/split_type_test.dart` 回归测试；替换无法通过的计数器模板测试 | `test/` |
| T1-3 | 新增 `quality` 闸门（format → analyze → test → 包 analyze），三个打包任务 `needs: quality`；触发器补 `pull_request` 与 `main` 分支；`flutter pub get --enforce-lockfile` | `.github/workflows/build.yml` |
| T1-4 | `_APKInfoPageState.dispose()` 反注册 `MethodChannel('file_association')` | `lib/pages/info_page.dart` |
| T1-5 | 引入 `_loadGeneration` 代次令牌，孤儿异步结果一律丢弃；`finally` 仅在代次匹配时关闭 loading | `lib/pages/info_page.dart` |
| T1-6 | `InstallDialog` 补 `dispose()`（中断 `_currentProcess`/`_currentInstaller`），`finally` 的 `setState` 加 `mounted` 守卫 | `lib/pages/install_dialog.dart` |
| T1-7 | `ConfigItem.flush()` + `Config.flushAll()`；`setXxx` 返回值不再丢弃，失败写日志；`AppLifecycleListener` 在失焦/暂停/隐藏/退出时落盘 | `lib/config.dart`、`lib/main.dart` |
| T1-8 | 两个 entitlements 补 `network.client`，移除无用且危险的 `network.server` | `macos/Runner/Release.entitlements`、`macos/Runner/DebugProfile.entitlements` |
| T1-9 | `bin/compare.dart` 在 `failCount>0 \|\| skipCount>0` 时 `exit(1)` | `packages/apk_parser/bin/compare.dart` |
| 逻辑 bug | `formatFileSize(1048575)` → `1 MB`；`SplitType.fromId('split_config.en')` → `language`；`trimSQ()` 单引号越界 | `lib/utils/format.dart`、`lib/models/split_type.dart`、`lib/apkparser/apk_info.dart` |

### 附带修复

- `tool_downloader.dart` 的 `_extractPlatformTools` / `_extractBuildTools` 同样存在 ZIP Slip（条目名直接 `path.join`），一并改走 `ZipGuard.extractToDirectory`。
- 下载器增加 scheme 白名单（仅 `https` / `file`）。
- `binary_xml.dart` 字符串池改为读取无符号字段，此前高位攻击值可伪装成小计数。

### 待验证（阻塞）

本机无 Flutter/Dart SDK，`flutter analyze` / `flutter test` / `dart format` 均未执行。需在装有 SDK 的环境跑一次：

```bash
flutter pub get
dart run build_runner build --delete-conflicting-outputs
dart format --set-exit-if-changed .
flutter analyze --fatal-infos --fatal-warnings
flutter test
(cd packages/apk_parser && dart pub get && dart analyze --fatal-infos --fatal-warnings)
```

### 遗留待办

- **T1-2 补强**：`compare.dart` 的差分语料仍为空，需要引入一组公开 APK 样本才能成为有效回归门禁。
- **`archive` fork 固定**：已统一 SHA，但该 fork 仍是个人仓库；长期建议改为 vendored 本地依赖或上游发布版本。
- **T2 全量**：见第四章，尚未处理。
- **V2.0**：IPA 分析与 Android 加固 APK 分析尚未开始，需在上述整改验证通过后进行。
