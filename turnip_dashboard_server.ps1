param(
  [string]$ConfigPath = ".\turnip_bot_config.json",
  [string]$BotStatePath = ".\turnip_bot_state.json",
  [string]$BotLogPath = ".\turnip_bot.log",
  [string]$Token,
  [int]$Port = 8848,
  [int]$ApiTimeoutSeconds = 5,
  [int]$CacheTtlSeconds = 8,
  [switch]$NoBrowser
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

function Get-Config {
  param([string]$Path)
  if (-not (Test-Path $Path)) {
    throw "Config not found: $Path"
  }
  return Get-Content $Path -Encoding UTF8 -Raw | ConvertFrom-Json
}

function Resolve-Token {
  param(
    [string]$CliToken,
    $Config
  )

  if ($CliToken) {
    return $CliToken
  }

  $envName = [string]$Config.token_env_var
  if ($envName) {
    $envValue = [Environment]::GetEnvironmentVariable($envName)
    if ($envValue) {
      return $envValue
    }
  }

  throw "Missing token. Pass -Token or set the environment variable defined by token_env_var."
}

function Invoke-ToolbearApi {
  param(
    [string]$BaseUrl,
    [string]$TokenValue,
    [string]$Path,
    [int]$TimeoutSeconds = 5
  )

  $uri = "{0}{1}" -f $BaseUrl.TrimEnd("/"), $Path
  $headers = @{ Authorization = "Bearer $TokenValue" }
  return Invoke-RestMethod -Headers $headers -Uri $uri -Method Get -TimeoutSec $TimeoutSeconds
}

function Get-ApiResultOrFallback {
  param(
    [string]$Name,
    [string]$BaseUrl,
    [string]$TokenValue,
    [string]$Path,
    [int]$TimeoutSeconds,
    $FallbackValue
  )

  try {
    $value = Invoke-ToolbearApi -BaseUrl $BaseUrl -TokenValue $TokenValue -Path $Path -TimeoutSeconds $TimeoutSeconds
    return @{
      success = $true
      value = $value
      error = $null
      source = "live"
    }
  } catch {
    return @{
      success = $false
      value = $FallbackValue
      error = "$Name failed: $($_.Exception.Message)"
      source = if ($null -ne $FallbackValue) { "cache" } else { "empty" }
    }
  }
}

function ConvertTo-DecimalValue {
  param($Value)
  if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
    return [decimal]0
  }
  return [decimal]::Parse([string]$Value, [System.Globalization.CultureInfo]::InvariantCulture)
}

function Get-JsonFileOrDefault {
  param(
    [string]$Path,
    $DefaultValue
  )

  if (-not (Test-Path $Path)) {
    return $DefaultValue
  }

  try {
    return Get-Content $Path -Encoding UTF8 -Raw | ConvertFrom-Json
  } catch {
    return $DefaultValue
  }
}

function Get-RecentLogLines {
  param(
    [string]$Path,
    [int]$Count = 120
  )

  if (-not (Test-Path $Path)) {
    return @()
  }

  return @(
    Get-Content -Path $Path -Encoding UTF8 -Tail $Count | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
  )
}

function Get-DashboardPayload {
  param(
    [string]$BaseUrl,
    [string]$TokenValue,
    [string]$StatePath,
    [string]$LogPath,
    $Config,
    [int]$TimeoutSeconds,
    $PreviousPayload
  )

  $marketResult = Get-ApiResultOrFallback -Name "market" -BaseUrl $BaseUrl -TokenValue $TokenValue -Path "/api/turnip/market" -TimeoutSeconds $TimeoutSeconds -FallbackValue $PreviousPayload.market
  $depthResult = Get-ApiResultOrFallback -Name "depth" -BaseUrl $BaseUrl -TokenValue $TokenValue -Path "/api/turnip/depth" -TimeoutSeconds $TimeoutSeconds -FallbackValue $PreviousPayload.depth
  $inventoryResult = Get-ApiResultOrFallback -Name "inventory" -BaseUrl $BaseUrl -TokenValue $TokenValue -Path "/api/turnip/inventory" -TimeoutSeconds $TimeoutSeconds -FallbackValue $PreviousPayload.inventory
  $transactionsResult = Get-ApiResultOrFallback -Name "transactions" -BaseUrl $BaseUrl -TokenValue $TokenValue -Path "/api/turnip/transactions?limit=30&offset=0" -TimeoutSeconds $TimeoutSeconds -FallbackValue $PreviousPayload.turnip_transactions
  $walletResult = Get-ApiResultOrFallback -Name "wallet" -BaseUrl $BaseUrl -TokenValue $TokenValue -Path "/api/wallet/balance" -TimeoutSeconds $TimeoutSeconds -FallbackValue $PreviousPayload.wallet
  $walletStatsResult = Get-ApiResultOrFallback -Name "wallet_stats" -BaseUrl $BaseUrl -TokenValue $TokenValue -Path "/api/wallet/stats" -TimeoutSeconds $TimeoutSeconds -FallbackValue $PreviousPayload.wallet_stats

  $market = $marketResult.value
  $depth = $depthResult.value
  $inventory = $inventoryResult.value
  $transactions = $transactionsResult.value
  $wallet = $walletResult.value
  $walletStats = $walletStatsResult.value
  $state = Get-JsonFileOrDefault -Path $StatePath -DefaultValue @{
    tick_history = @()
    last_actions = @()
    last_order_at = @{ buy = $null; sell = $null }
    position_peak_profit_pct = $null
  }
  $logs = Get-RecentLogLines -Path $LogPath -Count 120

  $currentPrice = ConvertTo-DecimalValue $market.current_price
  $avgCost = ConvertTo-DecimalValue $inventory.avg_buy_price
  $settled = ConvertTo-DecimalValue $inventory.settled_quantity
  $pending = ConvertTo-DecimalValue $inventory.pending_quantity
  $estimatedPnL = if ($avgCost -gt 0 -and ($settled + $pending) -gt 0) {
    [math]::Round(([double](($currentPrice - $avgCost) * ($settled + $pending))), 2)
  } else {
    0.0
  }

  return [ordered]@{
    generated_at = (Get-Date).ToUniversalTime().ToString("o")
    config = $Config
    market = $market
    depth = $depth
    inventory = $inventory
    wallet = $wallet
    wallet_stats = $walletStats
    turnip_transactions = $transactions
    bot_state = $state
    bot_logs = $logs
    service = [ordered]@{
      cache_refreshed_at = (Get-Date).ToUniversalTime().ToString("o")
      api_timeout_seconds = $TimeoutSeconds
      errors = @(
        $marketResult.error
        $depthResult.error
        $inventoryResult.error
        $transactionsResult.error
        $walletResult.error
        $walletStatsResult.error
      ) | Where-Object { $_ }
      live_sources = @(
        "market:$($marketResult.source)"
        "depth:$($depthResult.source)"
        "inventory:$($inventoryResult.source)"
        "transactions:$($transactionsResult.source)"
        "wallet:$($walletResult.source)"
        "wallet_stats:$($walletStatsResult.source)"
      )
    }
    derived = [ordered]@{
      estimated_unrealized_pnl = $estimatedPnL
      open_exposure_quantity = [double]($settled + $pending)
      current_price = [double]$currentPrice
      avg_cost = [double]$avgCost
    }
  }
}

function Write-JsonResponse {
  param(
    $Context,
    $Payload,
    [int]$StatusCode = 200
  )

  $json = $Payload | ConvertTo-Json -Depth 20
  $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
  $Context.Response.StatusCode = $StatusCode
  $Context.Response.ContentType = "application/json; charset=utf-8"
  $Context.Response.ContentLength64 = $buffer.Length
  $Context.Response.OutputStream.Write($buffer, 0, $buffer.Length)
  $Context.Response.OutputStream.Close()
}

function Write-TextResponse {
  param(
    $Context,
    [string]$Content,
    [string]$ContentType = "text/html; charset=utf-8",
    [int]$StatusCode = 200
  )

  $buffer = [System.Text.Encoding]::UTF8.GetBytes($Content)
  $Context.Response.StatusCode = $StatusCode
  $Context.Response.ContentType = $ContentType
  $Context.Response.ContentLength64 = $buffer.Length
  $Context.Response.OutputStream.Write($buffer, 0, $buffer.Length)
  $Context.Response.OutputStream.Close()
}

$config = Get-Config -Path $ConfigPath
$baseUrl = [string]$config.base_url
$resolvedToken = Resolve-Token -CliToken $Token -Config $config
$htmlPath = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "turnip_dashboard.html"
$script:DashboardCache = [ordered]@{
  generated_at = $null
  config = $config
  market = $null
  depth = $null
  inventory = $null
  wallet = $null
  wallet_stats = $null
  turnip_transactions = $null
  bot_state = @{
    tick_history = @()
    last_actions = @()
    last_order_at = @{ buy = $null; sell = $null }
    position_peak_profit_pct = $null
  }
  bot_logs = @()
  service = @{
    cache_refreshed_at = $null
    api_timeout_seconds = $ApiTimeoutSeconds
    errors = @("Dashboard cache not loaded yet.")
    live_sources = @()
  }
  derived = @{
    estimated_unrealized_pnl = 0.0
    open_exposure_quantity = 0.0
    current_price = 0.0
    avg_cost = 0.0
  }
}
$script:LastRefreshUtc = [DateTime]::MinValue

if (-not (Test-Path $htmlPath)) {
  throw "Dashboard HTML not found: $htmlPath"
}

$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("http://localhost:$Port/")
$listener.Start()

Write-Host "Turnip dashboard is running at http://localhost:$Port/"

if (-not $NoBrowser) {
  Start-Process "http://localhost:$Port/"
}

try {
  while ($listener.IsListening) {
    $context = $listener.GetContext()
    $path = $context.Request.Url.AbsolutePath

    try {
      switch ($path) {
        "/" {
          $html = Get-Content -Path $htmlPath -Encoding UTF8 -Raw
          Write-TextResponse -Context $context -Content $html
          continue
        }
        "/favicon.ico" {
          Write-TextResponse -Context $context -Content "" -ContentType "image/x-icon" -StatusCode 204
          continue
        }
        "/api/dashboard" {
          $shouldRefresh = ((Get-Date).ToUniversalTime() - $script:LastRefreshUtc).TotalSeconds -ge $CacheTtlSeconds
          if ($shouldRefresh) {
            $payload = Get-DashboardPayload -BaseUrl $baseUrl -TokenValue $resolvedToken -StatePath $BotStatePath -LogPath $BotLogPath -Config $config -TimeoutSeconds $ApiTimeoutSeconds -PreviousPayload $script:DashboardCache
            $script:DashboardCache = $payload
            $script:LastRefreshUtc = (Get-Date).ToUniversalTime()
          }
          Write-JsonResponse -Context $context -Payload $script:DashboardCache
          continue
        }
        "/api/health" {
          Write-JsonResponse -Context $context -Payload @{
            ok = $true
            port = $Port
            cache_refreshed_at = $script:DashboardCache.service.cache_refreshed_at
            errors = $script:DashboardCache.service.errors
          }
          continue
        }
        default {
          Write-JsonResponse -Context $context -Payload @{ error = "Not found"; path = $path } -StatusCode 404
          continue
        }
      }
    } catch {
      Write-JsonResponse -Context $context -Payload @{
        error = $_.Exception.Message
        path = $path
      } -StatusCode 500
    }
  }
} finally {
  $listener.Stop()
  $listener.Close()
}
