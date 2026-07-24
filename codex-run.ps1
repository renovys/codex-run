# codex-run.ps1 - watchdog wrapper for delegated GPT-5.6 Sol (codex) runs
# It detects unresponsive runs through a wall-clock limit or output silence, kills the process tree,
# and records the log path and termination reason in a standard format so the calling agent can take over.
# Usage: codex-run [--timeout SEC] [--stall SEC] [--stdin FILE] [--tail N] [--codex-bin PATH]
#                  [--help] [--version] [--] <codex args...>
# Exit codes: 0=success / 124=wall-clock limit / 125=output stall / 2=usage or argument error / other=codex exit code
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$AllArgs)
# Do not use CmdletBinding because common parameters such as -OutVariable conflict with codex's -o.
# Parse flags directly under the same names as the bash version of codex-run.

$ErrorActionPreference = "Stop"
$Version = "0.1.0"

function Show-Usage {
@'
Usage:
  codex-run [--timeout SEC] [--stall SEC] [--stdin FILE] [--tail N] [--codex-bin PATH]
            [--help] [--version] [--] <codex args...>

Options:
  --timeout SEC     Wall-clock limit (seconds, default: 900, minimum: 1)
  --stall SEC       Output-silence timeout (seconds, default: 0=off)
  --stdin FILE      Regular file to use as codex standard input
  --tail N          Log lines to print after exit (default: 40)
  --codex-bin PATH  codex executable (default: codex)
  --help            Print this help
  --version         Print version
  --                Stop parsing wrapper arguments

Environment:
  CODEX_RUN_TIMEOUT, CODEX_RUN_STALL, CODEX_RUN_TAIL, CODEX_BIN
'@
}

function Fail-Argument([string]$Message) {
  [Console]::Error.WriteLine("codex-run: $Message")
  exit 2
}

function Convert-ValidatedNumber([string]$Name, [AllowNull()][string]$Value, [long]$Minimum) {
  if ($null -eq $Value -or $Value -notmatch '^[0-9]+$') {
    Fail-Argument "$Name must be numeric"
  }
  [long]$parsed = 0
  if (-not [long]::TryParse(
      $Value,
      [Globalization.NumberStyles]::None,
      [Globalization.CultureInfo]::InvariantCulture,
      [ref]$parsed)) {
    Fail-Argument "$Name must be a number in the supported range"
  }
  if ($parsed -lt $Minimum) {
    Fail-Argument "$Name must be at least $Minimum"
  }
  return $parsed
}

function Require-NextValue([string]$Name, [int]$Index, [int]$Count) {
  if (($Index + 1) -ge $Count) {
    Fail-Argument "$Name requires a value"
  }
}

# Build one Windows command-line argument by reversing the CommandLineToArgvW rules.
function Quote-WindowsArgument([AllowEmptyString()][string]$Argument) {
  if ($Argument.Length -gt 0 -and $Argument -notmatch '[\s"]') {
    return $Argument
  }

  $builder = New-Object Text.StringBuilder
  [void]$builder.Append('"')
  $slashes = 0
  foreach ($ch in $Argument.ToCharArray()) {
    if ($ch -eq '\') {
      $slashes++
      continue
    }
    if ($ch -eq '"') {
      if ($slashes -gt 0) { [void]$builder.Append(('\' * ($slashes * 2))) }
      [void]$builder.Append('\"')
      $slashes = 0
      continue
    }
    if ($slashes -gt 0) {
      [void]$builder.Append(('\' * $slashes))
      $slashes = 0
    }
    [void]$builder.Append($ch)
  }
  if ($slashes -gt 0) { [void]$builder.Append(('\' * ($slashes * 2))) }
  [void]$builder.Append('"')
  return $builder.ToString()
}

# Capture the root and all descendant PIDs from a snapshot of parent-PID relationships.
function Get-ProcessTreeIds([int]$RootId) {
  $rows = @()
  try {
    $rows = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
      Select-Object ProcessId, ParentProcessId)
  } catch {}

  $ids = @([int]$RootId)
  $changed = $true
  while ($changed) {
    $changed = $false
    foreach ($row in $rows) {
      $parent = [int]$row.ParentProcessId
      $child = [int]$row.ProcessId
      if ($ids -contains $parent -and $ids -notcontains $child) {
        $ids += $child
        $changed = $true
      }
    }
  }
  return @($ids | Sort-Object -Unique)
}

function Get-LiveProcessIds([int[]]$Ids) {
  $live = @()
  foreach ($id in @($Ids | Sort-Object -Unique)) {
    try {
      if (Get-Process -Id $id -ErrorAction SilentlyContinue) { $live += [int]$id }
    } catch {}
  }
  return @($live)
}

# taskkill reports already-dead children on stderr, which is a normal race while killing a tree.
# Under $ErrorActionPreference="Stop", stderr from a native command becomes a terminating error,
# so lower the setting only for this call; otherwise cleanup stops and processes survive.
function Invoke-Taskkill([string[]]$TaskkillArgs) {
  $prev = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    & taskkill.exe @TaskkillArgs 2>&1 | Out-Null
    return $LASTEXITCODE
  } catch {
    return -1
  } finally {
    $ErrorActionPreference = $prev
  }
}

# Allow five seconds for a graceful exit, then clear survivors with taskkill /F and per-PID force.
function Stop-CodexTree([int]$RootId, [int[]]$KnownIds) {
  $allIds = @($KnownIds + (Get-ProcessTreeIds $RootId) | Sort-Object -Unique)

  $graceExit = Invoke-Taskkill @("/PID", "$RootId", "/T")
  Start-Sleep -Seconds 5

  $allIds = @($allIds + (Get-ProcessTreeIds $RootId) | Sort-Object -Unique)
  $live = @(Get-LiveProcessIds $allIds)
  if ($graceExit -ne 0 -or $live.Count -gt 0) {
    $forceExit = Invoke-Taskkill @("/PID", "$RootId", "/T", "/F")
    $live = @(Get-LiveProcessIds $allIds)
    if ($forceExit -ne 0 -or $live.Count -gt 0) {
      foreach ($id in $live) {
        try { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue } catch {}
      }
    }
    # Recheck every observed PID regardless of whether taskkill reported failure.
  }
  return @(Get-LiveProcessIds $allIds)
}

$timeoutRaw = [Environment]::GetEnvironmentVariable("CODEX_RUN_TIMEOUT")
$stallRaw = [Environment]::GetEnvironmentVariable("CODEX_RUN_STALL")
$tailRaw = [Environment]::GetEnvironmentVariable("CODEX_RUN_TAIL")
$CodexBin = [Environment]::GetEnvironmentVariable("CODEX_BIN")
if ($null -eq $timeoutRaw) { $timeoutRaw = "900" }
if ($null -eq $stallRaw) { $stallRaw = "0" }
if ($null -eq $tailRaw) { $tailRaw = "40" }
if ([string]::IsNullOrEmpty($CodexBin)) { $CodexBin = "codex" }

$TimeoutSec = $null
$StallSec = $null
$TailLines = $null
$StdinFile = $null
$CodexArgs = @()
$timeoutFromCli = $false
$stallFromCli = $false
$tailFromCli = $false

$i = 0
while ($i -lt $AllArgs.Count) {
  $current = $AllArgs[$i]
  switch ($current) {
    "--timeout" {
      Require-NextValue "--timeout" $i $AllArgs.Count
      $TimeoutSec = Convert-ValidatedNumber "--timeout" $AllArgs[$i + 1] 1
      $timeoutFromCli = $true
      $i += 2
      continue
    }
    "--stall" {
      Require-NextValue "--stall" $i $AllArgs.Count
      $StallSec = Convert-ValidatedNumber "--stall" $AllArgs[$i + 1] 0
      $stallFromCli = $true
      $i += 2
      continue
    }
    "--stdin" {
      Require-NextValue "--stdin" $i $AllArgs.Count
      if ([string]::IsNullOrEmpty($AllArgs[$i + 1])) { Fail-Argument "--stdin value is empty" }
      $StdinFile = $AllArgs[$i + 1]
      $i += 2
      continue
    }
    "--tail" {
      Require-NextValue "--tail" $i $AllArgs.Count
      $TailLines = Convert-ValidatedNumber "--tail" $AllArgs[$i + 1] 0
      $tailFromCli = $true
      $i += 2
      continue
    }
    "--codex-bin" {
      Require-NextValue "--codex-bin" $i $AllArgs.Count
      if ([string]::IsNullOrEmpty($AllArgs[$i + 1])) { Fail-Argument "--codex-bin value is empty" }
      $CodexBin = $AllArgs[$i + 1]
      $i += 2
      continue
    }
    "--help" {
      Show-Usage
      exit 0
    }
    "--version" {
      Write-Output "codex-run $Version"
      exit 0
    }
    "--" {
      $i++
      if ($i -lt $AllArgs.Count) { $CodexArgs = @($AllArgs[$i..($AllArgs.Count - 1)]) }
      $i = $AllArgs.Count
      continue
    }
    default {
      $CodexArgs = @($AllArgs[$i..($AllArgs.Count - 1)])
      $i = $AllArgs.Count
      continue
    }
  }
}

if (-not $timeoutFromCli) { $TimeoutSec = Convert-ValidatedNumber "--timeout/CODEX_RUN_TIMEOUT" $timeoutRaw 1 }
if (-not $stallFromCli) { $StallSec = Convert-ValidatedNumber "--stall/CODEX_RUN_STALL" $stallRaw 0 }
if (-not $tailFromCli) { $TailLines = Convert-ValidatedNumber "--tail/CODEX_RUN_TAIL" $tailRaw 0 }

if (-not $CodexArgs -or $CodexArgs.Count -eq 0) {
  Fail-Argument "no arguments. See codex-run --help"
}

if ($null -ne $StdinFile -and
    -not (Test-Path -LiteralPath $StdinFile -PathType Leaf)) {
  Fail-Argument "cannot read stdin regular file: $StdinFile"
}

# Add --skip-git-repo-check to delegated exec runs because codex otherwise rejects non-git working directories.
if ($CodexArgs[0] -eq "exec" -and ($CodexArgs -notcontains "--skip-git-repo-check")) {
  $rest = @()
  if ($CodexArgs.Count -gt 1) { $rest = @($CodexArgs[1..($CodexArgs.Count - 1)]) }
  $CodexArgs = @("exec", "--skip-git-repo-check") + $rest
}

$logDir = Join-Path $HOME ".codex-runs"
if (-not (Test-Path -LiteralPath $logDir -PathType Container)) {
  New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}
Get-ChildItem -LiteralPath $logDir -Filter *.log -ErrorAction SilentlyContinue |
  Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-30) } |
  Remove-Item -Force -ErrorAction SilentlyContinue   # Prune run logs older than 30 days.

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$runId = "$stamp-$PID-$([Guid]::NewGuid().ToString('N'))"
$outLog = Join-Path $logDir "$stamp-$PID.log"
$stdoutLog = Join-Path $logDir "$runId.stdout.tmp"
$stderrLog = Join-Path $logDir "$runId.stderr.tmp"
$ownedStdin = $false
$nullIn = $null
$watch = New-Object Diagnostics.Stopwatch
$reason = "ok"
$decisionElapsed = 0
$totalElapsed = 0
$rc = 1
$proc = $null
$knownTreeIds = @()
$leftIds = @()
$runError = $null
$needCleanup = $false

try {
  if ($null -ne $StdinFile) {
    $nullIn = $StdinFile
  } else {
    # Give each run its own empty stdin file so concurrent runs never share one.
    $nullIn = Join-Path $logDir "$runId.empty.stdin"
    $ownedStdin = $true
    New-Item -ItemType File -Path $nullIn -Force | Out-Null
  }
  New-Item -ItemType File -Path $stdoutLog -Force | Out-Null
  New-Item -ItemType File -Path $stderrLog -Force | Out-Null

  $quoted = @()
  foreach ($argument in $CodexArgs) {
    $quoted += Quote-WindowsArgument $argument
  }

  Set-Content -LiteralPath $outLog -Encoding UTF8 -Value @(
    "# codex-run start: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') / timeout $($TimeoutSec)s / stall $($StallSec)s / stdin $nullIn",
    "# command: $CodexBin $($quoted -join ' ')",
    "#---"
  )
  $watch.Start()

  $proc = Start-Process -FilePath $CodexBin -ArgumentList $quoted -NoNewWindow -PassThru `
    -RedirectStandardOutput $stdoutLog -RedirectStandardError $stderrLog -RedirectStandardInput $nullIn
  $handle = $proc.Handle   # PS 5.1 requires acquiring the handle before exit to read ExitCode afterward.
  $null = $handle
  $knownTreeIds = @([int]$proc.Id)
  $needCleanup = $true
  $lastBytes = 0L
  $lastActivity = 0.0

  while (-not $proc.HasExited) {
    Start-Sleep -Seconds 1
    if ($proc.HasExited) { break }   # A normal exit during sleep must not be mistaken for a limit breach.

    $elapsed = $watch.Elapsed.TotalSeconds
    $bytes = (Get-Item -LiteralPath $stdoutLog).Length + (Get-Item -LiteralPath $stderrLog).Length
    if ($bytes -ne $lastBytes) {
      $lastBytes = $bytes
      $lastActivity = $elapsed
    }
    if ($elapsed -ge $TimeoutSec) {
      $reason = "timeout"
      $decisionElapsed = [int][Math]::Floor($elapsed)
      break
    }
    if ($StallSec -gt 0 -and ($elapsed - $lastActivity) -ge $StallSec) {
      $reason = "stall"
      $decisionElapsed = [int][Math]::Floor($elapsed)
      break
    }
  }

  if ($reason -eq "ok") {
    $proc.WaitForExit()
    $rc = $proc.ExitCode
    if ($null -eq $rc) { $rc = 0 }
    $decisionElapsed = [int][Math]::Floor($watch.Elapsed.TotalSeconds)
    $needCleanup = $false
  } else {
    $leftIds = @(Stop-CodexTree $proc.Id $knownTreeIds)
    if ($reason -eq "timeout") { $rc = 124 } else { $rc = 125 }
    $needCleanup = $false
  }
} catch {
  $runError = $_.Exception.Message
} finally {
  if ($null -ne $proc) {
    try {
      $knownTreeIds = @($knownTreeIds + (Get-ProcessTreeIds $proc.Id) | Sort-Object -Unique)
      $liveNow = @(Get-LiveProcessIds $knownTreeIds)
      if ($needCleanup -or $liveNow.Count -gt 0) {
        $leftIds = @(Stop-CodexTree $proc.Id $knownTreeIds)
      }
    } catch {}
  }

  try {
    $stdoutText = @(Get-Content -LiteralPath $stdoutLog -Encoding UTF8 -ErrorAction SilentlyContinue)
    if ($stdoutText.Count -gt 0) {
      Add-Content -LiteralPath $outLog -Encoding UTF8 -Value $stdoutText
    }
    $stderrText = @(Get-Content -LiteralPath $stderrLog -Encoding UTF8 -ErrorAction SilentlyContinue)
    if ($stderrText.Count -gt 0) {
      Add-Content -LiteralPath $outLog -Encoding UTF8 -Value $stderrText
    }
  } catch {
    if ($null -eq $runError) { $runError = $_.Exception.Message }
  }

  Remove-Item -LiteralPath $stdoutLog -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $stderrLog -Force -ErrorAction SilentlyContinue
  if ($ownedStdin) {
    Remove-Item -LiteralPath $nullIn -Force -ErrorAction SilentlyContinue
  }
  $watch.Stop()
  $totalElapsed = [int][Math]::Floor($watch.Elapsed.TotalSeconds)
}

if ($null -ne $runError) {
  [Console]::Error.WriteLine("codex-run: execution error: $runError")
  exit 1
}

Write-Host "----- codex output (last $TailLines lines) -----"
Get-Content -LiteralPath $outLog -Encoding UTF8 -Tail $TailLines -ErrorAction SilentlyContinue |
  ForEach-Object { Write-Host $_ }
Write-Host "----- codex-run summary -----"
switch ($reason) {
  "ok"      { Write-Host "status: exited normally (codex exit code $rc)" }
  "timeout" { Write-Host "status: wall-clock limit of $($TimeoutSec)s exceeded - terminated; caller should take over" }
  "stall"   { Write-Host "status: no output for $($StallSec)s (presumed stalled) - terminated; caller should take over" }
}
if ($leftIds.Count -gt 0) {
  Write-Host "warning: codex process still running (PID $($leftIds -join ',')) - inspect it before delegating again"
}
Write-Host "decision at: $($decisionElapsed)s / total elapsed: $($totalElapsed)s / full log: $outLog"
Write-Host "codex-run: status=$reason exit_code=$rc elapsed_sec=$totalElapsed log=$outLog"
exit $rc
