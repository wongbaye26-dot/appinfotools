# AppInfoTool UI Redesign Prototype

本目录是 AppInfoTool 桌面端的 UI 升级原型，**不包含 Flutter 实现，也没有修改任何业务逻辑**。目标是在进入真实 UI 改造前，先确认信息密度、视觉层级与关键状态表达。

## 设计方向

**Precise inspection console / 精准检查台**

- 暖白工作台 + 石墨侧栏：长时间阅读不刺眼，同时保持专业工具感。
- 青色（`#0f766e`）表达“结构 / 证据 / 可操作”；薄荷色（`#b9f26e`）只做高亮，不大面积铺色。
- 琥珀与红色只用于安全发现、覆盖缺口和失败状态，避免把普通信息渲染成风险。
- 数字、路径、规则 ID 使用等宽字体；正文使用 SF Pro / PingFang。
- 卡片 16px 圆角、细描边和极轻阴影；页面只保留一条视觉动线：标题 → 当前对象 → 证据 → 操作。

## 画布与导航

- 画布：**1440 × 1024**，对应桌面窗口。
- 标题栏：38px，macOS 红黄绿交通灯。
- 侧栏：248px，包含品牌、⌘K、五个工作区入口、最近分析、平台与版本。
- 主区域：页头 + 内容；内容高度固定，超出部分在真实实现中使用页面内滚动。

## 页面索引

| # | 原型 | 说明 |
|---|---|---|
| 01 | [概览 · 空态](screens/01-overview-empty.html) | 首次打开：支持格式、开始分析、空最近文件 |
| 02 | [概览 · 工作台](screens/02-overview-active.html) | 当前对象、安全摘要、结构计数、最近文件 |
| 03 | [分析 · Android](screens/03-analysis-apk.html) | 应用信息、静态线索、覆盖环、结构证据 |
| 04 | [分析 · iOS](screens/04-analysis-ipa.html) | FairPlay、签名失败、嵌套截断、覆盖缺口 |
| 05 | [版本对比](screens/05-diff.html) | 字段 / 集合 / 无法比较三类差异 |
| 06 | [安装 · 设备](screens/06-install.html) | 文件、设备、安装选项、实时 adb 日志 |
| 07 | [设置](screens/07-settings.html) | 外观、系统集成、工具路径、诊断与关于 |
| 08 | [状态与浮层](screens/08-states.html) | Empty / Loading / Partial / Failure，导出与批量重命名 |

[打开完整画廊](prototype.html)

## 文件

```text
docs/prototypes/ui-redesign/
├── prototype.html          # 画廊入口
├── README.md
├── assets/
│   ├── logo.png            # 来自应用图标
│   ├── prototype.css       # 设计 token 与全部组件样式
│   ├── icons.js            # inline SVG symbol sprite
│   └── shell.js            # 注入标题栏与侧栏
├── screens/                # 8 个可交互静态页面
└── renders/                # 1440×1024 PNG 截图
```

页面通过 `<body class="app" data-nav="..." data-window-title="..." data-window-state="...">` 声明所属工作区，`shell.js` 负责注入统一外壳，避免每个页面重复写侧栏。

## 重新渲染 PNG

```bash
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  --headless=new --disable-gpu --hide-scrollbars \
  --window-size=1440,1024 \
  --screenshot=docs/prototypes/ui-redesign/renders/02-overview-active.png \
  "file:///Users/wangbaye/Projects/AppInfoTool/docs/prototypes/ui-redesign/screens/02-overview-active.html"
```

## 原型中刻意表达的产品语义

- **证据优先于结论**：安全卡片先展示“发现了什么、覆盖多少”，再给解释；不出现“恶意软件”定性。
- **未知 ≠ 差异 / 未知 ≠ 安全**：对比页与覆盖缺口都单独表达无法比较、未扫描的部分。
- **安装 ≠ 运行**：安装页明确只负责传输，不启动、不执行样本。
- **系统集成默认关闭**：缩略图开关默认 off；关闭失败时允许显示“未能完全停用”，不假报成功。
- **失败状态不渲染详情**：解析失败时只保留错误、重试与选择其他文件。

## 边界

- 所有数据为静态示例，用于表达信息架构和视觉语言。
- 未修改 `lib/`、`packages/`、`windows/` 等任何应用代码。
- 未提交 commit，也未移动版本或标签。
