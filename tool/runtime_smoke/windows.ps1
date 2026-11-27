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

$p = Start-Process -FilePath $ExePath -PassThru
try {
  Start-Sleep -Seconds 10
  $p.Refresh()
  if ($p.HasExited) {
    throw "windows runtime smoke: app exited during startup (exit $($p.ExitCode))"
  }
  Write-Host 'windows runtime smoke: OK (app stayed alive for 10s; launch-only scope)'
}
finally {
  if (-not $p.HasExited) {
    Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
  }
}
