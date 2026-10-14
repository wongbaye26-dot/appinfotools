## 下载

| 平台 | 文件 |
|---|---|
| Windows 安装包 | `AppInfoTool-{版本}-Windows-x86_64-Setup.exe` |
| Windows 免安装 | `AppInfoTool-{版本}-Windows-x86_64.zip` |
| macOS | `AppInfoTool-{版本}-macOS-universal.dmg` |
| Linux | `AppInfoTool-{版本}-Linux-x86_64.AppImage` |

macOS 的 dmg 是 universal 包，同一份在 Intel 与 Apple Silicon 上都能跑。

## 安装说明

### macOS（`.dmg`）

应用是**临时签名（ad-hoc）**的 —— 本项目没有 Apple 开发者证书，因此
**没有做公证**。首次打开会被 Gatekeeper 拦下，提示「无法验证开发者」
或「已损坏，应将它移到废纸篓」。包本身是完整的，二选一即可打开：

- 在「访达」里**右键点应用 → 打开**，在弹窗里再点一次「打开」；
- 或在终端执行：

  ```sh
  xattr -dr com.apple.quarantine "/Applications/AppInfoTool.app"
  ```

系统要求：macOS 11 或更高。

macOS 版**自带** `aapt2` 与 `adb`，装完就能用，不需要另外装 Android SDK。

### Windows（`.zip` / `-Setup.exe`）

`-Setup.exe` 是安装包，双击一路下一步即可；`.zip` 是绿色版，解压后运行
`apk_info_tool.exe`（可执行文件名是 Dart 工程名，与产物名不是一回事）。
两者内容相同，按习惯选一个即可。

> Windows 版**不内置** `aapt2` / `adb`。首次用到时去「设置 → 环境」里
> 一键下载，不需要自己装 Android SDK。

未签名的 Windows 程序首次运行可能出现 SmartScreen 提示，选择
「更多信息 → 仍要运行」。

### Linux（`.AppImage`）

```sh
chmod +x AppInfoTool-*-Linux-x86_64.AppImage
./AppInfoTool-*-Linux-x86_64.AppImage
```

## 命令行下载（可选）

如果浏览器下载不方便，可以直接用 curl 或 PowerShell：

```sh
# macOS / Linux
V=1.1.0
curl -L -o "AppInfoTool-${V}-macOS-universal.dmg" \
  "https://github.com/wongbaye26-dot/appinfotools/releases/download/v${V}/AppInfoTool-${V}-macOS-universal.dmg"
```

```powershell
# Windows（PowerShell）
$V = "1.1.0"
Invoke-WebRequest `
  "https://github.com/wongbaye26-dot/appinfotools/releases/download/v$V/AppInfoTool-$V-Windows-x86_64-Setup.exe" `
  -OutFile "AppInfoTool-$V-Windows-x86_64-Setup.exe"
```
