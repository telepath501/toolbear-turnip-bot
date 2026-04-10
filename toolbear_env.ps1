Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-EnvFileVariables {
  param(
    [string]$EnvPath
  )

  $values = @{}
  if (-not (Test-Path $EnvPath)) {
    return $values
  }

  foreach ($line in Get-Content -Path $EnvPath -Encoding UTF8) {
    if ([string]::IsNullOrWhiteSpace($line) -or $line.Trim().StartsWith("#")) {
      continue
    }

    $parts = $line -split "=", 2
    if ($parts.Count -eq 2) {
      $values[$parts[0].Trim()] = $parts[1].Trim()
    }
  }

  return $values
}

function Set-EnvFileVariable {
  param(
    [string]$EnvPath,
    [string]$Name,
    [string]$Value
  )

  $lines = @()
  if (Test-Path $EnvPath) {
    $lines = @(Get-Content -Path $EnvPath -Encoding UTF8)
  }

  $updated = $false
  for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match "^\s*${Name}\s*=") {
      $lines[$i] = "${Name}=${Value}"
      $updated = $true
      break
    }
  }

  if (-not $updated) {
    if ($lines.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($lines[-1])) {
      $lines += ""
    }
    $lines += "${Name}=${Value}"
  }

  Set-Content -Path $EnvPath -Value $lines -Encoding UTF8
}

function Read-FileTextShared {
  param(
    [string]$Path
  )

  try {
    $fileStream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
      $reader = New-Object System.IO.StreamReader($fileStream, [System.Text.Encoding]::ASCII, $true)
      try {
        return $reader.ReadToEnd()
      } finally {
        $reader.Dispose()
      }
    } finally {
      $fileStream.Dispose()
    }
  } catch {
    return $null
  }
}

function Get-ChromeLocalStorageProfiles {
  $userDataRoot = Join-Path $env:LOCALAPPDATA "Google\Chrome\User Data"
  if (-not (Test-Path $userDataRoot)) {
    return @()
  }

  return @(Get-ChildItem -Path $userDataRoot -Directory | Where-Object {
    $_.Name -eq "Default" -or $_.Name -like "Profile *"
  })
}

function Find-ToolbearTokenFromChrome {
  $best = $null
  $tokenPattern = [regex]'Bearer\s+([A-Za-z0-9._-]{20,})'

  foreach ($profile in Get-ChromeLocalStorageProfiles) {
    $levelDbPath = Join-Path $profile.FullName "Local Storage\leveldb"
    if (-not (Test-Path $levelDbPath)) {
      continue
    }

    $files = @(Get-ChildItem -Path $levelDbPath -File | Where-Object { $_.Extension -in @(".ldb", ".log") } | Sort-Object LastWriteTimeUtc -Descending)
    foreach ($file in $files) {
      $content = Read-FileTextShared -Path $file.FullName
      if (-not $content) {
        continue
      }

      foreach ($match in $tokenPattern.Matches($content)) {
        $token = [string]$match.Groups[1].Value
        if ([string]::IsNullOrWhiteSpace($token)) {
          continue
        }

        $start = [Math]::Max(0, $match.Index - 600)
        $length = [Math]::Min($content.Length - $start, 1200)
        $context = $content.Substring($start, $length).ToLowerInvariant()

        $score = 0
        if ($context.Contains("kuma.homes")) { $score += 200 }
        if ($context.Contains("lilium")) { $score += 200 }
        if ($context.Contains("authorization")) { $score += 30 }
        if ($context.Contains("bearer")) { $score += 10 }

        $candidate = @{
          token = $token
          score = $score
          timestamp = $file.LastWriteTimeUtc
          profile = $profile.Name
          path = $file.FullName
        }

        if ($null -eq $best) {
          $best = $candidate
          continue
        }

        if ($candidate.score -gt $best.score) {
          $best = $candidate
          continue
        }

        if ($candidate.score -eq $best.score -and $candidate.timestamp -gt $best.timestamp) {
          $best = $candidate
        }
      }
    }
  }

  if ($null -eq $best) {
    return $null
  }

  return $best.token
}

function Load-ToolbearEnvironment {
  param(
    [string]$RootPath
  )

  $envPath = Join-Path $RootPath ".env"
  $envValues = Get-EnvFileVariables -EnvPath $envPath

  foreach ($entry in $envValues.GetEnumerator()) {
    [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value)
  }

  $token = $env:TOOLBEAR_TOKEN
  if (-not $token -and $envValues.ContainsKey("TOOLBEAR_TOKEN")) {
    $token = [string]$envValues["TOOLBEAR_TOKEN"]
  }

  if (-not $token) {
    $detectedToken = Find-ToolbearTokenFromChrome
    if ($detectedToken) {
      [Environment]::SetEnvironmentVariable("TOOLBEAR_TOKEN", $detectedToken)
      Set-EnvFileVariable -EnvPath $envPath -Name "TOOLBEAR_TOKEN" -Value $detectedToken
    }
  }
}
