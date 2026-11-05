# 在 Windows 上手动跑安装器冒烟：静默安装 → 校验文件/注册表 → 静默卸载。
#
# 必须**以管理员身份**运行（appinfotool.iss 的 PrivilegesRequired=admin）。
# 这不是 CI 步骤：CI 没有交互式桌面，且管理员静默安装的目录行为在 runner
# 上不稳定；真实 Explorer 缩略图仍需人工确认。
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File tool/windows_install_smoke.ps1
#   powershell -ExecutionPolicy Bypass -File tool/windows_install_smoke.ps1 `
#     -SetupPath build/windows/x64/installer/Release/AppInfoTool-2.9.0-Windows-x86_64-Setup.exe
#   ... -KeepInstalled   # 保留安装，便于接着手工检查 Explorer

param(
  [string]$SetupPath = '',
  [switch]$KeepInstalled
)

$ErrorActionPreference = 'Stop'

function Assert-Admin {
  $principal = New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent())
  if (-not $principal.IsInRole(
      [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw '以管理员身份运行此脚本（安装器的 PrivilegesRequired=admin）。'
  }
}
Assert-Admin

if (-not $SetupPath) {
  $SetupPath = Get-ChildItem 'build/windows/x64/installer/Release/AppInfoTool-*-Setup.exe' |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
}
if (-not $SetupPath -or -not (Test-Path $SetupPath)) {
  throw "找不到安装器：$SetupPath"
}
Write-Host "setup: $SetupPath"

$log = Join-Path $env:TEMP 'appinfotool-install-smoke.log'
$p = Start-Process -FilePath $SetupPath -ArgumentList @(
  '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-',
  '/TASKS=associate', "/LOG=$log"
) -Wait -PassThru
Write-Host "installer exit: $($p.ExitCode)"
if ($p.ExitCode -ne 0) {
  Get-Content $log -ErrorAction SilentlyContinue | Select-Object -Last 40
  throw "安装失败：exit $($p.ExitCode)"
}

$uninstallRoot = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall'
$entry = Get-ChildItem $uninstallRoot |
  Where-Object { (Get-ItemProperty $_.PSPath).DisplayName -like '*AppInfoTool*' } |
  Select-Object -First 1
if (-not $entry) { throw '安装后找不到卸载项' }
$props = Get-ItemProperty $entry.PSPath
$dir = $props.InstallLocation
if ([string]::IsNullOrWhiteSpace($dir)) { $dir = Join-Path $env:ProgramFiles 'AppInfoTool' }
$dir = $dir.TrimEnd('\')

if (-not (Test-Path (Join-Path $dir 'AppInfoTool.exe'))) {
  $found = @($env:ProgramFiles, ${env:ProgramFiles(x86)}) |
    Where-Object { $_ -and (Test-Path $_) } |
    ForEach-Object {
      Get-ChildItem -Path $_ -Filter 'AppInfoTool.exe' -File -Recurse `
        -ErrorAction SilentlyContinue
    } | Select-Object -First 1
  if ($found) { $dir = $found.DirectoryName }
}
Write-Host "install dir: $dir"

foreach ($name in 'AppInfoTool.exe', 'appinfotool_thumbnail.dll', 'app_icon_extractor.exe') {
  $path = Join-Path $dir $name
  if (-not (Test-Path $path)) { throw "安装文件缺失：$path" }
  Write-Host "ok file: $path"
}

$clsid = '{9C4A7E52-3B7D-4E31-9A4C-6D2F8B1E5A70}'
$thumbKey = "HKCU:\Software\Classes\CLSID\$clsid\InprocServer32"
$thumbDll = (Get-Item $thumbKey).GetValue('')
if ($thumbDll -ne (Join-Path $dir 'appinfotool_thumbnail.dll')) {
  throw "缩略图 DLL 注册不对：$thumbDll"
}
Write-Host "ok thumbnail CLSID: $thumbDll"

$shellEx = "HKCU:\Software\Classes\.apk\ShellEx\{E357FCCD-A995-4576-B01F-234630154E96}"
$thumbClsid = (Get-Item $shellEx).GetValue('')
if ($thumbClsid -ne $clsid) { throw "ShellEx CLSID 不对：$thumbClsid" }
Write-Host "ok .apk ShellEx: $thumbClsid"

$assoc = 'HKLM:\Software\Classes\AppInfoTool.apk\shell\open\command'
$cmd = (Get-Item $assoc).GetValue('')
if ($cmd -notmatch 'AppInfoTool\.exe') { throw "文件关联命令不对：$cmd" }
Write-Host "ok association: $cmd"

Write-Host ''
Write-Host '安装/注册冒烟通过。'
Write-Host '请手工确认：在资源管理器里给一个 .apk 显示缩略图；应用设置里停用/启用缩略图后刷新。'
if ($KeepInstalled) {
  Write-Host "保留安装：$dir"
  exit 0
}

$unins = $props.UninstallString
if ([string]::IsNullOrWhiteSpace($unins)) { $unins = Join-Path $dir 'unins000.exe' }
$unins = $unins.Trim('"')
$u = Start-Process -FilePath $unins -ArgumentList @(
  '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART'
) -Wait -PassThru
if ($u.ExitCode -ne 0) { throw "卸载失败：exit $($u.ExitCode)" }
if (Test-Path (Join-Path $dir 'AppInfoTool.exe')) { throw '卸载后 AppInfoTool.exe 仍在' }
Write-Host '卸载冒烟通过。'
