# 三平台运行验收（Stage E / P1-6）

这个目录把「构建成功」和「产物真的能运行」分开处理。

CI 里的 `tool/runtime_smoke/*` 只验证**启动**：

- macOS：启动打包后的 `.app`，确认 10 秒内没有退出。
- Linux：在 Xvfb 下启动 AppImage，确认 10 秒内没有退出。
- Windows：启动便携 zip 里的 `AppInfoTool.exe`，确认 10 秒内没有退出。

CI runner 没有交互式桌面，不能点「打开文件」、不能在原生保存对话框里选路径，
也不能可靠地让 Explorer 渲染缩略图。因此 CI **不**声称完成 APK/IPA 分析、
报告导出、缩略图、文件关联、安装/卸载验收。完整验收必须按下面的清单在真实
桌面上执行，并把结果填进 `docs/audit/APPINFOTOOL_2.10.7_STAGE_E_RUNTIME_ACCEPTANCE.md`。

## macOS（安装 / 启动 / IPA 分析 / 报告导出）

1. 构建并安装：
   ```bash
   ~/development/flutter/bin/flutter build macos --release
   ditto build/macos/Build/Products/Release/AppInfoTool.app /Applications/AppInfoTool.app
   codesign --verify --strict /Applications/AppInfoTool.app
   ```
2. 启动并打开一个 IPA（验证文件打开事件，不只是普通启动）：
   ```bash
   open -a /Applications/AppInfoTool.app /path/to/sample.ipa
   ```
3. 等概览页出现文件名、Bundle ID、版本和发现数量；点「查看详情」，
   检查「应用」「签名」「安全」标签能渲染。
4. 右上角「更多」→「导出解析报告」，分别导出 Markdown 与 JSON；
   确认文件非空，JSON 的 `reportSchemaVersion` 为 8。
5. 关闭应用，删除 `/Applications/AppInfoTool.app`（或保留供人工复查）。

## Windows（安装 / 启动 / APK 分析 / 报告导出 / 缩略图 / 关联 / 卸载）

需要管理员权限和真实 Explorer 桌面。

1. 安装（`tool/windows_install_smoke.ps1` 会静默安装、校验文件/注册表、再静默卸载）：
   ```powershell
   powershell -ExecutionPolicy Bypass -File tool/windows_install_smoke.ps1 `
     -SetupPath build\windows\x64\installer\Release\AppInfoTool-<version>-Windows-x86_64-Setup.exe
   ```
   若要保留安装供手动检查，加 `-KeepInstalled`。
2. 从开始菜单启动，打开一个 APK，检查应用/权限/结构/签名/安全标签。
3. 导出 Markdown 与 JSON 报告，确认非空且 JSON 含 `security.artifacts`、
   `security.loadGraph`（Android 报告）。
4. 在 Explorer 中确认 `.apk` 有缩略图；在「打开方式」中确认 AppInfoTool 存在。
5. 在设置页停用再启用缩略图，刷新 Explorer；确认停用后缩略图消失、启用后恢复。
6. 卸载，确认安装目录与 HKCU/HKLM 相关项被清理（Stage F 会单独修默认行为）。

## Linux（AppImage 启动 / APK 分析 / 报告导出）

1. 赋予执行权限并启动：
   ```bash
   chmod +x AppInfoTool-<version>-Linux-x86_64.AppImage
   ./AppInfoTool-<version>-Linux-x86_64.AppImage
   ```
   没有 FUSE 时用 `APPIMAGE_EXTRACT_AND_RUN=1 ./AppInfoTool-...AppImage`。
2. 打开一个 APK，检查详情与「安全」标签。
3. 导出 Markdown 与 JSON 报告，确认非空。
4. （可选）在 Xvfb 下运行 `tool/runtime_smoke/linux.sh <AppImage>` 验证启动。

## 结果记录要求

- 每个平台必须记录：系统版本、产物路径、实际命令、观察到的界面/文件证据、
  未执行项及原因。
- 没跑过的项目写「未执行」，不能因为 CI 启动通过就写成「已验收」。
- 真实样本缺失、安装器权限不足或没有 Explorer 桌面时，P1-6 不能标为完成，
  发布建议必须是 NO-GO，直到补齐证据。
