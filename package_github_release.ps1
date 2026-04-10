Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$root = $PSScriptRoot
$distDir = Join-Path $root "dist"
$releaseDir = Join-Path $distDir "toolbear-turnip-github-release"
$zipPath = Join-Path $distDir "toolbear-turnip-github-release.zip"
$appDir = Join-Path $releaseDir "app"
$docsDir = Join-Path $releaseDir "docs"

if (Test-Path $releaseDir) {
  Remove-Item -Path $releaseDir -Recurse -Force
}
if (Test-Path $zipPath) {
  Remove-Item -Path $zipPath -Force
}

New-Item -Path $releaseDir -ItemType Directory -Force | Out-Null
New-Item -Path $appDir -ItemType Directory -Force | Out-Null
New-Item -Path $docsDir -ItemType Directory -Force | Out-Null

$rootFiles = @(
  "README.md",
  "RELEASE_NOTES.md",
  ".env.example"
)

foreach ($file in $rootFiles) {
  Copy-Item -Path (Join-Path $root $file) -Destination (Join-Path $releaseDir $file) -Force
}

Copy-Item -Path (Join-Path $root "README.md") -Destination (Join-Path $docsDir "README.md") -Force
Copy-Item -Path (Join-Path $root "RELEASE_NOTES.md") -Destination (Join-Path $docsDir "RELEASE_NOTES.md") -Force

$appFiles = @(
  "toolbear_env.ps1",
  "toolbear_turnip_bot.ps1",
  "turnip_bot_config.json",
  "turnip_dashboard.html",
  "run_turnip_bot.ps1",
  "run_turnip_dashboard.ps1",
  "run_turnip_suite.ps1",
  "run_turnip_bot.bat",
  "run_turnip_dashboard.bat",
  "run_turnip_suite.bat"
)

foreach ($file in $appFiles) {
  Copy-Item -Path (Join-Path $root $file) -Destination (Join-Path $appDir $file) -Force
}

$dashboardExe = Join-Path $root "turnip_dashboard_server.exe"
if (Test-Path $dashboardExe) {
  Copy-Item -Path $dashboardExe -Destination (Join-Path $appDir "turnip_dashboard_server.exe") -Force
}

$suiteExe = Join-Path $root "dist\toolbear-turnip-exe\ToolBearTurnipSuite.exe"
if (Test-Path $suiteExe) {
  Copy-Item -Path $suiteExe -Destination (Join-Path $appDir "ToolBearTurnipSuite.exe") -Force
}

$startSuite = @'
@echo off
setlocal
cd /d "%~dp0"
start "" ".\app\ToolBearTurnipSuite.exe"
endlocal
'@

$startBot = @'
@echo off
setlocal
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File ".\app\run_turnip_bot.ps1" -Execute
endlocal
'@

$startDashboard = @'
@echo off
setlocal
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File ".\app\run_turnip_dashboard.ps1"
timeout /t 2 >nul
start "" http://localhost:8862/
endlocal
'@

Set-Content -Path (Join-Path $releaseDir "start.bat") -Value $startSuite -Encoding ASCII
Set-Content -Path (Join-Path $releaseDir "start-bot.bat") -Value $startBot -Encoding ASCII
Set-Content -Path (Join-Path $releaseDir "start-dashboard.bat") -Value $startDashboard -Encoding ASCII

Compress-Archive -Path (Join-Path $releaseDir "*") -DestinationPath $zipPath
Write-Host "GitHub release package created: $zipPath"
