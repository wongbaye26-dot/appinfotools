# AppInfoTool — UI Redesign V4 · Paper & Signal

UI-only prototype. **No Flutter source, business logic, data model, or parser behavior was changed.**

- Canvas: 1440×1024 desktop (macOS frame)
- Shell: 72px top bar, floating 234px sidebar (collapses to 78px icon rail), 28px page padding
- Direction: warm paper workbench, floating white panels, electric violet action signal
- Status: static HTML + screenshots, for direction review only

## Why this direction

AppInfoTool is a static inspection tool, not a dashboard for its own sake. V4 treats the screen like an editorial evidence sheet:

1. **Current object first** — what file is open, what platform, what was parsed.
2. **Evidence second** — what is complete, what is partial, what is encrypted or truncated.
3. **Action third** — next review step, report export, or install target.

V1 was a quiet warm workbench; V3 was a dark instrument. V4 is a bright editorial studio: more air, stronger typographic hierarchy, and playful but restrained motion (sidebar spring, sliding pill tabs, checkbox pop).

## Design tokens

| Token | Value |
|---|---|
| Paper | `#F4F2EE` |
| Surface | `#FFFFFF` |
| Surface 2 / 3 | `#F5F3EF` / `#EAE7E1` |
| Ink / 2 / 3 | `#16151B` / `#57535F` / `#8E8A97` |
| Violet (action) | `#6A57F2` |
| Blue | `#2F8FE0` |
| Mint (positive) | `#119C72` |
| Amber (attention) | `#D6731E` |
| Danger | `#D93A55` |
| Gradient | `linear-gradient(120deg,#7B61FF,#3D8BFF 55%,#1FB89A)` |

Type: Pretendard / SF Pro / PingFang for UI; SF Mono / JetBrains Mono for IDs and counts. Card radius 22px; floating sidebar 28px; hairline `#E5E1D8`.

## Lucian elements used

Ported from the local `lucian-uxui` 1.2.0 library. License lines are kept in `assets/v4.css` and `assets/shell.js`.

- **#417 Collapsible sidebar** — width 224→64, spring `.6s cubic-bezier(.3,1.3,.45,1)`, sliding active highlight.
  <https://lucianlabs.dev/uxui-prompt/#417>
- **#039 Sliding pill tabs** — black active pill glides and stretches with `.5s var(--ux-spring)`.
  <https://lucianlabs.dev/uxui-prompt/#039>
- **#032 Drag-and-drop upload** — dashed border, gradient orb, hover lift.
  <https://lucianlabs.dev/uxui-prompt/#032>
- **#433 Checkbox / radio / switch** — 40×23 switch with spring thumb; checkbox pop.
  <https://lucianlabs.dev/uxui-prompt/#433>
- **#090 Error widget** — failure state with clear retry / choose-another action, no misleading details.
  <https://lucianlabs.dev/uxui-prompt/#090>

All motion respects `prefers-reduced-motion`. Focus-visible rings and keyboard arrow navigation are included for nav and tabs.

## Screens

| # | File | Purpose |
|---|---|---|
| 01 | `screens/01-overview-empty.html` | Empty overview: drop zone, formats, session state, pipeline |
| 02 | `screens/02-overview-active.html` | Active target: identity, posture, stats, recent files, log |
| 03 | `screens/03-analysis-apk.html` | Android analysis: findings, coverage, structure evidence |
| 04 | `screens/04-analysis-ipa.html` | iOS analysis: FairPlay, signature failure, nested truncation |
| 05 | `screens/05-diff.html` | Version comparison: field/set/unknown separation |
| 06 | `screens/06-install.html` | Install: file, device, options, live adb log |
| 07 | `screens/07-settings.html` | Settings: appearance, system integration, tools, diagnostics |
| 08 | `screens/08-states.html` | Empty / Loading / Partial / Failure + dialogs |

Gallery: `prototype.html`. Contact sheet: `renders/contact-sheet.png`.

## How to view / render

Open `prototype.html` in a browser, or any screen directly.

```bash
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  --headless=new --disable-gpu --hide-scrollbars \
  --window-size=1440,1024 \
  --screenshot=docs/prototypes/ui-redesign-v4/renders/<name>.png \
  "file:///Users/wangbaye/Projects/AppInfoTool/docs/prototypes/ui-redesign-v4/screens/<name>.html"
```

Screenshots are fixed at 1440×1024. Contact sheet uses Hiragino Sans GB to avoid CJK box glyphs.

## Scope

- Prototype only; no Flutter implementation.
- No behavior, security wording, or parser logic changed.
- V1 (`docs/prototypes/ui-redesign/`) and V3 (`docs/prototypes/ui-redesign-v3/`) remain available for comparison.
