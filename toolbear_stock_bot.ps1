param(
  [string]$ConfigPath = ".\stock_bot_config.json",
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

function Get-Config {
  param([string]$Path)
  if (-not (Test-Path $Path)) {
    throw "Config not found: $Path"
  }
  return Get-Content $Path -Raw | ConvertFrom-Json
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

function Invoke-ExternalJson {
  param([string]$Url)

  $headers = @{
    "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/135.0.0.0 Safari/537.36"
    "Accept" = "application/json, text/plain, */*"
  }

  return Invoke-RestMethod -Uri $Url -Headers $headers -Method Get
}

function New-State {
  return @{
    price_history = @{}
    peaks = @{}
    last_trade_at = @{}
    last_actions = @()
  }
}

function Get-State {
  param([string]$Path)

  if (-not (Test-Path $Path)) {
    return New-State
  }

  try {
    $raw = Get-Content $Path -Raw | ConvertFrom-Json -AsHashtable
    if (-not $raw) {
      return New-State
    }
    foreach ($key in @("price_history", "peaks", "last_trade_at", "last_actions")) {
      if (-not $raw.ContainsKey($key) -or $null -eq $raw[$key]) {
        $raw[$key] = if ($key -eq "last_actions") { @() } else { @{} }
      }
    }
    return $raw
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

function Get-StockPrice {
  param([string]$Symbol)
  return Invoke-ToolbearApi -Method GET -Path ("/api/stock/price?symbol={0}" -f $Symbol)
}

function Get-Portfolio {
  return Invoke-ToolbearApi -Method GET -Path "/api/stock/portfolio"
}

function Get-Triggers {
  return Invoke-ToolbearApi -Method GET -Path "/api/stock/triggers"
}

function Add-PriceObservation {
  param(
    [hashtable]$State,
    [string]$Symbol,
    $Quote
  )

  if (-not $State.price_history.ContainsKey($Symbol)) {
    $State.price_history[$Symbol] = @()
  }

  $history = @($State.price_history[$Symbol])
  $history += @{
    timestamp = (Get-Date).ToUniversalTime().ToString("o")
    price = [decimal]::Parse([string]$Quote.price, [System.Globalization.CultureInfo]::InvariantCulture)
    change_percent = [decimal]::Parse([string]$Quote.change_percent, [System.Globalization.CultureInfo]::InvariantCulture)
    market_state = [string]$Quote.market_state
  }

  $cutoff = (Get-Date).ToUniversalTime().AddHours(-6)
  $history = @(
    $history | Where-Object {
      [DateTime]::Parse($_.timestamp, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind) -ge $cutoff
    }
  )

  $State.price_history[$Symbol] = $history
}

function Get-ReturnOverWindow {
  param(
    [object[]]$History,
    [int]$WindowMinutes
  )

  if (-not $History -or $History.Count -lt 2) {
    return $null
  }

  $now = (Get-Date).ToUniversalTime()
  $cutoff = $now.AddMinutes(-1 * $WindowMinutes)
  $ordered = @($History | Sort-Object { [DateTime]::Parse($_.timestamp) })
  $current = [decimal]$ordered[-1].price
  $baseline = $null

  foreach ($row in $ordered) {
    $rowTime = [DateTime]::Parse($row.timestamp, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
    if ($rowTime -ge $cutoff) {
      $baseline = [decimal]$row.price
      break
    }
  }

  if ($null -eq $baseline -or $baseline -le 0) {
    return $null
  }

  return [math]::Round((([double]$current / [double]$baseline) - 1.0) * 100.0, 4)
}

function Get-OpenPositionCount {
  param($Portfolio)
  return @($Portfolio.positions).Count
}

function Get-PositionBySymbol {
  param(
    $Portfolio,
    [string]$Symbol
  )

  foreach ($position in @($Portfolio.positions)) {
    if ([string]$position.symbol -eq $Symbol) {
      return $position
    }
  }

  return $null
}

function Get-CooldownExpired {
  param(
    [hashtable]$State,
    [string]$Symbol,
    [int]$CooldownMinutes
  )

  if (-not $State.last_trade_at.ContainsKey($Symbol)) {
    return $true
  }

  $lastTrade = [DateTime]::Parse($State.last_trade_at[$Symbol], [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
  return ((Get-Date).ToUniversalTime() - $lastTrade).TotalMinutes -ge $CooldownMinutes
}

function Register-TradeTimestamp {
  param(
    [hashtable]$State,
    [string]$Symbol
  )

  $State.last_trade_at[$Symbol] = (Get-Date).ToUniversalTime().ToString("o")
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

function Get-ExternalChartSeries {
  param(
    [string]$Symbol,
    [string]$Range = "1mo",
    [string]$Interval = "1d"
  )

  $encodedSymbol = [uri]::EscapeDataString($Symbol)
  $url = "https://query1.finance.yahoo.com/v8/finance/chart/{0}?interval={1}&range={2}&includePrePost=false" -f $encodedSymbol, $Interval, $Range
  $response = Invoke-ExternalJson -Url $url
  $result = @($response.chart.result)[0]
  if (-not $result) {
    return $null
  }

  $timestamps = @($result.timestamp)
  $quote = @($result.indicators.quote)[0]
  $closes = @($quote.close)
  $rows = @()
  for ($i = 0; $i -lt $timestamps.Count; $i++) {
    $closeValue = $closes[$i]
    if ($null -eq $closeValue) {
      continue
    }

    $rows += @{
      timestamp = [DateTimeOffset]::FromUnixTimeSeconds([long]$timestamps[$i]).UtcDateTime.ToString("o")
      close = [double]$closeValue
    }
  }

  return @{
    symbol = $Symbol
    rows = $rows
  }
}

function Get-SeriesReturnPct {
  param(
    [object[]]$Rows,
    [int]$LookbackBars
  )

  if (-not $Rows -or $Rows.Count -lt ($LookbackBars + 1)) {
    return $null
  }

  $current = [double]$Rows[-1].close
  $baseline = [double]$Rows[-1 * ($LookbackBars + 1)].close
  if ($baseline -le 0) {
    return $null
  }

  return [math]::Round((($current / $baseline) - 1.0) * 100.0, 4)
}

function Get-Sma {
  param(
    [object[]]$Rows,
    [int]$Period
  )

  if (-not $Rows -or $Rows.Count -lt $Period) {
    return $null
  }

  $window = @($Rows | Select-Object -Last $Period)
  $sum = 0.0
  foreach ($row in $window) {
    $sum += [double]$row.close
  }
  return [math]::Round(($sum / $Period), 6)
}

function Get-ExternalReferenceSnapshot {
  param(
    [string]$Symbol,
    $ExternalReferenceConfig
  )

  if (-not $ExternalReferenceConfig -or -not $ExternalReferenceConfig.enabled) {
    return $null
  }

  $symbolSeries = Get-ExternalChartSeries -Symbol $Symbol -Range ([string]$ExternalReferenceConfig.symbol_range) -Interval ([string]$ExternalReferenceConfig.symbol_interval)
  if (-not $symbolSeries -or @($symbolSeries.rows).Count -lt 20) {
    return $null
  }

  $benchmarkSnapshots = @()
  foreach ($benchmarkSymbol in @($ExternalReferenceConfig.benchmark_symbols)) {
    $benchmarkSeries = Get-ExternalChartSeries -Symbol ([string]$benchmarkSymbol) -Range ([string]$ExternalReferenceConfig.benchmark_range) -Interval ([string]$ExternalReferenceConfig.benchmark_interval)
    if (-not $benchmarkSeries -or @($benchmarkSeries.rows).Count -lt 20) {
      continue
    }

    $benchmarkSnapshots += @{
      symbol = [string]$benchmarkSymbol
      ret_5d_pct = Get-SeriesReturnPct -Rows @($benchmarkSeries.rows) -LookbackBars 5
      sma20 = Get-Sma -Rows @($benchmarkSeries.rows) -Period 20
      last = [double]$benchmarkSeries.rows[-1].close
    }
  }

  $rows = @($symbolSeries.rows)
  $last = [double]$rows[-1].close
  $sma20 = Get-Sma -Rows $rows -Period 20
  $ret5d = Get-SeriesReturnPct -Rows $rows -LookbackBars 5
  $distanceFromSma20Pct = $null
  if ($sma20 -and $sma20 -gt 0) {
    $distanceFromSma20Pct = [math]::Round((($last / $sma20) - 1.0) * 100.0, 4)
  }

  return @{
    symbol = $Symbol
    last = $last
    sma20 = $sma20
    ret_5d_pct = $ret5d
    distance_from_sma20_pct = $distanceFromSma20Pct
    benchmarks = $benchmarkSnapshots
  }
}

function Test-ExternalAlignment {
  param(
    [string]$Signal,
    $ReferenceSnapshot,
    $Strategy
  )

  if (-not $ReferenceSnapshot) {
    return @{
      allowed = $true
      reason = "external reference unavailable"
    }
  }

  $symbolRet5d = $ReferenceSnapshot.ret_5d_pct
  $distanceFromSma20 = $ReferenceSnapshot.distance_from_sma20_pct
  $benchmarkReturns = @($ReferenceSnapshot.benchmarks | ForEach-Object { $_.ret_5d_pct } | Where-Object { $null -ne $_ })
  $benchmarkMin = if ($benchmarkReturns.Count -gt 0) { ($benchmarkReturns | Measure-Object -Minimum).Minimum } else { $null }
  $benchmarkMax = if ($benchmarkReturns.Count -gt 0) { ($benchmarkReturns | Measure-Object -Maximum).Maximum } else { $null }

  if ($Signal -eq "buy") {
    if ($null -ne $symbolRet5d -and $symbolRet5d -lt [double]$Strategy.external_symbol_min_5d_return_pct_for_long) {
      return @{ allowed = $false; reason = "external 5d trend too weak for long (${symbolRet5d}%)" }
    }
    if ($null -ne $distanceFromSma20 -and $distanceFromSma20 -lt [double]$Strategy.external_symbol_min_distance_from_sma20_pct_for_long) {
      return @{ allowed = $false; reason = "price still below external SMA20 (${distanceFromSma20}%)" }
    }
    if ($null -ne $benchmarkMin -and $benchmarkMin -lt [double]$Strategy.benchmark_min_5d_return_pct_for_long) {
      return @{ allowed = $false; reason = "benchmark regime not supportive for long (${benchmarkMin}%)" }
    }
    return @{ allowed = $true; reason = "external long alignment ok" }
  }

  if ($Signal -eq "short") {
    if ($null -ne $symbolRet5d -and $symbolRet5d -gt [double]$Strategy.external_symbol_max_5d_return_pct_for_short) {
      return @{ allowed = $false; reason = "external 5d trend too strong for short (${symbolRet5d}%)" }
    }
    if ($null -ne $distanceFromSma20 -and $distanceFromSma20 -gt [double]$Strategy.external_symbol_max_distance_from_sma20_pct_for_short) {
      return @{ allowed = $false; reason = "price still above external SMA20 (${distanceFromSma20}%)" }
    }
    if ($null -ne $benchmarkMax -and $benchmarkMax -gt [double]$Strategy.benchmark_max_5d_return_pct_for_short) {
      return @{ allowed = $false; reason = "benchmark regime not supportive for short (${benchmarkMax}%)" }
    }
    return @{ allowed = $true; reason = "external short alignment ok" }
  }

  return @{ allowed = $true; reason = "no external gate" }
}

function Get-MaxAffordableCash {
  param(
    $Portfolio,
    $Strategy
  )

  $cash = [decimal]::Parse([string]$Portfolio.cash_balance, [System.Globalization.CultureInfo]::InvariantCulture)
  $buffer = [decimal]$Strategy.min_cash_buffer
  $perTrade = [decimal]$Strategy.per_trade_cash

  $available = $cash - $buffer
  if ($available -le 0) {
    return [decimal]0
  }

  if ($available -lt $perTrade) {
    return $available
  }

  return $perTrade
}

function Submit-StockOrder {
  param(
    [string]$Action,
    [string]$Symbol,
    [hashtable]$Payload
  )

  $pathMap = @{
    buy = "/api/stock/buy"
    sell = "/api/stock/sell"
    short = "/api/stock/short"
    cover = "/api/stock/cover"
  }

  if (-not $pathMap.ContainsKey($Action)) {
    throw "Unsupported stock action: $Action"
  }

  return Invoke-ToolbearApi -Method POST -Path $pathMap[$Action] -Body $Payload
}

function Set-StockTrigger {
  param(
    [string]$TriggerType,
    [string]$Symbol,
    [decimal]$Price,
    [decimal]$Shares
  )

  $pathMap = @{
    stop_loss = "/api/stock/trigger/stop-loss"
    take_profit = "/api/stock/trigger/take-profit"
  }

  $body = @{
    symbol = $Symbol
    price = [string]([math]::Round([double]$Price, 4))
    shares = [string]([math]::Round([double]$Shares, 6))
  }

  return Invoke-ToolbearApi -Method POST -Path $pathMap[$TriggerType] -Body $body
}

function Ensure-ProtectiveTriggers {
  param(
    [string]$Symbol,
    $Position,
    [object[]]$ExistingTriggers,
    $Strategy
  )

  if (-not $Position) {
    return
  }

  $shares = [decimal]::Parse([string]$Position.total_shares, [System.Globalization.CultureInfo]::InvariantCulture)
  $avgCost = [decimal]::Parse([string]$Position.avg_cost, [System.Globalization.CultureInfo]::InvariantCulture)
  $side = [string]$Position.position_type

  $stopFactor = [decimal](1.0 - ([double]$Strategy.stop_loss_pct / 100.0))
  $tpFactor = [decimal](1.0 + ([double]$Strategy.take_profit_pct / 100.0))
  if ($side -eq "short") {
    $stopFactor = [decimal](1.0 + ([double]$Strategy.stop_loss_pct / 100.0))
    $tpFactor = [decimal](1.0 - ([double]$Strategy.take_profit_pct / 100.0))
  }

  $stopPrice = $avgCost * $stopFactor
  $takeProfitPrice = $avgCost * $tpFactor

  $hasStop = @($ExistingTriggers | Where-Object { $_.symbol -eq $Symbol -and $_.trigger_type -eq "stop_loss" }).Count -gt 0
  $hasTakeProfit = @($ExistingTriggers | Where-Object { $_.symbol -eq $Symbol -and $_.trigger_type -eq "take_profit" }).Count -gt 0

  if (-not $Execute) {
    if (-not $hasStop) {
      Write-Log ("[dry-run] would set stop-loss for {0} at {1}" -f $Symbol, [math]::Round([double]$stopPrice, 4))
    }
    if (-not $hasTakeProfit) {
      Write-Log ("[dry-run] would set take-profit for {0} at {1}" -f $Symbol, [math]::Round([double]$takeProfitPrice, 4))
    }
    return
  }

  if (-not $hasStop) {
    [void](Set-StockTrigger -TriggerType "stop_loss" -Symbol $Symbol -Price $stopPrice -Shares $shares)
    Write-Log ("Set stop-loss for {0}" -f $Symbol)
  }

  if (-not $hasTakeProfit) {
    [void](Set-StockTrigger -TriggerType "take_profit" -Symbol $Symbol -Price $takeProfitPrice -Shares $shares)
    Write-Log ("Set take-profit for {0}" -f $Symbol)
  }
}

function Get-EntrySignal {
  param(
    [string]$Symbol,
    [object[]]$History,
    $Quote,
    $Portfolio,
    [hashtable]$State,
    $Strategy,
    $ExternalReferenceSnapshot,
    $ExternalReferenceConfig
  )

  if ([string]$Quote.market_state -ne "REGULAR") {
    return $null
  }

  if (-not (Get-CooldownExpired -State $State -Symbol $Symbol -CooldownMinutes ([int]$Strategy.cooldown_minutes))) {
    return $null
  }

  if ((Get-OpenPositionCount -Portfolio $Portfolio) -ge [int]$Strategy.max_open_positions) {
    return $null
  }

  $cashToDeploy = Get-MaxAffordableCash -Portfolio $Portfolio -Strategy $Strategy
  if ($cashToDeploy -le 0) {
    return $null
  }

  $ret5 = Get-ReturnOverWindow -History $History -WindowMinutes 5
  $ret15 = Get-ReturnOverWindow -History $History -WindowMinutes 15
  if ($null -eq $ret5 -or $null -eq $ret15) {
    return $null
  }

  $lastPrice = [decimal]::Parse([string]$Quote.price, [System.Globalization.CultureInfo]::InvariantCulture)
  if ($lastPrice -le 0) {
    return $null
  }

  $existing = Get-PositionBySymbol -Portfolio $Portfolio -Symbol $Symbol
  if ($existing) {
    return $null
  }

  $signal = $null
  if ($ret5 -ge [double]$Strategy.entry_5m_momentum_pct -and $ret15 -ge [double]$Strategy.entry_15m_confirm_pct) {
    $signal = "buy"
  } elseif ($ret5 -le [double]$Strategy.short_5m_momentum_pct -and $ret15 -le [double]$Strategy.short_15m_confirm_pct) {
    $signal = "short"
  }

  if (-not $signal) {
    return $null
  }

  if ($ExternalReferenceConfig -and $ExternalReferenceConfig.enabled -and $ExternalReferenceConfig.require_external_alignment) {
    $alignment = Test-ExternalAlignment -Signal $signal -ReferenceSnapshot $ExternalReferenceSnapshot -Strategy $Strategy
    if (-not $alignment.allowed) {
      Write-Log ("Skip {0} {1}: {2}" -f $signal.ToUpperInvariant(), $Symbol, $alignment.reason)
      return $null
    }
  }

  $notionalCap = [decimal]$Strategy.max_notional_per_symbol
  if ($cashToDeploy -gt $notionalCap) {
    $cashToDeploy = $notionalCap
  }

  return @{
    action = $signal
    symbol = $Symbol
    amount = [math]::Round([double]$cashToDeploy, 2)
    reason = "ret5=${ret5}% ret15=${ret15}%"
  }
}

function Get-ExitSignal {
  param(
    [string]$Symbol,
    $Position,
    $Quote,
    [hashtable]$State,
    $Strategy
  )

  if (-not $Position) {
    return $null
  }

  $entry = [decimal]::Parse([string]$Position.avg_cost, [System.Globalization.CultureInfo]::InvariantCulture)
  $current = [decimal]::Parse([string]$Quote.price, [System.Globalization.CultureInfo]::InvariantCulture)
  $shares = [decimal]::Parse([string]$Position.total_shares, [System.Globalization.CultureInfo]::InvariantCulture)
  $side = [string]$Position.position_type

  if ($entry -le 0 -or $current -le 0 -or $shares -le 0) {
    return $null
  }

  $rawReturn = (([double]$current / [double]$entry) - 1.0) * 100.0
  if ($side -eq "short") {
    $rawReturn = -1.0 * $rawReturn
  }

  if (-not $State.peaks.ContainsKey($Symbol)) {
    $State.peaks[$Symbol] = @{
      best_return_pct = $rawReturn
    }
  } elseif ($rawReturn -gt [double]$State.peaks[$Symbol].best_return_pct) {
    $State.peaks[$Symbol].best_return_pct = $rawReturn
  }

  $bestReturn = [double]$State.peaks[$Symbol].best_return_pct
  $trailingDrop = $bestReturn - $rawReturn

  if ($rawReturn -le (-1.0 * [double]$Strategy.stop_loss_pct)) {
    return @{
      action = if ($side -eq "long") { "sell" } else { "cover" }
      symbol = $Symbol
      shares = [math]::Round([double]$shares, 6)
      reason = "hard stop ${rawReturn}%"
    }
  }

  if ($rawReturn -ge [double]$Strategy.take_profit_pct) {
    return @{
      action = if ($side -eq "long") { "sell" } else { "cover" }
      symbol = $Symbol
      shares = [math]::Round([double]$shares, 6)
      reason = "take profit ${rawReturn}%"
    }
  }

  if ($bestReturn -gt [double]$Strategy.trailing_stop_pct -and $trailingDrop -ge [double]$Strategy.trailing_stop_pct) {
    return @{
      action = if ($side -eq "long") { "sell" } else { "cover" }
      symbol = $Symbol
      shares = [math]::Round([double]$shares, 6)
      reason = "trailing stop best=${bestReturn}% now=${rawReturn}%"
    }
  }

  return $null
}

function Execute-Signal {
  param(
    [hashtable]$Signal,
    [hashtable]$State
  )

  $symbol = [string]$Signal.symbol
  $action = [string]$Signal.action

  if (-not $Execute) {
    Write-Log ("[dry-run] {0} {1} -> {2}" -f $action.ToUpperInvariant(), $symbol, $Signal.reason)
    Register-Action -State $State -Action @{
      timestamp = (Get-Date).ToUniversalTime().ToString("o")
      mode = "dry-run"
      action = $action
      symbol = $symbol
      reason = $Signal.reason
    }
    return
  }

  $payload = @{ symbol = $symbol }
  if ($Signal.ContainsKey("amount")) {
    $payload.amount = [string]$Signal.amount
  }
  if ($Signal.ContainsKey("shares")) {
    $payload.shares = [string]$Signal.shares
  }
  if ($Signal.ContainsKey("leverage")) {
    $payload.leverage = [int]$Signal.leverage
  }

  $response = Submit-StockOrder -Action $action -Symbol $symbol -Payload $payload
  Write-Log ("Executed {0} {1}: success={2}" -f $action.ToUpperInvariant(), $symbol, $response.success)
  Register-TradeTimestamp -State $State -Symbol $symbol
  Register-Action -State $State -Action @{
    timestamp = (Get-Date).ToUniversalTime().ToString("o")
    mode = "execute"
    action = $action
    symbol = $symbol
    reason = $Signal.reason
    response = $response
  }
}

$config = Get-Config -Path $ConfigPath
$script:BaseUrl = [string]$config.base_url
$script:Token = Resolve-Token -CliToken $Token -Config $config
$script:LogPath = [string]$config.log_path
$statePath = [string]$config.state_path
$strategy = $config.strategy
$externalReference = $config.external_reference
$watchlist = @($config.watchlist | ForEach-Object { [string]$_ })
$pollingSeconds = [int]$config.polling_seconds
$state = Get-State -Path $statePath

Write-Log ("Starting stock bot in {0} mode for {1}" -f ($(if ($Execute) { "EXECUTE" } else { "DRY-RUN" }), ($watchlist -join ", ")))

while ($true) {
  try {
    $portfolio = Get-Portfolio
    $triggers = Get-Triggers
    $quotes = @{}

    foreach ($symbol in $watchlist) {
      $quote = Get-StockPrice -Symbol $symbol
      if (-not $quote.success) {
        Write-Log ("Quote fetch failed for {0}" -f $symbol) "WARN"
        continue
      }

      $quotes[$symbol] = $quote
      Add-PriceObservation -State $state -Symbol $symbol -Quote $quote
      Write-Log ("{0} price={1} change={2}%" -f $symbol, $quote.price, $quote.change_percent)
    }

    foreach ($symbol in $watchlist) {
      if (-not $quotes.ContainsKey($symbol)) {
        continue
      }

      $quote = $quotes[$symbol]
      $position = Get-PositionBySymbol -Portfolio $portfolio -Symbol $symbol
      $history = @()
      $externalReferenceSnapshot = $null
      if ($state.price_history.ContainsKey($symbol)) {
        $history = @($state.price_history[$symbol])
      }
      if ($externalReference -and $externalReference.enabled) {
        try {
          $externalReferenceSnapshot = Get-ExternalReferenceSnapshot -Symbol $symbol -ExternalReferenceConfig $externalReference
          if ($externalReferenceSnapshot) {
            Write-Log ("{0} external ret5d={1}% sma20_gap={2}%" -f $symbol, $externalReferenceSnapshot.ret_5d_pct, $externalReferenceSnapshot.distance_from_sma20_pct)
          }
        } catch {
          Write-Log ("External reference fetch failed for {0}: {1}" -f $symbol, $_.Exception.Message) "WARN"
        }
      }

      $exitSignal = Get-ExitSignal -Symbol $symbol -Position $position -Quote $quote -State $state -Strategy $strategy
      if ($exitSignal) {
        Execute-Signal -Signal $exitSignal -State $state
        continue
      }

      if ($position) {
        Ensure-ProtectiveTriggers -Symbol $symbol -Position $position -ExistingTriggers @($triggers.triggers) -Strategy $strategy
        continue
      }

      $entrySignal = Get-EntrySignal -Symbol $symbol -History $history -Quote $quote -Portfolio $portfolio -State $state -Strategy $strategy -ExternalReferenceSnapshot $externalReferenceSnapshot -ExternalReferenceConfig $externalReference
      if ($entrySignal) {
        Execute-Signal -Signal $entrySignal -State $state
      }
    }

    Save-State -State $state -Path $statePath
  } catch {
    Write-Log $_.Exception.Message "ERROR"
  }

  if ($Once) {
    break
  }

  Start-Sleep -Seconds $pollingSeconds
}
