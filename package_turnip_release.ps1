Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$root = $PSScriptRoot
$distDir = Join-Path $root "dist"
$releaseDir = Join-Path $distDir "toolbear-turnip-bot"
$zipPath = Join-Path $distDir "toolbear-turnip-bot.zip"

if (Test-Path $releaseDir) {
  Remove-Item -Path $releaseDir -Recurse -Force
}
if (Test-Path $zipPath) {
  Remove-Item -Path $zipPath -Force
}

New-Item -Path $releaseDir -ItemType Directory -Force | Out-Null

$files = @(
  "README.md",
  ".env.example",
  "toolbear_env.ps1",
  "toolbear_turnip_bot.ps1",
  "turnip_bot_config.json",
  "turnip_dashboard_server.py",
  "turnip_dashboard.html",
  "build_turnip_executables.ps1",
  "run_turnip_bot.ps1",
  "run_turnip_dashboard.ps1",
  "run_turnip_suite.ps1",
  "run_turnip_bot.bat",
  "run_turnip_dashboard.bat",
  "run_turnip_suite.bat"
)

foreach ($file in $files) {
  Copy-Item -Path (Join-Path $root $file) -Destination (Join-Path $releaseDir $file) -Force
}

Compress-Archive -Path (Join-Path $releaseDir "*") -DestinationPath $zipPath
Write-Host "Release package created: $zipPath"
