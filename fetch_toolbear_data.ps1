param(
  [Parameter(Mandatory = $true)]
  [string]$Token,

  [string]$BaseUrl = "https://lilium.kuma.homes",

  [string]$OutputDir = ".\\toolbear_export"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$headers = @{
  Authorization = "Bearer $Token"
}

$endpoints = @(
  @{ Name = "me"; Path = "/api/auth/me" },
  @{ Name = "wallet_balance"; Path = "/api/wallet/balance" },
  @{ Name = "wallet_stats"; Path = "/api/wallet/stats" },
  @{ Name = "wallet_transactions"; Path = "/api/wallet/transactions?page=1&size=100" },
  @{ Name = "wealth_leaderboard"; Path = "/api/wallet/wealth_leaderboard?limit=100" },
  @{ Name = "economy_overview"; Path = "/api/economy/overview" }
)

New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

foreach ($endpoint in $endpoints) {
  $uri = "{0}{1}" -f $BaseUrl.TrimEnd("/"), $endpoint.Path
  $data = Invoke-RestMethod -Headers $headers -Uri $uri
  $path = Join-Path $OutputDir ($endpoint.Name + ".json")
  $data | ConvertTo-Json -Depth 100 | Set-Content -Path $path -Encoding UTF8
  Write-Host ("Exported {0} -> {1}" -f $endpoint.Name, $path)
}
