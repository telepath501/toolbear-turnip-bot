param(
  [int]$Port = 8862,
  [string]$ConfigPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$root = $PSScriptRoot
. (Join-Path $root "toolbear_env.ps1")
Load-ToolbearEnvironment -RootPath $root

$resolvedConfig = if ($ConfigPath) { (Resolve-Path $ConfigPath).Path } else { (Join-Path $root "turnip_bot_config.json") }
$serverPath = Join-Path $root "turnip_dashboard_server.py"
$serverExePath = Join-Path $root "turnip_dashboard_server.exe"

if (Test-Path $serverExePath) {
  & $serverExePath --config-path $resolvedConfig --port $Port
} else {
  & python $serverPath --config-path $resolvedConfig --port $Port
}
