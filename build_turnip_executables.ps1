Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$root = $PSScriptRoot
$distDir = Join-Path $root "dist"
$exeDir = Join-Path $distDir "toolbear-turnip-exe"
$dashboardScript = Join-Path $root "turnip_dashboard_server.py"
$suiteScript = Join-Path $root "run_turnip_suite.ps1"
$dashboardExe = Join-Path $root "turnip_dashboard_server.exe"
$suiteExe = Join-Path $exeDir "ToolBearTurnipSuite.exe"

New-Item -Path $exeDir -ItemType Directory -Force | Out-Null

python -m pip install --user pyinstaller | Out-Host

try {
  Import-Module ps2exe -ErrorAction Stop
} catch {
  Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser | Out-Null
  Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
  Install-Module -Name ps2exe -Scope CurrentUser -Force -AllowClobber
  Import-Module ps2exe -ErrorAction Stop
}

$pyInstallerArgs = @(
  "-m", "PyInstaller",
  "--onefile",
  "--clean",
  "--name", "turnip_dashboard_server",
  "--distpath", $root,
  "--workpath", (Join-Path $distDir "pyinstaller-build"),
  "--specpath", (Join-Path $distDir "pyinstaller-spec"),
  $dashboardScript
)

& python @pyInstallerArgs

Invoke-PS2EXE `
  -inputFile $suiteScript `
  -outputFile $suiteExe `
  -noConsole `
  -title "ToolBear Turnip Suite" `
  -description "Launches the ToolBear turnip bot and dashboard." `
  -company "Telep" `
  -product "ToolBear Turnip Suite"

$releaseFiles = @(
  "README.md",
  ".env.example",
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

foreach ($file in $releaseFiles) {
  Copy-Item -Path (Join-Path $root $file) -Destination (Join-Path $exeDir $file) -Force
}

if (Test-Path $dashboardExe) {
  Copy-Item -Path $dashboardExe -Destination (Join-Path $exeDir "turnip_dashboard_server.exe") -Force
}

Write-Host "Executable bundle created in: $exeDir"
