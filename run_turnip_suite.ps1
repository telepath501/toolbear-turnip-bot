Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$root = $PSScriptRoot

Start-Process powershell -ArgumentList @(
  "-NoProfile",
  "-ExecutionPolicy", "Bypass",
  "-File", (Join-Path $root "run_turnip_bot.ps1"),
  "-Execute"
) -WorkingDirectory $root | Out-Null

Start-Sleep -Seconds 2

Start-Process powershell -ArgumentList @(
  "-NoProfile",
  "-ExecutionPolicy", "Bypass",
  "-File", (Join-Path $root "run_turnip_dashboard.ps1")
) -WorkingDirectory $root | Out-Null
