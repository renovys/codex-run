# Self-test harness for codex-run.ps1, using fake codex binaries to reproduce each scenario.
# Usage: .\test\run-tests.ps1 [path to codex-run.ps1]   (default: .\codex-run.ps1 at the repository root)
# Exit codes: 0=all passed / 1=one or more failures
# The real codex is never called, so this consumes no API quota or credits.
param([string]$Wrapper)

# Some runners, including GitHub Actions, start the shell with $ErrorActionPreference="Stop".
# The wrapper sends usage errors to stderr to match the bash contract, but that setting promotes native
# stderr to a terminating NativeCommandError and kills the test while it verifies an expected rejection.
$ErrorActionPreference = "Continue"

if (-not $Wrapper) {
  $Wrapper = Join-Path (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)) "codex-run.ps1"
}
$Wrapper = (Resolve-Path -LiteralPath $Wrapper).Path
if (-not (Test-Path -LiteralPath $Wrapper)) { Write-Host "codex-run.ps1 not found: $Wrapper"; exit 2 }

$td = Join-Path ([IO.Path]::GetTempPath()) ("codexrun-test-" + [Guid]::NewGuid().ToString("N").Substring(0,8))
New-Item -ItemType Directory -Path $td -Force | Out-Null

$pass = 0; $fail = 0
function Check($name, $expected, $actual) {
  if ("$expected" -eq "$actual") {
    Write-Host ("  ok   {0,-34} ({1})" -f $name, $actual); $script:pass++
  } else {
    Write-Host ("  FAIL {0,-34} expected={1} actual={2}" -f $name, $expected, $actual); $script:fail++
  }
}
function RunW { & powershell -NoProfile -File $Wrapper @args 2>&1 | Out-Null; return $LASTEXITCODE }

# Use .cmd fake codex binaries so Start-Process can launch them directly.
Set-Content "$td\ok.cmd"   -Value "@echo off`r`necho progress`r`nexit /b 0"                -Encoding OEM
Set-Content "$td\rc7.cmd"  -Value "@echo off`r`necho failed`r`nexit /b 7"                  -Encoding OEM
Set-Content "$td\hang.cmd" -Value "@echo off`r`necho start`r`nping -n 300 127.0.0.1 > nul" -Encoding OEM

Write-Host "codex-run tests: $Wrapper"
Write-Host "PowerShell: $($PSVersionTable.PSVersion)"

# --- Basic behavior ---
Check "normal exit"                     0   (RunW --timeout 30 --codex-bin "$td\ok.cmd" run)
Check "codex exit-code pass-through"    7   (RunW --timeout 30 --codex-bin "$td\rc7.cmd" run)
Check "wall-clock limit"                124 (RunW --timeout 10 --codex-bin "$td\hang.cmd" run)
Check "output stall"                    125 (RunW --timeout 120 --stall 10 --codex-bin "$td\hang.cmd" run)

# --- Process cleanup (taskkill /T includes the child ping) ---
Start-Sleep -Seconds 2
Check "child process cleanup" 0 (@(Get-Process -Name ping -ErrorAction SilentlyContinue).Count)

# --- Argument contract (must match the bash version) ---
Check "reject no arguments"                 2 (RunW)
Check "reject missing --timeout value"      2 (RunW --timeout)
Check "reject nonnumeric --timeout"         2 (RunW --timeout abc run)
Check "reject --timeout 0"                  2 (RunW --timeout 0 run)
Check "reject missing --stdin file"         2 (RunW --stdin "$td\missing-file.txt" run)
Check "reject --stdin directory"            2 (RunW --stdin "$td" --codex-bin "$td\ok.cmd" run)
$env:CODEX_RUN_TIMEOUT = "abc"
Check "reject nonnumeric environment"       2 (RunW --codex-bin "$td\ok.cmd" run)
Remove-Item Env:\CODEX_RUN_TIMEOUT -ErrorAction SilentlyContinue
Check "accept --stall 0"                    0 (RunW --stall 0 --codex-bin "$td\ok.cmd" run)

# --- Help and version (must not call codex) ---
Check "--help rc=0" 0 (RunW --help)
$ver = & powershell -NoProfile -File $Wrapper --version 2>&1
Check "--version string" $true ("$ver" -match "0\.1\.0")

# --- Machine-readable line ---
$out = & powershell -NoProfile -File $Wrapper --timeout 30 --codex-bin "$td\ok.cmd" run 2>&1
Check "machine line (ok)" $true ("$out" -match "status=ok exit_code=0")
$out = & powershell -NoProfile -File $Wrapper --timeout 10 --codex-bin "$td\hang.cmd" run 2>&1
Check "machine line (timeout)" $true ("$out" -match "status=timeout exit_code=124")
$out = & powershell -NoProfile -File $Wrapper --timeout 120 --stall 10 --codex-bin "$td\hang.cmd" run 2>&1
Check "machine line (stall)" $true ("$out" -match "status=stall exit_code=125")

Remove-Item $td -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "passed $pass / failed $fail"
if ($fail -gt 0) { exit 1 } else { exit 0 }
