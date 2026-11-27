# Windows runtime smoke: start the packaged executable and verify it stays alive.
#
# Scope: **startup only**. APK analysis / report export / Explorer thumbnail /
# association / installer / uninstall are covered by the Stage E manual
# acceptance checklist and (for install/uninstall) tool/windows_install_smoke.ps1.
# The CI runner does not provide an interactive Explorer desktop, so this script
# must not claim those checks.
param(
  [Parameter(Mandatory = $true)][string]$ExePath
)
$ErrorActionPreference = 'Stop'
if (-not (Test-Path $ExePath)) { throw "windows runtime smoke: exe not found: $ExePath" }

$work = Split-Path -Parent $ExePath
$p = Start-Process -FilePath $ExePath -WorkingDirectory $work -PassThru
try {
  Start-Sleep -Seconds 10
  $p.Refresh()
  if ($p.HasExited) {
    $code = $p.ExitCode
    $eventDetail = ''
    try {
      $events = Get-WinEvent -FilterHashtable @{LogName='Application'; StartTime=(Get-Date).AddMinutes(-2)} -ErrorAction SilentlyContinue |
        Where-Object { $_.Message -match 'AppInfoTool|apk_info_tool' } |
        Select-Object -First 3
      $eventDetail = ($events | ForEach-Object { $_.Message }) -join ' | '
    } catch { }
    if ($eventDetail.Length -gt 1200) { $eventDetail = $eventDetail.Substring(0, 1200) }
    Write-Host "::error title=Windows runtime smoke failed::exit=$code; $eventDetail"
    throw "windows runtime smoke: app exited during startup (exit $code)"
  }
  Write-Host 'windows runtime smoke: OK (app stayed alive for 10s; launch-only scope)'
}
finally {
  if (-not $p.HasExited) {
    Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
  }
}
