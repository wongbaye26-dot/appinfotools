# 界面目视：把真实组件渲成 PNG

> 结论先说：**`RepaintBoundary.toImage()` 在本机跑不了**，必须走 web 构建 +
> 无头浏览器截图。这份笔记记下两条路的确切症状与可用步骤，省得下次再试一遍。

## 为什么需要它

本机构建不了任何平台产物（macOS 被沙箱拒、Linux/Windows 只支持各自主机），
但「界面长什么样」不能靠读代码确认：文案会不会被截断、长列表会不会刷屏、
中文有没有漏成英文回退 —— 这些只有看到才作数。

## 路一（不可用）：`flutter test` 里 `toImage()`

`test/_snapshot_render.dart` 与 `tool/snapshot_security.dart`（已删）走的是
这条路。实测：**只要调用 `boundary.toImage()`，整个测试进程立刻被 SIGKILL**
（退出码 137，连 `loading ...` 都不打印，`stderr` 也空）。最小复现：

```dart
await tester.pumpWidget(const MaterialApp(
  home: Scaffold(body: RepaintBoundary(child: Text('hi'))),
));
await tester.pump();
final b = tester.renderObject<RenderRepaintBoundary>(
  find.byType(RepaintBoundary).first);
final image = await b.toImage(pixelRatio: 1.0);   // ← 进程在这里死掉
```

对照实验：

| 用例 | 结果 |
|---|---|
| 纯 widget 测试（无 `toImage`） | 通过 |
| 只取 `RenderRepaintBoundary.size` | 通过（`Size(800, 600)`） |
| 加一行 `await b.toImage(...)` | **SIGKILL，无任何输出** |

关掉工具沙箱重试同样被杀，所以不是沙箱策略。

## 路二（可用）：web 构建 + 无头 Chrome

不需要任何平台工具链，也不需要 GPU。

```sh
# 1) 临时工程（不要放进本仓库，避免为一个验证步骤加 web/ 目录）
flutter create --platforms=web --project-name nsc_snapshot /tmp/nscsnap
# pubspec 里加路径依赖：
#   apk_info_tool: {path: <本仓库>}
#   analysis_model: {path: <本仓库>/packages/analysis_model}

# 2) 入口：只渲染要看的组件（SecurityFindingCard + AnalysisReport 的覆盖率正文）
#    数据用 tool/emit_audit_literals_test.dart 从真实 APK 导出成 Dart 字面量，
#    避免为了截图去搬 apk_parser（web 端读不了本地文件）。
flutter test tool/emit_audit_literals_test.dart        # 产出 /tmp/findings.dart

# 3) 构建 + 起静态服务
flutter build web --release
python3 -m http.server 8792        # 在 build/web 下，用 run_in_background 起

# 4) 截图（Chrome 已装，无需 chromedriver）
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  --headless=new --disable-gpu --no-sandbox --hide-scrollbars \
  --force-device-scale-factor=1 --window-size=920,1500 \
  --virtual-time-budget=20000 \
  --screenshot=/tmp/shot.png "http://127.0.0.1:8792/index.html?section=a"
```

要点：

- **窗口宽度 ≤ 1000**：再宽截图被等比缩小，文字就看不清了。
- 入口里用 URL 查询参数切段（`?section=a|b|c`），一次只渲一段，
  比截一张超长图再裁更省事。
- `--virtual-time-budget` 要给足：语言包是 deferred 的，加载要时间。
- `http.server` 必须用 `run_in_background` 起。用 `(cmd &)` 会随上一个
  Bash 调用结束被回收，Chrome 拿到 `ERR_CONNECTION_REFUSED`。

## 已经这样验证过的内容（2026-10-18）

- `ANDROID-EXPORTED-COMPONENT` 在抖音上渲染成「有 159 个组件…其中包括
  （12 个）…另有 147 个未列出」，卡片约 10 行 —— 截断生效，没有刷屏。
- `ANDROID-RULE-D` / `ANDROID-RULE-D-ESCALATED` 正文是中文，不是英文回退。
- 覆盖率面板出现新维度「明文流量策略 1/1」，没有露出 `android.cleartextPolicy`
  这种机器 id。
- 三种夹具（NSC / 清单配置 / 真实大包）在 920px 宽下都没有溢出、没有竖排文字。
