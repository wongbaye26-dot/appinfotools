# AppInfoTool UI Redesign — V3 / Signal Room

> **原型，不是实现。** 本目录没有修改 Flutter 源码、解析逻辑或业务规则；所有页面为静态 HTML，用于确认视觉方向与信息结构。

## 为什么是 V3

V1 是暖白工作台 + 石墨侧栏，偏“安静的桌面工具”；V3 用同一套信息架构，改成深色技术仪表盘，偏“检查台 / 证据链”。两套都保留在仓库中，便于对比后再决定实现方向。

V3 使用 `ui-ux-pro-max` 的设计检索结果作为输入：

- 模式：`data-dense-dashboard`（密集数据仪表盘，而非落地页 / 文档页）
- 风格：Dark Mode / OLED，高对比、低装饰
- 字体：JetBrains Mono / IBM Plex Sans（本地以 SF Mono / SF Pro / PingFang 为实际 fallback）
- UX：可见 focus、键盘可达、状态不能只靠颜色表达、减少无意义动效
- 密度：8px 间距基线，36px 表格行，12–14px 正文，8–9px mono 标签

检索结果里的“文档落地页”模式被判断为不适合桌面检查工具，未采用。

## 设计语言

| Token | 值 | 用途 |
|---|---|---|
| `--bg` | `#070b0f` | 最深背景 |
| `--panel` | `#101820` | 卡片 / 面板 |
| `--line` | `#22303a` | 分隔线 |
| `--ink` | `#e9eef2` | 主文字 |
| `--muted` | `#7f909b` | 次要说明 |
| `--lime` | `#c4f36a` | 主动作、正向、当前目标 |
| `--teal` | `#5bd6c4` | 证据 / 链接 / 可核对信息 |
| `--amber` | `#f0b35e` | 覆盖缺口、需复核 |
| `--red` | `#ff6b5f` | 失败、高风险 |
| `--blue` | `#7aa7ff` | 信息性标记 |

- 画布 **1440×1024**，56px 顶栏 + 72px 图标 rail + 30px 状态栏。
- 卡片 8px 圆角、1px 描边，几乎没有阴影；靠线框和留白建立层级。
- 标题/数字用 mono 或紧字距无衬线；路径、规则 ID、计数用等宽。
- 状态不只靠颜色：同时出现 `CHANGED` / `UNKNOWN` / `PARTIAL` 等文本标签。

## 页面

| # | 页面 | 内容 |
|---|---|---|
| 01 | [概览 · 空态](screens/01-overview-empty.html) | 首次打开、支持格式、分析管线、会话环境 |
| 02 | [概览 · 当前目标](screens/02-overview-active.html) | 目标身份、安全姿态、结构计数、最近分析 |
| 03 | [分析 · Android](screens/03-analysis-apk.html) | 静态线索、覆盖仪表、Artifact / Load Graph 证据 |
| 04 | [分析 · iOS](screens/04-analysis-ipa.html) | FairPlay 密文、签名失败、嵌套截断 |
| 05 | [版本对比](screens/05-diff.html) | 字段 / 集合 / 无法比较三类差异 |
| 06 | [安装 · 设备](screens/06-install.html) | 设备、选项、实时 adb 日志 |
| 07 | [设置](screens/07-settings.html) | 外观、系统集成、工具路径、诊断、隐私 |
| 08 | [状态与浮层](screens/08-states.html) | Empty / Loading / Partial / Failure + 导出、批量重命名 |

打开 [完整画廊](prototype.html) 可点击进入每个页面。

## 文件

```text
docs/prototypes/ui-redesign-v3/
├── prototype.html       # 画廊入口
├── README.md
├── assets/
│   ├── logo.png
│   ├── v3.css           # token + 组件 + 页面布局
│   ├── icons.js         # inline SVG symbol sprite
│   └── shell.js         # 顶栏 / rail / 状态栏注入
├── screens/             # 8 个静态页面
└── renders/             # 1440×1024 PNG
```

页面通过 `<body class="app" data-nav="..." data-state="..." ...>` 声明外壳状态，由 `shell.js` 注入统一导航，避免每页复制侧栏。

## 重新截图

```bash
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  --headless=new --disable-gpu --hide-scrollbars \
  --window-size=1440,1024 \
  --screenshot=docs/prototypes/ui-redesign-v3/renders/03-analysis-apk.png \
  "file:///Users/wangbaye/Projects/AppInfoTool/docs/prototypes/ui-redesign-v3/screens/03-analysis-apk.html"
```

## 与 V1 的差异

| | V1 (Precise inspection console) | V3 (Signal Room) |
|---|---|---|
| 基调 | 暖白、纸面、轻 | 深色、仪器、证据 |
| 导航 | 248px 文本侧栏 | 72px 图标 rail + 顶栏 |
| 信息密度 | 中等，卡片呼吸感强 | 高，表格行 36px |
| 强调色 | 深青 + 薄荷 | 荧光青柠 + 青绿 |
| 适用 | 日常阅读 / 报告浏览 | 长时间检查 / 大屏工作站 |

## 边界

- 所有样本、数字、路径均为演示数据。
- 未修改 `lib/`、`packages/`、`windows/`、`macos/`。
- 未提交 commit，未移动 tag 或发布版本。
- V1 仍在 `docs/prototypes/ui-redesign/`，未删除。
