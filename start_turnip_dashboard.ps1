param(
  [int]$Port = 8856,
  [string]$ConfigPath = ".\turnip_bot_config.json",
  [string]$Token
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$serverPath = Join-Path $PSScriptRoot "turnip_dashboard_server.py"
if (-not (Test-Path $serverPath)) {
  throw "Dashboard server not found: $serverPath"
}

$args = @(
  $serverPath,
  "--config-path", (Resolve-Path $ConfigPath).Path,
  "--port", [string]$Port
)

if ($Token) {
  $args += @("--token", $Token)
}

Start-Process python -ArgumentList $args | Out-Null
