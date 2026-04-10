param(
  [string]$ConfigPath = ".\turnip_bot_config.json",
  [string]$Token,
  [switch]$Execute,
  [switch]$Once
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

function Write-Log {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Message,

    [string]$Level = "INFO"
  )

  $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
  $line = "[{0}] [{1}] {2}" -f $timestamp, $Level.ToUpperInvariant(), $Message
  Write-Host $line
  if ($script:LogPath) {
    Add-Content -Path $script:LogPath -Value $line -Encoding UTF8
  }
}

function ConvertTo-Decimal {
  param($Value)
  if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
    return [decimal]0
  }
  return [decimal]::Parse([string]$Value, [System.Globalization.CultureInfo]::InvariantCulture)
}

function ConvertTo-DoubleValue {
  param($Value)
  if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
    return [double]0
  }
  return [double]::Parse([string]$Value, [System.Globalization.CultureInfo]::InvariantCulture)
}

function Get-Config {
  param([string]$Path)
  if (-not (Test-Path $Path)) {
    throw "Config not found: $Path"
  }
  return Get-Content $Path -Raw | ConvertFrom-Json
}

function Resolve-ConfigRelativePath {
  param(
    [string]$ConfigPath,
    [string]$TargetPath
  )

  if ([string]::IsNullOrWhiteSpace($TargetPath)) {
    return $TargetPath
  }

  if ([System.IO.Path]::IsPathRooted($TargetPath)) {
    return [System.IO.Path]::GetFullPath($TargetPath)
  }
  return [System.IO.Path]::GetFullPath((Join-Path -Path (Split-Path -Parent $ConfigPath) -ChildPath $TargetPath))
}

function ConvertTo-Hashtable {
  param($InputObject)

  if ($null -eq $InputObject) {
    return $null
  }

  if ($InputObject -is [System.Collections.IDictionary]) {
    $result = @{}
    foreach ($key in $InputObject.Keys) {
      $result[$key] = ConvertTo-Hashtable $InputObject[$key]
    }
    return $result
  }

  if ($InputObject -is [System.Collections.IEnumerable] -and -not ($InputObject -is [string])) {
    $items = @()
    foreach ($item in $InputObject) {
      $items += ,(ConvertTo-Hashtable $item)
    }
    return $items
  }

  if ($InputObject -is [psobject]) {
    $props = $InputObject.PSObject.Properties
    if ($props.Count -gt 0) {
      $result = @{}
      foreach ($prop in $props) {
        $result[$prop.Name] = ConvertTo-Hashtable $prop.Value
      }
      return $result
    }
  }

  return $InputObject
}

function Get-ObjectValue {
  param(
    $InputObject,
    [string]$Name
  )

  if ($null -eq $InputObject) {
    return $null
  }

  if ($InputObject -is [System.Collections.IDictionary]) {
    if ($InputObject.Contains($Name)) {
      return $InputObject[$Name]
    }
    return $null
  }

  $prop = $InputObject.PSObject.Properties[$Name]
  if ($null -ne $prop) {
    return $prop.Value
  }

  return $null
}

function Resolve-Token {
  param(
    [string]$CliToken,
    $Config
  )

  if ($CliToken) {
    return $CliToken
  }

  if ($Config.token_env_var) {
    $envValue = [Environment]::GetEnvironmentVariable([string]$Config.token_env_var)
    if ($envValue) {
      return $envValue
    }
  }

  throw "Missing token. Pass -Token or set the environment variable defined by token_env_var."
}

function New-State {
  return @{
    tick_history = @()
    last_actions = @()
    last_order_at = @{
      buy = $null
      sell = $null
    }
    position_peak_profit_pct = $null
    sell_ladder = @{
      anchor_total_quantity = 0
      anchor_avg_cost = "0"
      executed_tiers = @()
    }
  }
}

function Read-TickHistoryFromDisk {
  param(
    [string]$Path,
    [int]$WindowHours = 6
  )

  if (-not $Path -or -not (Test-Path $Path)) {
    return @()
  }

  $cutoff = (Get-Date).ToUniversalTime().AddHours(-1 * $WindowHours)
  $rows = New-Object System.Collections.Generic.List[object]
  foreach ($line in Get-Content -Path $Path -Encoding UTF8) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    try {
      $row = $line | ConvertFrom-Json
      $stamp = [DateTime]::Parse((Get-ObjectValue -InputObject $row -Name "timestamp"), [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
      if ($stamp -ge $cutoff) {
        $rows.Add($row)
      }
    } catch {
      continue
    }
  }
  return $rows.ToArray()
}

function Write-TickHistoryToDisk {
  param(
    [string]$Path,
    [hashtable]$TickRow
  )

  if (-not $Path) { return }
  ($TickRow | ConvertTo-Json -Compress -Depth 10) | Add-Content -Path $Path -Encoding UTF8
}

function Trim-TickHistoryDisk {
  param(
    [string]$Path,
    [int]$WindowHours = 6
  )

  if (-not $Path -or -not (Test-Path $Path)) {
    return
  }

  $cutoff = (Get-Date).ToUniversalTime().AddHours(-1 * $WindowHours)
  $kept = New-Object System.Collections.Generic.List[string]
  foreach ($line in Get-Content -Path $Path -Encoding UTF8) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    try {
      $row = $line | ConvertFrom-Json
      $stamp = [DateTime]::Parse((Get-ObjectValue -InputObject $row -Name "timestamp"), [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
      if ($stamp -ge $cutoff) {
        $kept.Add($line)
      }
    } catch {
      continue
    }
  }
  Set-Content -Path $Path -Value $kept -Encoding UTF8
}

function Get-State {
  param([string]$Path)

  if (-not (Test-Path $Path)) {
    return New-State
  }

  try {
    $raw = Get-Content $Path -Raw | ConvertFrom-Json
    if ($null -eq $raw) {
      return New-State
    }

    $state = New-State
    $state.tick_history = @((Get-ObjectValue -InputObject $raw -Name "tick_history"))
    $state.last_actions = @((Get-ObjectValue -InputObject $raw -Name "last_actions"))

    $lastOrderAt = Get-ObjectValue -InputObject $raw -Name "last_order_at"
    if ($null -ne $lastOrderAt) {
      $state.last_order_at = @{
        buy = Get-ObjectValue -InputObject $lastOrderAt -Name "buy"
        sell = Get-ObjectValue -InputObject $lastOrderAt -Name "sell"
      }
    }

    $state.position_peak_profit_pct = Get-ObjectValue -InputObject $raw -Name "position_peak_profit_pct"

    $sellLadder = Get-ObjectValue -InputObject $raw -Name "sell_ladder"
    if ($null -ne $sellLadder) {
      $state.sell_ladder = @{
        anchor_total_quantity = [int](Get-ObjectValue -InputObject $sellLadder -Name "anchor_total_quantity")
        anchor_avg_cost = [string](Get-ObjectValue -InputObject $sellLadder -Name "anchor_avg_cost")
        executed_tiers = @((Get-ObjectValue -InputObject $sellLadder -Name "executed_tiers"))
      }
    }

    return $state
  } catch {
    Write-Log "State file is unreadable. Starting with a fresh state." "WARN"
    return New-State
  }
}

function Save-State {
  param(
    [hashtable]$State,
    [string]$Path
  )

  $State | ConvertTo-Json -Depth 20 | Set-Content -Path $Path -Encoding UTF8
}

function Register-Action {
  param(
    [hashtable]$State,
    [hashtable]$Action
  )

  $actions = @($State.last_actions)
  $actions += $Action
  if ($actions.Count -gt 100) {
    $actions = @($actions | Select-Object -Last 100)
  }
  $State.last_actions = $actions
}

function Register-OrderTimestamp {
  param(
    [hashtable]$State,
    [string]$Side
  )

  $State.last_order_at[$Side] = (Get-Date).ToUniversalTime().ToString("o")
}

function Get-CooldownExpired {
  param(
    [hashtable]$State,
    [string]$Side,
    [int]$CooldownMinutes
  )

  $stamp = $State.last_order_at[$Side]
  if (-not $stamp) {
    return $true
  }

  $lastTrade = [DateTime]::Parse($stamp, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
  return ((Get-Date).ToUniversalTime() - $lastTrade).TotalMinutes -ge $CooldownMinutes
}

function Invoke-ToolbearApi {
  param(
    [ValidateSet("GET", "POST")]
    [string]$Method,
    [string]$Path,
    $Body
  )

  $uri = "{0}{1}" -f $script:BaseUrl.TrimEnd("/"), $Path
  $headers = @{ Authorization = "Bearer $script:Token" }

  if ($Method -eq "GET") {
    return Invoke-RestMethod -Headers $headers -Uri $uri -Method Get
  }

  $jsonBody = if ($null -ne $Body) { $Body | ConvertTo-Json -Depth 20 -Compress } else { "{}" }
  return Invoke-RestMethod -Headers $headers -Uri $uri -Method Post -Body $jsonBody -ContentType "application/json"
}

function Get-WalletBalance {
  return Invoke-ToolbearApi -Method GET -Path "/api/wallet/balance"
}

function Get-TurnipInventory {
  return Invoke-ToolbearApi -Method GET -Path "/api/turnip/inventory"
}

function Get-TurnipMarket {
  return Invoke-ToolbearApi -Method GET -Path "/api/turnip/market"
}

function Get-TurnipDepth {
  return Invoke-ToolbearApi -Method GET -Path "/api/turnip/depth"
}

function Invoke-TurnipBuy {
  param(
    [int]$Quantity,
    [decimal]$MaxPrice
  )

  $payload = @{
    quantity = [string]$Quantity
  }

  if ($MaxPrice -gt 0) {
    $payload.max_price = $MaxPrice.ToString("0.00", [System.Globalization.CultureInfo]::InvariantCulture)
  }

  return Invoke-ToolbearApi -Method POST -Path "/api/turnip/buy" -Body $payload
}

function Invoke-TurnipSell {
  param(
    [int]$Quantity,
    [decimal]$MinPrice
  )

  $payload = @{
    quantity = [string]$Quantity
  }

  if ($MinPrice -gt 0) {
    $payload.min_price = $MinPrice.ToString("0.00", [System.Globalization.CultureInfo]::InvariantCulture)
  }

  return Invoke-ToolbearApi -Method POST -Path "/api/turnip/sell" -Body $payload
}

function Normalize-SpreadPct {
  param($Value)

  if ($null -eq $Value) {
    return [double]0
  }

  $numeric = ConvertTo-DoubleValue $Value
  if ($numeric -le 1.0) {
    return [math]::Round($numeric * 100.0, 4)
  }

  return [math]::Round($numeric, 4)
}

function Get-QuoteSpreadPct {
  param(
    $Bid,
    $Ask,
    $MidPrice
  )

  $bidValue = ConvertTo-DoubleValue $Bid
  $askValue = ConvertTo-DoubleValue $Ask
  $midValue = ConvertTo-DoubleValue $MidPrice
  if ($bidValue -le 0 -or $askValue -le 0) {
    return $null
  }

  $base = if ($midValue -gt 0) { $midValue } else { (($bidValue + $askValue) / 2.0) }
  if ($base -le 0) {
    return $null
  }

  return [math]::Round((($askValue - $bidValue) / $base) * 100.0, 4)
}

function Get-TopLevelMicroprice {
  param(
    [object[]]$Bids,
    [object[]]$Asks
  )

  $bestBid = @($Bids | Select-Object -First 1)
  $bestAsk = @($Asks | Select-Object -First 1)
  if ($bestBid.Count -eq 0 -or $bestAsk.Count -eq 0) {
    return $null
  }

  $bidPrice = ConvertTo-DoubleValue $bestBid[0].price
  $askPrice = ConvertTo-DoubleValue $bestAsk[0].price
  $bidQty = ConvertTo-DoubleValue $bestBid[0].quantity
  $askQty = ConvertTo-DoubleValue $bestAsk[0].quantity
  if ($bidPrice -le 0 -or $askPrice -le 0 -or ($bidQty + $askQty) -le 0) {
    return $null
  }

  $micro = (($askPrice * $bidQty) + ($bidPrice * $askQty)) / ($bidQty + $askQty)
  return [math]::Round($micro, 4)
}

function Get-RecentTradeVwap {
  param([object[]]$Trades)

  $notional = 0.0
  $volume = 0.0

  foreach ($trade in @($Trades | Select-Object -First 20)) {
    $qty = ConvertTo-DoubleValue $trade.qty
    $price = ConvertTo-DoubleValue $trade.price
    if ($qty -le 0 -or $price -le 0) {
      continue
    }

    $notional += ($qty * $price)
    $volume += $qty
  }

  if ($volume -le 0) {
    return $null
  }

  return [math]::Round(($notional / $volume), 4)
}

function Get-InstantFairValue {
  param(
    $MidPrice,
    [object[]]$Bids,
    [object[]]$Asks,
    [object[]]$Trades
  )

  $components = New-Object System.Collections.Generic.List[double]
  $weights = New-Object System.Collections.Generic.List[double]

  $mid = ConvertTo-DoubleValue $MidPrice
  if ($mid -gt 0) {
    $components.Add($mid)
    $weights.Add(0.35)
  }

  $micro = Get-TopLevelMicroprice -Bids $Bids -Asks $Asks
  if ($null -ne $micro -and $micro -gt 0) {
    $components.Add([double]$micro)
    $weights.Add(0.45)
  }

  $tradeVwap = Get-RecentTradeVwap -Trades $Trades
  if ($null -ne $tradeVwap -and $tradeVwap -gt 0) {
    $components.Add([double]$tradeVwap)
    $weights.Add(0.20)
  }

  if ($components.Count -eq 0) {
    return [decimal]0
  }

  $weightedSum = 0.0
  $totalWeight = 0.0
  for ($i = 0; $i -lt $components.Count; $i++) {
    $weightedSum += ($components[$i] * $weights[$i])
    $totalWeight += $weights[$i]
  }

  return [decimal][math]::Round(($weightedSum / $totalWeight), 4)
}

function New-TickFromMarketData {
  param(
    $Market,
    $Depth
  )

  $midPrice = if ($Depth.mid_price) { [string]$Depth.mid_price } else { [string]$Market.current_price }
  $bid = if ($Depth.bid) { [string]$Depth.bid } else { [string]$Market.bid }
  $ask = if ($Depth.ask) { [string]$Depth.ask } else { [string]$Market.ask }
  $spreadPct = Get-QuoteSpreadPct -Bid $bid -Ask $ask -MidPrice $midPrice
  if ($null -eq $spreadPct) {
    $spreadPct = Normalize-SpreadPct $Market.spread_pct
  }

  $recentTrades = @($Market.recent_trades)
  $bids = @($Depth.bids)
  $asks = @($Depth.asks)
  $fairValue = Get-InstantFairValue -MidPrice $midPrice -Bids $bids -Asks $asks -Trades $recentTrades

  return [pscustomobject]@{
    type = "turnip"
    mid_price = $midPrice
    fair_value = $fairValue.ToString("0.0000", [System.Globalization.CultureInfo]::InvariantCulture)
    bid = $bid
    ask = $ask
    spread_pct = $spreadPct
    depth = [string]$Depth.depth
    bids = $bids
    asks = $asks
    recent_trades = $recentTrades
    updated_at = (Get-Date).ToUniversalTime().ToString("o")
    trend = [string]$Market.trend
    trend_hour = $Market.trend_hour
    cycle_progress = $Market.cycle_progress
    total_holders = $Market.total_holders
    source = "turnip_market_api"
  }
}

function Get-RecentTradeImbalance {
  param($Tick)

  $buyVolume = 0.0
  $sellVolume = 0.0

  foreach ($trade in @($Tick.recent_trades | Select-Object -First 20)) {
    $qty = ConvertTo-DoubleValue $trade.qty
    if ([string]$trade.side -eq "buy") {
      $buyVolume += $qty
    } elseif ([string]$trade.side -eq "sell") {
      $sellVolume += $qty
    }
  }

  if (($buyVolume + $sellVolume) -le 0) {
    return 0.0
  }

  return [math]::Round((($buyVolume - $sellVolume) / ($buyVolume + $sellVolume)), 4)
}

function New-TurnipBuyOrder {
  param(
    [int]$Quantity,
    [decimal]$ReferenceAsk,
    $Strategy
  )

  $maxPrice = [decimal][math]::Round([double]($ReferenceAsk * [decimal](1.0 + ([double]$Strategy.buy_slippage_limit_pct / 100.0))), 2)
  return Invoke-TurnipBuy -Quantity $Quantity -MaxPrice $maxPrice
}

function New-TurnipSellOrder {
  param(
    [int]$Quantity,
    [decimal]$ReferenceBid,
    $Strategy
  )

  $minPrice = [decimal][math]::Round([double]($ReferenceBid * [decimal](1.0 - ([double]$Strategy.sell_slippage_limit_pct / 100.0))), 2)
  return Invoke-TurnipSell -Quantity $Quantity -MinPrice $minPrice
}

function Add-TickObservation {
  param(
    [hashtable]$State,
    $Tick
  )

  $tickRow = @{
    timestamp = (Get-Date).ToUniversalTime().ToString("o")
    mid_price = [string]$Tick.mid_price
    fair_value = [string]$Tick.fair_value
    bid = if ($null -ne $Tick.bid) { [string]$Tick.bid } else { $null }
    ask = if ($null -ne $Tick.ask) { [string]$Tick.ask } else { $null }
    spread_pct = if ($null -ne $Tick.spread_pct) { [double]$Tick.spread_pct } else { [double]0 }
    depth = if ($null -ne $Tick.depth) { [string]$Tick.depth } else { "0" }
  }

  Write-TickHistoryToDisk -Path $script:TickHistoryPath -TickRow $tickRow
  $history = @($State.tick_history)
  $history += $tickRow
  if ($history.Count -gt 180) {
    $history = @($history | Select-Object -Last 180)
  }
  $State.tick_history = $history
}

function Get-HistoryWindow {
  param(
    [object[]]$History,
    [int]$WindowMinutes
  )

  $cutoff = (Get-Date).ToUniversalTime().AddMinutes(-1 * $WindowMinutes)
  return @(
    $History | Where-Object {
      [DateTime]::Parse((Get-ObjectValue -InputObject $_ -Name "timestamp"), [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind) -ge $cutoff
    } | Sort-Object {
      [DateTime]::Parse((Get-ObjectValue -InputObject $_ -Name "timestamp"), [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
    }
  )
}

function Get-WindowReturnPct {
  param(
    [object[]]$History,
    [int]$WindowMinutes
  )

  $window = Get-HistoryWindow -History $History -WindowMinutes $WindowMinutes
  if ($window.Count -lt 2) {
    return $null
  }

  $startPrice = ConvertTo-DoubleValue (Get-ObjectValue -InputObject $window[0] -Name "mid_price")
  $endPrice = ConvertTo-DoubleValue (Get-ObjectValue -InputObject $window[-1] -Name "mid_price")
  if ($startPrice -le 0 -or $endPrice -le 0) {
    return $null
  }

  return [math]::Round((($endPrice / $startPrice) - 1.0) * 100.0, 4)
}

function Get-MeanAndStd {
  param(
    [object[]]$History,
    [int]$WindowMinutes
  )

  $window = Get-HistoryWindow -History $History -WindowMinutes $WindowMinutes
  if ($window.Count -lt 5) {
    return $null
  }

  $prices = New-Object System.Collections.Generic.List[double]
  foreach ($row in $window) {
    $price = ConvertTo-DoubleValue (Get-ObjectValue -InputObject $row -Name "mid_price")
    if ($price -gt 0) {
      $prices.Add($price)
    }
  }

  if ($prices.Count -lt 5) {
    return $null
  }

  $mean = ($prices | Measure-Object -Average).Average
  $sum = 0.0
  foreach ($value in $prices) {
    $sum += [math]::Pow(($value - $mean), 2)
  }

  $std = [math]::Sqrt($sum / [math]::Max(1, ($prices.Count - 1)))
  return @{
    mean = [math]::Round($mean, 4)
    std = [math]::Round($std, 4)
  }
}

function Get-PriceZScore {
  param(
    [object[]]$History,
    [int]$WindowMinutes
  )

  $stats = Get-MeanAndStd -History $History -WindowMinutes $WindowMinutes
  if ($null -eq $stats -or $stats.std -le 0) {
    return $null
  }

  $latest = @($History | Sort-Object {
    [DateTime]::Parse((Get-ObjectValue -InputObject $_ -Name "timestamp"), [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
  } | Select-Object -Last 1)

  if ($latest.Count -eq 0) {
    return $null
  }

  $lastPrice = ConvertTo-DoubleValue (Get-ObjectValue -InputObject $latest[0] -Name "mid_price")
  if ($lastPrice -le 0) {
    return $null
  }

  return [math]::Round((($lastPrice - [double]$stats.mean) / [double]$stats.std), 4)
}

function Get-VolatilityPct {
  param(
    [object[]]$History,
    [int]$WindowMinutes
  )

  $window = Get-HistoryWindow -History $History -WindowMinutes $WindowMinutes
  if ($window.Count -lt 5) {
    return $null
  }

  $returns = New-Object System.Collections.Generic.List[double]
  for ($i = 1; $i -lt $window.Count; $i++) {
    $prev = ConvertTo-DoubleValue (Get-ObjectValue -InputObject $window[$i - 1] -Name "mid_price")
    $curr = ConvertTo-DoubleValue (Get-ObjectValue -InputObject $window[$i] -Name "mid_price")
    if ($prev -le 0 -or $curr -le 0) {
      continue
    }
    $returns.Add((($curr / $prev) - 1.0) * 100.0)
  }

  if ($returns.Count -lt 4) {
    return $null
  }

  $mean = ($returns | Measure-Object -Average).Average
  $sum = 0.0
  foreach ($value in $returns) {
    $sum += [math]::Pow(($value - $mean), 2)
  }

  return [math]::Round([math]::Sqrt($sum / ($returns.Count - 1)), 4)
}

function Get-PercentileValue {
  param(
    [double[]]$SortedValues,
    [double]$Percentile
  )

  if ($null -eq $SortedValues -or $SortedValues.Count -eq 0) {
    return $null
  }

  $p = [math]::Max(0.0, [math]::Min(1.0, $Percentile))
  if ($SortedValues.Count -eq 1) {
    return [double]$SortedValues[0]
  }

  $index = $p * ($SortedValues.Count - 1)
  $lower = [int][math]::Floor($index)
  $upper = [int][math]::Ceiling($index)
  if ($lower -eq $upper) {
    return [double]$SortedValues[$lower]
  }

  $weight = $index - $lower
  return ([double]$SortedValues[$lower] * (1.0 - $weight)) + ([double]$SortedValues[$upper] * $weight)
}

function Get-WindowPriceRangeStats {
  param(
    [object[]]$History,
    [int]$WindowMinutes,
    [double]$TrimPercentile = 0.15
  )

  $window = Get-HistoryWindow -History $History -WindowMinutes $WindowMinutes
  if ($window.Count -lt 10) {
    return $null
  }

  $prices = New-Object System.Collections.Generic.List[double]
  foreach ($row in $window) {
    $price = ConvertTo-DoubleValue (Get-ObjectValue -InputObject $row -Name "mid_price")
    if ($price -gt 0) {
      $prices.Add($price)
    }
  }

  if ($prices.Count -lt 10) {
    return $null
  }

  $sorted = @($prices | Sort-Object)
  $robustLow = Get-PercentileValue -SortedValues $sorted -Percentile $TrimPercentile
  $robustHigh = Get-PercentileValue -SortedValues $sorted -Percentile (1.0 - $TrimPercentile)
  $minValue = ($sorted | Measure-Object -Minimum).Minimum
  $maxValue = ($sorted | Measure-Object -Maximum).Maximum

  return @{
    low = [math]::Round([double]$minValue, 4)
    high = [math]::Round([double]$maxValue, 4)
    robust_low = [math]::Round([double]$robustLow, 4)
    robust_high = [math]::Round([double]$robustHigh, 4)
  }
}

function Get-OrderBookImbalance {
  param($Tick)

  $bidTotal = 0.0
  $askTotal = 0.0

  foreach ($level in @($Tick.bids | Select-Object -First 5)) {
    $bidTotal += ConvertTo-DoubleValue $level.quantity
  }

  foreach ($level in @($Tick.asks | Select-Object -First 5)) {
    $askTotal += ConvertTo-DoubleValue $level.quantity
  }

  if (($bidTotal + $askTotal) -le 0) {
    return 0.0
  }

  return [math]::Round((($bidTotal - $askTotal) / ($bidTotal + $askTotal)), 4)
}

function Get-InventoryQuantity {
  param($Inventory)
  return [int][Math]::Floor((ConvertTo-DoubleValue $Inventory.total_quantity))
}

function Get-SettledInventoryQuantity {
  param($Inventory)
  return [int][Math]::Floor((ConvertTo-DoubleValue $Inventory.settled_quantity))
}

function Get-PendingInventoryQuantity {
  param($Inventory)
  return [int][Math]::Floor((ConvertTo-DoubleValue $Inventory.pending_quantity))
}

function Reset-SellLadderState {
  param([hashtable]$State)

  $State.sell_ladder = @{
    anchor_total_quantity = 0
    anchor_avg_cost = "0"
    executed_tiers = @()
  }
}

function Sync-SellLadderState {
  param(
    [hashtable]$State,
    $Inventory
  )

  if ($null -eq $State.sell_ladder) {
    Reset-SellLadderState -State $State
  }

  $settledCostBasis = Get-SellableSettledCostBasis -Inventory $Inventory
  $totalQty = [int](Get-ObjectValue -InputObject $settledCostBasis -Name "quantity")
  $avgCost = ConvertTo-Decimal (Get-ObjectValue -InputObject $settledCostBasis -Name "avg_buy_price")
  $anchorQty = [int](Get-ObjectValue -InputObject $State.sell_ladder -Name "anchor_total_quantity")
  $anchorAvgCost = ConvertTo-Decimal (Get-ObjectValue -InputObject $State.sell_ladder -Name "anchor_avg_cost")

  if ($totalQty -le 0 -or $avgCost -le 0) {
    Reset-SellLadderState -State $State
    return
  }

  $avgCostShiftPct = 0.0
  if ($anchorAvgCost -gt 0) {
    $avgCostShiftPct = [math]::Abs((([double]$avgCost / [double]$anchorAvgCost) - 1.0) * 100.0)
  }

  if ($anchorQty -le 0 -or $totalQty -gt $anchorQty -or $avgCostShiftPct -ge 0.35) {
    $State.sell_ladder = @{
      anchor_total_quantity = $totalQty
      anchor_avg_cost = $avgCost.ToString("0.0000", [System.Globalization.CultureInfo]::InvariantCulture)
      executed_tiers = @()
    }
  }
}

function Get-SellLadderTierPlan {
  param(
    [double]$ProfitPct,
    [int]$AvailableToSell,
    [hashtable]$State,
    $Strategy
  )

  $tiers = @((Get-ObjectValue -InputObject $Strategy -Name "sell_ladder_tiers"))
  if ($tiers.Count -eq 0 -or $AvailableToSell -lt [int]$Strategy.min_trade_quantity) {
    return $null
  }

  if ($null -eq $State.sell_ladder) {
    Reset-SellLadderState -State $State
  }

  $executed = @((Get-ObjectValue -InputObject $State.sell_ladder -Name "executed_tiers"))
  $triggeredTiers = @()
  $cumulativeFraction = 0.0
  foreach ($tier in $tiers) {
    $tierProfit = [double](Get-ObjectValue -InputObject $tier -Name "profit_pct")
    $tierFraction = [double](Get-ObjectValue -InputObject $tier -Name "sell_fraction")
    if ($tierProfit -le 0 -or $tierFraction -le 0) {
      continue
    }

    $tierKey = [string]([math]::Round($tierProfit, 4))
    if ($executed -contains $tierKey) {
      continue
    }

    if ($ProfitPct -lt $tierProfit) {
      continue
    }

    $cumulativeFraction += $tierFraction
    $triggeredTiers += @{
      tier_key = $tierKey
      tier_profit_pct = $tierProfit
      sell_fraction = $tierFraction
    }
  }

  if ($triggeredTiers.Count -eq 0) {
    return $null
  }

  $effectiveFraction = [math]::Min(1.0, $cumulativeFraction)
  $qty = [int][math]::Floor($AvailableToSell * $effectiveFraction)
  if ($qty -lt [int]$Strategy.min_trade_quantity) {
    $qty = [int]$Strategy.min_trade_quantity
  }
  if ($qty -gt $AvailableToSell) {
    $qty = $AvailableToSell
  }

  $tierKeys = @($triggeredTiers | ForEach-Object { [string]$_.tier_key })
  $tierSummary = @($triggeredTiers | ForEach-Object { "{0}%:{1}%" -f ([math]::Round([double]$_.tier_profit_pct, 2)), ([math]::Round(([double]$_.sell_fraction * 100.0), 2)) })

  return @{
    tier_key = [string]$tierKeys[-1]
    tier_keys = $tierKeys
    tier_profit_pct = [double]$triggeredTiers[-1].tier_profit_pct
    sell_fraction = $effectiveFraction
    quantity = $qty
    tier_count = $triggeredTiers.Count
    tier_summary = ($tierSummary -join ", ")
  }
}

function Register-SellLadderExecution {
  param(
    [hashtable]$State,
    [object]$TierKey
  )

  if (-not $TierKey) {
    return
  }

  if ($null -eq $State.sell_ladder) {
    Reset-SellLadderState -State $State
  }

  $executed = @((Get-ObjectValue -InputObject $State.sell_ladder -Name "executed_tiers"))
  $tierKeys = @($TierKey)
  foreach ($key in $tierKeys) {
    $tierKeyValue = [string]$key
    if (-not $tierKeyValue) {
      continue
    }
    if ($executed -contains $tierKeyValue) {
      continue
    }
    $executed += $tierKeyValue
  }
  $State.sell_ladder.executed_tiers = $executed
}

function Get-InventoryCostBasis {
  param($Inventory)
  return ConvertTo-Decimal $Inventory.total_cost
}

function Get-InventoryBatchQuantity {
  param($Batch)

  $quantity = ConvertTo-Decimal (Get-ObjectValue -InputObject $Batch -Name "quantity")
  if ($quantity -gt 0) {
    return $quantity
  }

  $settledQuantity = ConvertTo-Decimal (Get-ObjectValue -InputObject $Batch -Name "settled_quantity")
  if ($settledQuantity -gt 0) {
    return $settledQuantity
  }

  return [decimal]0
}

function Get-InventoryBatchBuyPrice {
  param($Batch)

  $buyPrice = ConvertTo-Decimal (Get-ObjectValue -InputObject $Batch -Name "buy_price")
  if ($buyPrice -gt 0) {
    return $buyPrice
  }

  $totalCost = ConvertTo-Decimal (Get-ObjectValue -InputObject $Batch -Name "total_cost")
  $quantity = Get-InventoryBatchQuantity -Batch $Batch
  if ($totalCost -gt 0 -and $quantity -gt 0) {
    return [decimal][math]::Round([double]($totalCost / $quantity), 6)
  }

  return [decimal]0
}

function Test-InventoryBatchSettled {
  param($Batch)

  $isSettledValue = Get-ObjectValue -InputObject $Batch -Name "is_settled"
  if ($null -ne $isSettledValue) {
    return [bool]$isSettledValue
  }

  $pendingQuantity = ConvertTo-Decimal (Get-ObjectValue -InputObject $Batch -Name "pending_quantity")
  $quantity = Get-InventoryBatchQuantity -Batch $Batch
  if ($quantity -gt 0 -and $pendingQuantity -eq 0) {
    return $true
  }

  $settlesAt = [string](Get-ObjectValue -InputObject $Batch -Name "settles_at")
  if ($settlesAt) {
    try {
      $settlesAtUtc = [DateTimeOffset]::Parse($settlesAt).ToUniversalTime()
      return $settlesAtUtc -le [DateTimeOffset]::UtcNow
    } catch {
    }
  }

  return $false
}

function Get-SellableSettledCostBasis {
  param($Inventory)

  $settledTargetQty = Get-SettledInventoryQuantity -Inventory $Inventory
  if ($settledTargetQty -le 0) {
    return @{
      quantity = 0
      total_cost = [decimal]0
      avg_buy_price = [decimal]0
      batch_count = 0
      source = "none"
    }
  }

  $settledQty = [decimal]0
  $settledCost = [decimal]0
  $settledBatchCount = 0

  foreach ($batch in @($Inventory.batches)) {
    if (-not (Test-InventoryBatchSettled -Batch $batch)) {
      continue
    }

    $batchQty = Get-InventoryBatchQuantity -Batch $batch
    $batchPrice = Get-InventoryBatchBuyPrice -Batch $batch
    if ($batchQty -le 0 -or $batchPrice -le 0) {
      continue
    }

    $settledQty += $batchQty
    $settledCost += [decimal][math]::Round([double]($batchQty * $batchPrice), 6)
    $settledBatchCount += 1
  }

  if ($settledQty -gt 0 -and $settledCost -gt 0) {
    return @{
      quantity = [int][math]::Floor([double]$settledQty)
      total_cost = [decimal][math]::Round([double]$settledCost, 4)
      avg_buy_price = [decimal][math]::Round([double]($settledCost / $settledQty), 6)
      batch_count = $settledBatchCount
      source = "settled_batches"
    }
  }

  $fallbackAvg = ConvertTo-Decimal $Inventory.avg_buy_price
  if ($fallbackAvg -gt 0) {
    $fallbackQty = [decimal]$settledTargetQty
    return @{
      quantity = $settledTargetQty
      total_cost = [decimal][math]::Round([double]($fallbackAvg * $fallbackQty), 4)
      avg_buy_price = $fallbackAvg
      batch_count = 0
      source = "inventory_avg_fallback"
    }
  }

  return @{
    quantity = $settledTargetQty
    total_cost = [decimal]0
    avg_buy_price = [decimal]0
    batch_count = 0
    source = "missing"
  }
}

function Get-AvailableCash {
  param(
    $WalletBalance,
    $Strategy
  )

  $cash = ConvertTo-Decimal $WalletBalance.balance
  $buffer = [decimal]$Strategy.min_cash_buffer
  if ($cash -le $buffer) {
    return [decimal]0
  }
  return $cash - $buffer
}

function Get-DynamicBuyQuantity {
  param(
    [decimal]$ReferencePrice,
    [decimal]$AvailableCash,
    [decimal]$CurrentCostBasis,
    [double]$VolatilityPct,
    [double]$DiscountPct,
    $Strategy
  )

  if ($ReferencePrice -le 0 -or $AvailableCash -le 0) {
    return 0
  }

  $volFloor = [double]$Strategy.volatility_floor_pct
  $volCap = [double]$Strategy.volatility_entry_ceiling_pct
  $volScale = if ($volatilityPct -le $volFloor) { 1.0 } else { [math]::Max(0.25, [math]::Min(1.0, ($volCap - $volatilityPct) / [math]::Max(0.01, $volCap - $volFloor))) }
  $edgeScale = [math]::Max(0.55, [math]::Min(1.0, $DiscountPct / [double]$Strategy.fair_value_discount_entry_pct))
  $deployCash = $AvailableCash
  $remainingCapitalBudget = $AvailableCash

  if ($null -ne (Get-ObjectValue -InputObject $Strategy -Name "max_total_capital_deployed")) {
    $capitalCap = [decimal]$Strategy.max_total_capital_deployed
    $remainingCapitalBudget = [decimal][math]::Round([double]($capitalCap - $CurrentCostBasis), 2)
    if ($remainingCapitalBudget -le 0) {
      return 0
    }
    $deployCash = [decimal][math]::Min([double]$deployCash, [double]$remainingCapitalBudget)
  }

  $maxBuyFraction = [double](Get-ObjectValue -InputObject $Strategy -Name "max_buy_fraction_of_remaining_budget")
  if ($maxBuyFraction -gt 0 -and $maxBuyFraction -lt 1) {
    $fractionCap = [decimal][math]::Round([double]$deployCash * $maxBuyFraction, 2)
    if ($fractionCap -gt 0) {
      $deployCash = [decimal][math]::Min([double]$deployCash, [double]$fractionCap)
    }
  }

  $deployCash = [decimal][math]::Round(([double]$deployCash * $volScale * $edgeScale), 2)
  $deployCash = [decimal][math]::Min([double]$deployCash, [double]$AvailableCash)
  if ($remainingCapitalBudget -gt 0) {
    $deployCash = [decimal][math]::Min([double]$deployCash, [double]$remainingCapitalBudget)
  }

  if ($deployCash -lt ($ReferencePrice * [decimal][int]$Strategy.min_trade_quantity)) {
    return 0
  }

  $rawQty = [int][math]::Floor([double]($deployCash / $ReferencePrice))
  $qty = $rawQty

  if ($qty -lt [int]$Strategy.min_trade_quantity) {
    return 0
  }

  return $qty
}

function Get-BuyTrendContext {
  param(
    $Tick,
    [object[]]$History,
    $Strategy
  )

  $mid = ConvertTo-DoubleValue $Tick.mid_price
  $ret10 = Get-WindowReturnPct -History $History -WindowMinutes 10
  $ret15 = Get-WindowReturnPct -History $History -WindowMinutes 15
  $ret30 = Get-WindowReturnPct -History $History -WindowMinutes 30
  $ret60 = Get-WindowReturnPct -History $History -WindowMinutes 60

  $confirmWindowMinutes = [int](Get-ObjectValue -InputObject $Strategy -Name "entry_confirmation_window_minutes")
  if ($confirmWindowMinutes -le 0) {
    $confirmWindowMinutes = 18
  }
  $confirmTrim = [double](Get-ObjectValue -InputObject $Strategy -Name "entry_confirmation_trim_percentile")
  if ($confirmTrim -le 0 -or $confirmTrim -ge 0.5) {
    $confirmTrim = 0.2
  }

  $confirmRange = Get-WindowPriceRangeStats -History $History -WindowMinutes $confirmWindowMinutes -TrimPercentile $confirmTrim
  $bouncePct = $null
  $distanceFromHighPct = $null
  if ($null -ne $confirmRange) {
    $recentLow = [double]$confirmRange.robust_low
    $recentHigh = [double]$confirmRange.robust_high
    if ($recentLow -gt 0) {
      $bouncePct = [math]::Round((($mid / $recentLow) - 1.0) * 100.0, 4)
    }
    if ($recentHigh -gt 0) {
      $distanceFromHighPct = [math]::Round(((($recentHigh - $mid) / $recentHigh) * 100.0), 4)
    }
  }

  $trendGatePassed = $true
  if ($null -ne $ret30 -and $ret30 -lt [double](Get-ObjectValue -InputObject $Strategy -Name "entry_trend_filter_30m_min_return_pct")) {
    $trendGatePassed = $false
  }
  if ($null -ne $ret60 -and $ret60 -lt [double](Get-ObjectValue -InputObject $Strategy -Name "entry_trend_filter_60m_min_return_pct")) {
    $trendGatePassed = $false
  }

  $confirmationScore = 0
  if ($null -ne $ret10 -and $ret10 -ge [double](Get-ObjectValue -InputObject $Strategy -Name "entry_confirmation_min_return_10m_pct")) {
    $confirmationScore += 1
  }
  if ($null -ne $ret15 -and $ret15 -ge [double](Get-ObjectValue -InputObject $Strategy -Name "entry_confirmation_min_return_15m_pct")) {
    $confirmationScore += 1
  }
  if ($null -ne $bouncePct -and $bouncePct -ge [double](Get-ObjectValue -InputObject $Strategy -Name "entry_confirmation_min_bounce_pct")) {
    $confirmationScore += 1
  }
  if ($null -ne $distanceFromHighPct -and $distanceFromHighPct -le [double](Get-ObjectValue -InputObject $Strategy -Name "entry_confirmation_max_distance_from_high_pct")) {
    $confirmationScore += 1
  }

  return @{
    trend_gate_passed = $trendGatePassed
    confirmation_score = $confirmationScore
    ret10 = $ret10
    ret15 = $ret15
    ret30 = $ret30
    ret60 = $ret60
    bounce_pct = $bouncePct
    distance_from_high_pct = $distanceFromHighPct
  }
}

function Get-SellTrendContext {
  param(
    $Tick,
    [object[]]$History,
    [double]$ProfitPct,
    $Strategy
  )

  $ret15 = Get-WindowReturnPct -History $History -WindowMinutes 15
  $ret30 = Get-WindowReturnPct -History $History -WindowMinutes 30
  $zScore = Get-PriceZScore -History $History -WindowMinutes ([int]$Strategy.mean_reversion_window_minutes)
  $imbalance = Get-OrderBookImbalance -Tick $Tick
  $tradeImbalance = Get-RecentTradeImbalance -Tick $Tick

  $score = 0
  if ($null -ne $ret15 -and $ret15 -ge [double](Get-ObjectValue -InputObject $Strategy -Name "trend_runner_min_return_15m_pct")) {
    $score += 1
  }
  if ($null -ne $ret30 -and $ret30 -ge [double](Get-ObjectValue -InputObject $Strategy -Name "trend_runner_min_return_30m_pct")) {
    $score += 1
  }
  if ($null -ne $zScore -and $zScore -ge [double](Get-ObjectValue -InputObject $Strategy -Name "trend_runner_min_zscore")) {
    $score += 1
  }
  if ($imbalance -ge [double](Get-ObjectValue -InputObject $Strategy -Name "trend_runner_min_orderbook_imbalance")) {
    $score += 1
  }
  if ($tradeImbalance -ge [double](Get-ObjectValue -InputObject $Strategy -Name "trend_runner_min_trade_imbalance")) {
    $score += 1
  }

  $strongTrend = $false
  if ($ProfitPct -ge [double](Get-ObjectValue -InputObject $Strategy -Name "trend_runner_min_profit_pct") -and $score -ge [int](Get-ObjectValue -InputObject $Strategy -Name "trend_runner_min_score")) {
    $strongTrend = $true
  }

  $reserveFraction = [double](Get-ObjectValue -InputObject $Strategy -Name "trend_runner_reserve_fraction")
  if ($strongTrend -and $ProfitPct -ge [double](Get-ObjectValue -InputObject $Strategy -Name "trend_runner_boost_profit_pct")) {
    $reserveFraction = [math]::Max($reserveFraction, [double](Get-ObjectValue -InputObject $Strategy -Name "trend_runner_max_reserve_fraction"))
  }

  return @{
    strong_trend = $strongTrend
    score = $score
    ret15 = $ret15
    ret30 = $ret30
    z_score = $zScore
    orderbook = $imbalance
    tape = $tradeImbalance
    reserve_fraction = $reserveFraction
  }
}

function Get-BuySignal {
  param(
    $Tick,
    [object[]]$History,
    $Inventory,
    $WalletBalance,
    [hashtable]$State,
    $Strategy
  )

  if (-not (Get-CooldownExpired -State $State -Side "buy" -CooldownMinutes ([int]$Strategy.cooldown_minutes))) {
    return $null
  }

  $spreadPct = ConvertTo-DoubleValue $Tick.spread_pct
  if ($spreadPct -gt [double]$Strategy.max_spread_pct) {
    return $null
  }

  $volatility = Get-VolatilityPct -History $History -WindowMinutes ([int]$Strategy.volatility_window_minutes)
  if ($null -eq $volatility) {
    return $null
  }

  if ($volatility -gt [double]$Strategy.volatility_entry_ceiling_pct) {
    return $null
  }

  $mid = ConvertTo-Decimal $Tick.mid_price
  $fair = ConvertTo-Decimal $Tick.fair_value
  if ($mid -le 0 -or $fair -le 0) {
    return $null
  }

  $discountPct = [math]::Round((([double]$fair - [double]$mid) / [double]$fair) * 100.0, 4)
  $requiredDiscount = [double]$Strategy.fair_value_discount_entry_pct + ([double]$Strategy.discount_volatility_multiplier * $volatility)
  $zScore = Get-PriceZScore -History $History -WindowMinutes ([int]$Strategy.mean_reversion_window_minutes)
  $shortWindowMinutes = [int](Get-ObjectValue -InputObject $Strategy -Name "entry_short_window_minutes")
  if ($shortWindowMinutes -le 0) {
    $shortWindowMinutes = 90
  }
  $longWindowMinutes = [int](Get-ObjectValue -InputObject $Strategy -Name "entry_long_window_minutes")
  if ($longWindowMinutes -le 0) {
    $longWindowMinutes = 360
  }
  $trimPercentile = [double](Get-ObjectValue -InputObject $Strategy -Name "entry_noise_trim_percentile")
  if ($trimPercentile -le 0 -or $trimPercentile -ge 0.5) {
    $trimPercentile = 0.15
  }
  $shortRangeStats = Get-WindowPriceRangeStats -History $History -WindowMinutes $shortWindowMinutes -TrimPercentile $trimPercentile
  $longRangeStats = Get-WindowPriceRangeStats -History $History -WindowMinutes $longWindowMinutes -TrimPercentile $trimPercentile
  if ($null -eq $shortRangeStats -or $null -eq $longRangeStats) {
    return $null
  }

  $shortRangeLow = [double]$shortRangeStats.robust_low
  $shortRangeHigh = [double]$shortRangeStats.robust_high
  $shortRangeWidth = [math]::Max(0.0001, ($shortRangeHigh - $shortRangeLow))
  $shortRangePosition = [math]::Round((([double]$mid - $shortRangeLow) / $shortRangeWidth), 4)
  $shortPriceAboveLowPct = if ($shortRangeLow -gt 0) { [math]::Round((([double]$mid / $shortRangeLow) - 1.0) * 100.0, 4) } else { 9999.0 }

  $longRangeLow = [double]$longRangeStats.robust_low
  $longRangeHigh = [double]$longRangeStats.robust_high
  $longRangeWidth = [math]::Max(0.0001, ($longRangeHigh - $longRangeLow))
  $longRangePosition = [math]::Round((([double]$mid - $longRangeLow) / $longRangeWidth), 4)
  $longPriceAboveLowPct = if ($longRangeLow -gt 0) { [math]::Round((([double]$mid / $longRangeLow) - 1.0) * 100.0, 4) } else { 9999.0 }
  $entryMode = $null
  $effectiveEdge = $discountPct

  if ($discountPct -ge $requiredDiscount) {
    $entryMode = "fair_value_discount"
  } elseif ($null -ne $zScore -and $zScore -le (-1.0 * [double]$Strategy.mean_reversion_entry_z)) {
    $entryMode = "mean_reversion"
    $effectiveEdge = [math]::Max($discountPct, [double]$Strategy.fair_value_discount_entry_pct * ([math]::Abs($zScore) / [double]$Strategy.mean_reversion_entry_z))
  } else {
    return $null
  }

  $signalScore = 0
  $shortRangePass = $shortRangePosition -le [double](Get-ObjectValue -InputObject $Strategy -Name "short_window_max_range_position_for_entry")
  $longRangePass = $longRangePosition -le [double](Get-ObjectValue -InputObject $Strategy -Name "long_window_max_range_position_for_entry")
  $shortLowPass = $shortPriceAboveLowPct -le [double](Get-ObjectValue -InputObject $Strategy -Name "short_window_max_above_low_pct")
  $longLowPass = $longPriceAboveLowPct -le [double]$Strategy.max_price_above_long_window_low_pct

  if ($shortRangePass) { $signalScore += 1 }
  if ($longRangePass) { $signalScore += 1 }
  if ($shortLowPass) { $signalScore += 1 }
  if ($longLowPass) { $signalScore += 1 }

  $requiredSignalScore = [int](Get-ObjectValue -InputObject $Strategy -Name "entry_min_signal_score")
  if ($requiredSignalScore -le 0) {
    $requiredSignalScore = 3
  }

  if (-not (($shortRangePass -or $shortLowPass) -and ($longRangePass -or $longLowPass))) {
    return $null
  }

  if ($signalScore -lt $requiredSignalScore) {
    return $null
  }

  $ret5 = Get-WindowReturnPct -History $History -WindowMinutes 5
  $buyTrendContext = Get-BuyTrendContext -Tick $Tick -History $History -Strategy $Strategy
  if ($null -ne $ret5 -and $ret5 -lt (-1.0 * [double]$Strategy.max_negative_5m_momentum_pct_for_entry)) {
    return $null
  }
  if (-not [bool](Get-ObjectValue -InputObject $buyTrendContext -Name "trend_gate_passed")) {
    return $null
  }
  $requiredConfirmationScore = [int](Get-ObjectValue -InputObject $Strategy -Name "entry_confirmation_min_score")
  if ($requiredConfirmationScore -le 0) {
    $requiredConfirmationScore = 2
  }
  if ([int](Get-ObjectValue -InputObject $buyTrendContext -Name "confirmation_score") -lt $requiredConfirmationScore) {
    return $null
  }

  $imbalance = Get-OrderBookImbalance -Tick $Tick
  if ($imbalance -lt [double]$Strategy.min_orderbook_imbalance_for_buy) {
    return $null
  }

  $tradeImbalance = Get-RecentTradeImbalance -Tick $Tick
  if ($tradeImbalance -lt [double]$Strategy.min_recent_trade_imbalance_for_buy) {
    return $null
  }

  $walletAvailable = Get-AvailableCash -WalletBalance $WalletBalance -Strategy $Strategy
  $currentCostBasis = Get-InventoryCostBasis -Inventory $Inventory
  $ask = if ($Tick.ask) { ConvertTo-Decimal $Tick.ask } else { $mid }
  $maxBuyPrice = [decimal][math]::Round([double]($ask * [decimal](1.0 + ([double]$Strategy.buy_slippage_limit_pct / 100.0))), 2)
  $qty = Get-DynamicBuyQuantity -ReferencePrice $maxBuyPrice -AvailableCash $walletAvailable -CurrentCostBasis $currentCostBasis -VolatilityPct $volatility -DiscountPct $effectiveEdge -Strategy $Strategy
  if ($qty -le 0) {
    return $null
  }

  return @{
    side = "buy"
    quantity = $qty
    reference_price = $ask
    reason = "mode=${entryMode} discount=${discountPct}% required=${requiredDiscount}% z=${zScore} vol=${volatility}% spread=${spreadPct}% book=${imbalance} tape=${tradeImbalance} short_pos=${shortRangePosition} short_above_low=${shortPriceAboveLowPct}% long_pos=${longRangePosition} long_above_low=${longPriceAboveLowPct}% score=${signalScore} ret10=${($buyTrendContext.ret10)} ret15=${($buyTrendContext.ret15)} ret30=${($buyTrendContext.ret30)} ret60=${($buyTrendContext.ret60)} bounce=${($buyTrendContext.bounce_pct)} near_high=${($buyTrendContext.distance_from_high_pct)} confirm=${($buyTrendContext.confirmation_score)} max_buy=${maxBuyPrice}"
  }
}

function Get-SellSignal {
  param(
    $Tick,
    [object[]]$History,
    $Inventory,
    [hashtable]$State,
    $Strategy
  )

  if (-not (Get-CooldownExpired -State $State -Side "sell" -CooldownMinutes ([int]$Strategy.cooldown_minutes))) {
    return $null
  }

  $availableToSell = Get-SettledInventoryQuantity -Inventory $Inventory
  if ($availableToSell -lt [int]$Strategy.min_trade_quantity) {
    return $null
  }

  Sync-SellLadderState -State $State -Inventory $Inventory

  $mid = ConvertTo-Decimal $Tick.mid_price
  $ask = if ($Tick.ask) { ConvertTo-Decimal $Tick.ask } else { $mid }
  $settledCostBasis = Get-SellableSettledCostBasis -Inventory $Inventory
  $avgCost = ConvertTo-Decimal (Get-ObjectValue -InputObject $settledCostBasis -Name "avg_buy_price")
  $costBasisSource = [string](Get-ObjectValue -InputObject $settledCostBasis -Name "source")
  if ($mid -le 0 -or $avgCost -le 0) {
    return $null
  }

  $profitPct = [math]::Round((([double]$mid / [double]$avgCost) - 1.0) * 100.0, 4)
  if ($null -eq $State.position_peak_profit_pct -or $profitPct -gt [double]$State.position_peak_profit_pct) {
    $State.position_peak_profit_pct = $profitPct
  }

  if ($profitPct -le 0) {
    return $null
  }

  $peak = [double]$State.position_peak_profit_pct
  $drawdown = $peak - $profitPct
  $volatility = Get-VolatilityPct -History $History -WindowMinutes ([int]$Strategy.volatility_window_minutes)
  if ($null -eq $volatility) {
    $volatility = [double]$Strategy.volatility_floor_pct
  }
  $trendContext = Get-SellTrendContext -Tick $Tick -History $History -ProfitPct $profitPct -Strategy $Strategy

  $dynamicTakeProfit = [double]$Strategy.base_take_profit_pct + ([double]$Strategy.volatility_take_profit_boost_pct * $volatility)
  $sellReason = $null
  $sellQty = $availableToSell
  $tierPlan = Get-SellLadderTierPlan -ProfitPct $profitPct -AvailableToSell $availableToSell -State $State -Strategy $Strategy

  if ($null -ne $tierPlan) {
    $sellReason = "ladder_take_profit"
    $sellQty = [int]$tierPlan.quantity
  }

  if (-not $sellReason -and $profitPct -ge $dynamicTakeProfit) {
    $sellReason = "take_profit"
  } elseif (-not $sellReason -and $peak -ge [double]$Strategy.trailing_arm_pct -and $drawdown -ge [double]$Strategy.trailing_stop_pct) {
    $sellReason = "trailing_stop"
  } elseif (-not $sellReason) {
    $fair = ConvertTo-Decimal $Tick.fair_value
    if ($fair -gt 0) {
      $premiumPct = [math]::Round((([double]$mid - [double]$fair) / [double]$fair) * 100.0, 4)
      if ($profitPct -gt [double]$Strategy.min_profit_for_fair_value_exit_pct -and $premiumPct -ge [double]$Strategy.fair_value_premium_exit_pct) {
        $sellReason = "fair_value_reversion"
      }
    }
  }

  if (-not $sellReason) {
    $zScore = Get-PriceZScore -History $History -WindowMinutes ([int]$Strategy.mean_reversion_window_minutes)
    if ($null -ne $zScore -and $zScore -ge [double]$Strategy.mean_reversion_exit_z -and $profitPct -ge [double]$Strategy.min_profit_for_mean_reversion_exit_pct) {
      $sellReason = "mean_reversion_exit"
    }
  }

  if (-not $sellReason) {
    return $null
  }

  $qty = $sellQty
  $runnerApplied = $false
  $runnerReserveQty = 0
  $profitTakingReasons = @("ladder_take_profit", "take_profit", "fair_value_reversion", "mean_reversion_exit")
  if ($profitTakingReasons -contains $sellReason -and [bool](Get-ObjectValue -InputObject $trendContext -Name "strong_trend")) {
    $reserveFraction = [double](Get-ObjectValue -InputObject $trendContext -Name "reserve_fraction")
    if ($reserveFraction -gt 0) {
      $runnerReserveQty = [int][math]::Ceiling($availableToSell * $reserveFraction)
      $maxSellQty = [int]($availableToSell - $runnerReserveQty)
      if ($maxSellQty -le 0) {
        return $null
      }
      if ($qty -gt $maxSellQty) {
        $qty = $maxSellQty
        $runnerApplied = $true
      }
    }
  }

  if ($qty -lt [int]$Strategy.min_trade_quantity) {
    return $null
  }

  $referenceBid = if ($Tick.bid) { ConvertTo-Decimal $Tick.bid } else { $ask }

  $reasonText = if ($null -ne $tierPlan) {
    $tierProfitPct = [double]$tierPlan.tier_profit_pct
    $tierFractionPct = [math]::Round([double]$tierPlan.sell_fraction * 100.0, 2)
    $tierCount = [int](Get-ObjectValue -InputObject $tierPlan -Name "tier_count")
    $tierSummary = [string](Get-ObjectValue -InputObject $tierPlan -Name "tier_summary")
    $trendScore = [int](Get-ObjectValue -InputObject $trendContext -Name "score")
    $trendRet15 = Get-ObjectValue -InputObject $trendContext -Name "ret15"
    $trendRet30 = Get-ObjectValue -InputObject $trendContext -Name "ret30"
    $trendZ = Get-ObjectValue -InputObject $trendContext -Name "z_score"
    "mode=${sellReason} profit=${profitPct}% peak=${peak}% vol=${volatility}% settled=${availableToSell} qty=${qty} settled_avg=${avgCost} cost_source=${costBasisSource} tier=${tierProfitPct}% fraction=${tierFractionPct}% tiers=${tierCount} detail=${tierSummary} trend_score=${trendScore} ret15=${trendRet15} ret30=${trendRet30} z=${trendZ} runner_keep=${runnerReserveQty} runner_applied=${runnerApplied}"
  } else {
    $trendScore = [int](Get-ObjectValue -InputObject $trendContext -Name "score")
    $trendRet15 = Get-ObjectValue -InputObject $trendContext -Name "ret15"
    $trendRet30 = Get-ObjectValue -InputObject $trendContext -Name "ret30"
    $trendZ = Get-ObjectValue -InputObject $trendContext -Name "z_score"
    "mode=${sellReason} profit=${profitPct}% peak=${peak}% vol=${volatility}% settled=${availableToSell} qty=${qty} settled_avg=${avgCost} cost_source=${costBasisSource} trend_score=${trendScore} ret15=${trendRet15} ret30=${trendRet30} z=${trendZ} runner_keep=${runnerReserveQty} runner_applied=${runnerApplied}"
  }

  return @{
    side = "sell"
    quantity = $qty
    reference_price = $referenceBid
    tier_key = if ($null -ne $tierPlan) { [string]$tierPlan.tier_key } else { $null }
    reason = $reasonText
  }
}

function Invoke-OrderPlan {
  param(
    [hashtable]$Plan,
    [hashtable]$State,
    $Strategy
  )

  $side = [string]$Plan.side
  $quantity = [int]$Plan.quantity
  $referencePrice = [decimal]$Plan.reference_price

  if (-not $Execute) {
    Write-Log ("[dry-run] {0} {1} ref={2} -> {3}" -f $side.ToUpperInvariant(), $quantity, $referencePrice.ToString("0.00", [System.Globalization.CultureInfo]::InvariantCulture), $Plan.reason)
    Register-Action -State $State -Action @{
      timestamp = (Get-Date).ToUniversalTime().ToString("o")
      mode = "dry-run"
      side = $side
      reference_price = [string]$referencePrice
      quantity = $quantity
      reason = $Plan.reason
    }
    return
  }

  if ($side -eq "buy") {
    $response = New-TurnipBuyOrder -Quantity $quantity -ReferenceAsk $referencePrice -Strategy $Strategy
  } else {
    $response = New-TurnipSellOrder -Quantity $quantity -ReferenceBid $referencePrice -Strategy $Strategy
  }

  Write-Log ("Executed {0} {1} ref={2} success={3}" -f $side.ToUpperInvariant(), $quantity, $referencePrice.ToString("0.00", [System.Globalization.CultureInfo]::InvariantCulture), $response.success)
  Register-OrderTimestamp -State $State -Side $side
  if ($side -eq "sell" -and $response.success) {
    $tierKeys = Get-ObjectValue -InputObject $Plan -Name "tier_keys"
    if ($null -eq $tierKeys) {
      $tierKeys = [string](Get-ObjectValue -InputObject $Plan -Name "tier_key")
    }
    if ($tierKeys) {
      Register-SellLadderExecution -State $State -TierKey $tierKeys
    }
  }
  Register-Action -State $State -Action @{
    timestamp = (Get-Date).ToUniversalTime().ToString("o")
    mode = "execute"
    side = $side
    reference_price = [string]$referencePrice
    quantity = $quantity
    reason = $Plan.reason
    response = $response
  }
}

$config = Get-Config -Path $ConfigPath
$resolvedConfigPath = [System.IO.Path]::GetFullPath($ConfigPath)
$script:BaseUrl = [string]$config.base_url
$script:Token = Resolve-Token -CliToken $Token -Config $config
$script:LogPath = Resolve-ConfigRelativePath -ConfigPath $resolvedConfigPath -TargetPath ([string]$config.log_path)
$script:TickHistoryPath = Resolve-ConfigRelativePath -ConfigPath $resolvedConfigPath -TargetPath ([string]$config.tick_history_path)
$statePath = Resolve-ConfigRelativePath -ConfigPath $resolvedConfigPath -TargetPath ([string]$config.state_path)
$strategy = $config.strategy
$pollingSeconds = [int]$config.polling_seconds
$pollingSeconds = [Math]::Max(1, $pollingSeconds)
$pollInterval = [TimeSpan]::FromSeconds($pollingSeconds)
$state = Get-State -Path $statePath
if ($script:TickHistoryPath) {
  $state.tick_history = @(Read-TickHistoryFromDisk -Path $script:TickHistoryPath -WindowHours 6 | Select-Object -Last 180)
}

Write-Log ("Starting turnip bot in {0} mode" -f ($(if ($Execute) { "EXECUTE" } else { "DRY-RUN" })))

$nextCycleAt = [DateTimeOffset]::UtcNow
while ($true) {
  $now = [DateTimeOffset]::UtcNow
  if ($now -lt $nextCycleAt) {
    $sleepMs = [int][Math]::Ceiling(($nextCycleAt - $now).TotalMilliseconds)
    if ($sleepMs -gt 0) {
      Start-Sleep -Milliseconds $sleepMs
    }
  } else {
    $nextCycleAt = $now
  }

  try {
    $inventory = Get-TurnipInventory
    $walletBalance = Get-WalletBalance
    $market = Get-TurnipMarket
    $depth = Get-TurnipDepth
    $tick = New-TickFromMarketData -Market $market -Depth $depth

    Add-TickObservation -State $state -Tick $tick
    if ($script:TickHistoryPath) {
      Trim-TickHistoryDisk -Path $script:TickHistoryPath -WindowHours 6
      $history = Read-TickHistoryFromDisk -Path $script:TickHistoryPath -WindowHours 6
      $state.tick_history = @($history | Select-Object -Last 180)
    } else {
      $history = @($state.tick_history)
    }
    $mid = ConvertTo-Decimal $tick.mid_price
    $spreadPct = ConvertTo-DoubleValue $tick.spread_pct
    $volatility = Get-VolatilityPct -History $history -WindowMinutes ([int]$strategy.volatility_window_minutes)
    $ret5 = Get-WindowReturnPct -History $history -WindowMinutes 5
    $zScore = Get-PriceZScore -History $history -WindowMinutes ([int]$strategy.mean_reversion_window_minutes)
    $imbalance = Get-OrderBookImbalance -Tick $tick
    $tradeImbalance = Get-RecentTradeImbalance -Tick $tick
    $inventoryQty = Get-InventoryQuantity -Inventory $inventory
    $settledQty = Get-SettledInventoryQuantity -Inventory $inventory
    $pendingQty = Get-PendingInventoryQuantity -Inventory $inventory
    $avgCost = ConvertTo-Decimal $inventory.avg_buy_price
    $profitPct = if ($inventoryQty -gt 0 -and $avgCost -gt 0) { [math]::Round((([double]$mid / [double]$avgCost) - 1.0) * 100.0, 4) } else { 0.0 }
    $settledCostBasis = Get-SellableSettledCostBasis -Inventory $inventory
    $settledAvgCost = ConvertTo-Decimal (Get-ObjectValue -InputObject $settledCostBasis -Name "avg_buy_price")
    $settledProfitPct = if ($settledQty -gt 0 -and $settledAvgCost -gt 0) { [math]::Round((([double]$mid / [double]$settledAvgCost) - 1.0) * 100.0, 4) } else { 0.0 }
    $settledCostSource = [string](Get-ObjectValue -InputObject $settledCostBasis -Name "source")

    Write-Log ("tick source={0} mid={1} bid={2} ask={3} spread={4}% vol={5}% ret5={6}% z={7} book={8} tape={9} total={10} settled={11} pending={12} avg={13} pnl={14}% settled_avg={15} settled_pnl={16}% settled_source={17}" -f `
      $(if ($tick.PSObject.Properties.Name -contains "source") { $tick.source } else { "live_stream" }), `
      $mid.ToString("0.00", [System.Globalization.CultureInfo]::InvariantCulture), `
      (ConvertTo-Decimal $tick.bid).ToString("0.00", [System.Globalization.CultureInfo]::InvariantCulture), `
      (ConvertTo-Decimal $tick.ask).ToString("0.00", [System.Globalization.CultureInfo]::InvariantCulture), `
      ([math]::Round($spreadPct, 4)), `
      $(if ($null -ne $volatility) { [math]::Round($volatility, 4) } else { "n/a" }), `
      $(if ($null -ne $ret5) { [math]::Round($ret5, 4) } else { "n/a" }), `
      $(if ($null -ne $zScore) { [math]::Round($zScore, 4) } else { "n/a" }), `
      $imbalance, `
      $tradeImbalance, `
      $inventoryQty, `
      $settledQty, `
      $pendingQty, `
      $avgCost.ToString("0.00", [System.Globalization.CultureInfo]::InvariantCulture), `
      $profitPct, `
      $settledAvgCost.ToString("0.00", [System.Globalization.CultureInfo]::InvariantCulture), `
      $settledProfitPct, `
      $settledCostSource)

    if ($inventoryQty -le 0) {
      $state.position_peak_profit_pct = $null
    }

    $sellSignal = Get-SellSignal -Tick $tick -History $history -Inventory $inventory -State $state -Strategy $strategy
    if ($sellSignal) {
      Invoke-OrderPlan -Plan $sellSignal -State $state -Strategy $strategy
    } else {
      $buySignal = Get-BuySignal -Tick $tick -History $history -Inventory $inventory -WalletBalance $walletBalance -State $state -Strategy $strategy
      if ($buySignal) {
        Invoke-OrderPlan -Plan $buySignal -State $state -Strategy $strategy
      }
    }

    Save-State -State $state -Path $statePath
  } catch {
    Write-Log $_.Exception.Message "ERROR"
  }

  if ($Once) {
    break
  }

  $nextCycleAt = $nextCycleAt.Add($pollInterval)
  $afterCycle = [DateTimeOffset]::UtcNow
  if ($afterCycle -ge $nextCycleAt) {
    $intervalMs = [Math]::Max(1.0, $pollInterval.TotalMilliseconds)
    $lagMs = ($afterCycle - $nextCycleAt).TotalMilliseconds
    $skipCount = [int][Math]::Floor($lagMs / $intervalMs) + 1
    $nextCycleAt = $nextCycleAt.AddMilliseconds($skipCount * $intervalMs)
  }
}
