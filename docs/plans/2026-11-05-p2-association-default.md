# P2-7：启动不再替用户决定默认文件关联

> 日期：2026-11-05｜状态：已修（待 Windows 编译验证）

## 问题

`FileAssociationManager.registerAssociations()` 在每次启动时调用；Windows
原生实现原本在没有 `UserChoice` 时还会写：

```
HKCU\Software\Classes\.apk = AppInfoTool.apk
```

这等于替用户把本程序设成默认打开方式，与 README 的“由你决定”矛盾；而且
每次启动都会重新写回，用户后来选择的默认值也会被抢回。

## 修复

`windows/runner/file_association_channel.cpp` 的注册逻辑现在只做两件事：

1. 写 ProgID 本体（描述 / 图标 / 打开命令）；
2. 写 `OpenWithProgids`，让本程序出现在“打开方式 → 选择其他应用”里。

**不再写扩展名的默认值**；`HasUserChoice` 辅助函数已删除（不再使用）。

安装器里的显式关联（HKLM）不受影响。

## 仍未验证

- Windows 编译与真机双击行为；
- 安装版与便携版的行为差异。

## 门禁

本轮只改 Windows C++，Dart 门禁保持：
根项目 1,780 通过；analyze 0 问题；format 414 files 0 changed。
