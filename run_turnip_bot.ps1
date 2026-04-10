param(
  [string]$ConfigPath = "",
  [switch]$Execute
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$root = $PSScriptRoot
. (Join-Path $root "toolbear_env.ps1")
Load-ToolbearEnvironment -RootPath $root

$resolvedConfig = if ($ConfigPath) { (Resolve-Path $ConfigPath).Path } else { (Join-Path $root "turnip_bot_config.json") }
$scriptPath = Join-Path $root "toolbear_turnip_bot.ps1"

$args = @(
  "-NoProfile",
  "-ExecutionPolicy", "Bypass",
  "-File", $scriptPath,
  "-ConfigPath", $resolvedConfig
)

if ($Execute) {
  $args += "-Execute"
}

& powershell @args
