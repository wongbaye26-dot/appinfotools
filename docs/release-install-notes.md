## 安装说明

### macOS（`.dmg`）

应用是**临时签名（ad-hoc）**的 —— 本项目没有 Apple 开发者证书，因此
**没有做公证**。首次打开会被 Gatekeeper 拦下，提示「无法验证开发者」
或「已损坏，应将它移到废纸篓」。包本身是完整的，二选一即可打开：

- 在「访达」里**右键点应用 → 打开**，在弹窗里再点一次「打开」；
- 或在终端执行：

  ```sh
  xattr -dr com.apple.quarantine "/Applications/APP详情工具.app"
  ```

系统要求：macOS 11 或更高。macOS 版自带 `aapt2` 与 `adb`，无需再下载 Android SDK。

### Windows（`.exe` / `.zip`）

`.exe` 是安装包，`.zip` 解压后直接运行 `apk_info_tool.exe`。
两者内容相同，按习惯选一个即可。

Windows 版**不内置** `aapt2` / `adb`，请到「设置 → 环境」里一键下载。

> 未签名的 Windows 程序首次运行可能出现 SmartScreen 提示，选择
> 「更多信息 → 仍要运行」。

### Linux（`.AppImage`）

```sh
chmod +x APKInfoTool-*-x86_64.AppImage
./APKInfoTool-*-x86_64.AppImage
```
