# codex-run.ps1 — GPT-5.6 Sol(codex) 위임 실행 래퍼 (윈도우판, 서버 ~/.local/bin/codex-run 과 같은 규격)
# 목적: codex가 무응답으로 매달리는 상황을 상한 시간·무출력 정체로 감지해 프로세스 트리째 정리하고,
#       본체 에이전트가 이어받을 수 있도록 로그 경로와 종료 사유를 표준 형식으로 남긴다.
# 사용: codex-run [--timeout SEC] [--stall SEC] [--stdin FILE] [--tail N] [--codex-bin PATH]
#                  [--help] [--version] [--] <codex 인자...>
# 종료코드: 0=정상 / 124=전체 상한 초과 / 125=무출력 정체 / 2=사용법·인자 오류 / 그 외=codex 자체 종료코드
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$AllArgs)
# CmdletBinding을 쓰지 않는다 — 공통 파라미터(-OutVariable 등)가 codex의 -o와 충돌한다.
# 플래그는 bash판 codex-run과 같은 이름으로 직접 파싱한다.

$ErrorActionPreference = "Stop"
$Version = "0.1.0"

function Show-Usage {
@'
사용법:
  codex-run [--timeout SEC] [--stall SEC] [--stdin FILE] [--tail N] [--codex-bin PATH]
            [--help] [--version] [--] <codex 인자...>

옵션:
  --timeout SEC     전체 상한(초, 기본값: 900, 1 이상)
  --stall SEC       무출력 정체 감시(초, 기본값: 0=끔)
  --stdin FILE      codex 표준입력으로 사용할 일반 파일
  --tail N          종료 후 출력할 로그 줄 수(기본값: 40)
  --codex-bin PATH  codex 실행 파일(기본값: codex)
  --help            이 도움말 출력
  --version         버전 출력
  --                래퍼 인자 파싱 종료

환경변수:
  CODEX_RUN_TIMEOUT, CODEX_RUN_STALL, CODEX_RUN_TAIL, CODEX_BIN
'@
}

function Fail-Argument([string]$Message) {
  [Console]::Error.WriteLine("codex-run: $Message")
  exit 2
}

function Convert-ValidatedNumber([string]$Name, [AllowNull()][string]$Value, [long]$Minimum) {
  if ($null -eq $Value -or $Value -notmatch '^[0-9]+$') {
    Fail-Argument "$Name 값은 숫자여야 한다"
  }
  [long]$parsed = 0
  if (-not [long]::TryParse(
      $Value,
      [Globalization.NumberStyles]::None,
      [Globalization.CultureInfo]::InvariantCulture,
      [ref]$parsed)) {
    Fail-Argument "$Name 값은 지원 범위의 숫자여야 한다"
  }
  if ($parsed -lt $Minimum) {
    Fail-Argument "$Name 값은 $Minimum 이상이어야 한다"
  }
  return $parsed
}

function Require-NextValue([string]$Name, [int]$Index, [int]$Count) {
  if (($Index + 1) -ge $Count) {
    Fail-Argument "$Name 값이 없다"
  }
}

# CommandLineToArgvW의 역규칙에 맞춰 인자 하나를 Windows 명령행 문자열로 만든다.
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

# 한 시점의 부모 PID 관계를 따라 루트와 모든 하위 PID를 수집한다.
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

# taskkill 은 이미 죽은 자식에 대해 stderr 로 오류를 낸다 — 트리를 죽이는 중에는 정상적인 경쟁 상태다.
# $ErrorActionPreference="Stop" 아래에서 네이티브 명령의 stderr 는 종료성 예외로 승격되므로,
# 이 호출 동안만 설정을 낮춘다. (낮추지 않으면 정리가 중단돼 프로세스가 그대로 살아남는다)
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

# 먼저 5초간 정상 종료를 기다린 뒤 taskkill /F와 PID별 강제 종료로 잔존을 재정리한다.
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
    # taskkill 실패 여부와 무관하게 직접 확인한 PID를 모두 다시 검사한다.
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
      if ([string]::IsNullOrEmpty($AllArgs[$i + 1])) { Fail-Argument "--stdin 값이 비어 있다" }
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
      if ([string]::IsNullOrEmpty($AllArgs[$i + 1])) { Fail-Argument "--codex-bin 값이 비어 있다" }
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
  Fail-Argument "인자가 없다. 사용법은 codex-run --help"
}

if ($null -ne $StdinFile -and
    -not (Test-Path -LiteralPath $StdinFile -PathType Leaf)) {
  Fail-Argument "stdin 일반 파일을 읽을 수 없다: $StdinFile"
}

# exec 위임에 --skip-git-repo-check 자동 부착 (git 저장소 밖이면 codex가 즉시 거부한다)
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
  Remove-Item -Force -ErrorAction SilentlyContinue   # 30일 지난 실행 로그 정리

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
    # 동시 실행끼리 빈 stdin 파일을 공유하지 않도록 실행별 고유 파일을 쓴다.
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
    "# codex-run 실행: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') / 상한 $($TimeoutSec)초 / 정체 $($StallSec)초 / stdin $nullIn",
    "# 명령: $CodexBin $($quoted -join ' ')",
    "#---"
  )
  $watch.Start()

  $proc = Start-Process -FilePath $CodexBin -ArgumentList $quoted -NoNewWindow -PassThru `
    -RedirectStandardOutput $stdoutLog -RedirectStandardError $stderrLog -RedirectStandardInput $nullIn
  $handle = $proc.Handle   # 핸들을 미리 잡아둬야 종료 후 ExitCode를 읽을 수 있다(PS 5.1 특성)
  $null = $handle
  $knownTreeIds = @([int]$proc.Id)
  $needCleanup = $true
  $lastBytes = 0L
  $lastActivity = 0.0

  while (-not $proc.HasExited) {
    Start-Sleep -Seconds 1
    if ($proc.HasExited) { break }   # 대기 중 정상 종료 — 상한으로 오판하지 않는다

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
  [Console]::Error.WriteLine("codex-run: 실행 오류: $runError")
  exit 1
}

Write-Host "----- codex 출력(마지막 $TailLines 줄) -----"
Get-Content -LiteralPath $outLog -Encoding UTF8 -Tail $TailLines -ErrorAction SilentlyContinue |
  ForEach-Object { Write-Host $_ }
Write-Host "----- codex-run 요약 -----"
switch ($reason) {
  "ok"      { Write-Host "상태: 정상 종료 (codex 종료코드 $rc)" }
  "timeout" { Write-Host "상태: 전체 상한 $TimeoutSec 초 초과로 강제 종료 — 본체가 이어받을 것" }
  "stall"   { Write-Host "상태: $StallSec 초간 무출력 정체(추정)로 강제 종료 — 본체가 이어받을 것" }
}
if ($leftIds.Count -gt 0) {
  Write-Host "경고: 종료되지 않은 codex 프로세스가 남아 있다(PID $($leftIds -join ',')) — 재위임 전에 확인할 것"
}
Write-Host "판정 시각: $decisionElapsed 초 / 총 경과: $totalElapsed 초 / 로그 전문: $outLog"
Write-Host "codex-run: status=$reason exit_code=$rc elapsed_sec=$totalElapsed log=$outLog"
exit $rc
