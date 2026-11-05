# P2-8：补齐 4 类常见权限

> 日期：2026-11-05

## 改动

`PermissionCatalog` 新增：

- `READ_SMS`（deviceData / P3）
- `READ_CALL_LOG`（deviceData / P3）
- `READ_CALENDAR`（deviceData / P3）
- `POST_NOTIFICATIONS`（backgroundTask / INFO / minApi 33）

规则库版本升到 `android-permissions-2026.11.1`；6 语言权限文案与
`_permissionRuleText` 分支已补。

## 结果

这 4 类权限不再落入 `ANDROID-PERMISSION-UNCATEGORIZED`，会带等级、用途与
版本条件进入权限卡片。规则总数 29 → 33；README 已同步。

## 门禁

| 项 | 结果 |
|---|---|
| 根项目 `flutter test` | 1,772 通过 |
| `apk_parser` | 217 通过 |
| 根项目 / 包 analyze | 0 问题 |
| `dart format` | 407 files，0 changed |
