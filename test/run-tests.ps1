# codex-run.ps1 자체 검증 하네스 — 가짜 codex 바이너리로 각 시나리오를 재현한다.
# 사용: .\test\run-tests.ps1 [codex-run.ps1 경로]   (기본: 저장소 루트의 .\codex-run.ps1)
# 종료코드: 0=전부 통과 / 1=실패 있음
# 실제 codex를 호출하지 않으므로 API 사용량·과금이 발생하지 않는다.
param([string]$Wrapper)

if (-not $Wrapper) {
  $Wrapper = Join-Path (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)) "codex-run.ps1"
}
$Wrapper = (Resolve-Path -LiteralPath $Wrapper).Path
if (-not (Test-Path -LiteralPath $Wrapper)) { Write-Host "codex-run.ps1을 찾을 수 없다: $Wrapper"; exit 2 }

$td = Join-Path ([IO.Path]::GetTempPath()) ("codexrun-test-" + [Guid]::NewGuid().ToString("N").Substring(0,8))
New-Item -ItemType Directory -Path $td -Force | Out-Null

$pass = 0; $fail = 0
function Check($name, $expected, $actual) {
  if ("$expected" -eq "$actual") {
    Write-Host ("  ok   {0,-34} ({1})" -f $name, $actual); $script:pass++
  } else {
    Write-Host ("  FAIL {0,-34} 기대={1} 실제={2}" -f $name, $expected, $actual); $script:fail++
  }
}
function RunW { & powershell -NoProfile -File $Wrapper @args 2>&1 | Out-Null; return $LASTEXITCODE }

# 가짜 codex — .cmd 로 만들어 Start-Process 가 바로 띄울 수 있게 한다
Set-Content "$td\ok.cmd"   -Value "@echo off`r`necho progress`r`nexit /b 0"                -Encoding OEM
Set-Content "$td\rc7.cmd"  -Value "@echo off`r`necho failed`r`nexit /b 7"                  -Encoding OEM
Set-Content "$td\hang.cmd" -Value "@echo off`r`necho start`r`nping -n 300 127.0.0.1 > nul" -Encoding OEM

Write-Host "codex-run 검증: $Wrapper"
Write-Host "PowerShell: $($PSVersionTable.PSVersion)"

# --- 기본 동작 ---
Check "정상 종료"            0   (RunW --timeout 30 --codex-bin "$td\ok.cmd" run)
Check "codex 종료코드 전달"  7   (RunW --timeout 30 --codex-bin "$td\rc7.cmd" run)
Check "전체 상한 초과"       124 (RunW --timeout 10 --codex-bin "$td\hang.cmd" run)
Check "무출력 정체"          125 (RunW --timeout 120 --stall 10 --codex-bin "$td\hang.cmd" run)

# --- 프로세스 정리 (taskkill /T 로 자식 ping 까지) ---
Start-Sleep -Seconds 2
Check "자식 프로세스 정리" 0 (@(Get-Process -Name ping -ErrorAction SilentlyContinue).Count)

# --- 인자 계약 (bash 판과 동일해야 한다) ---
Check "인자 없음 거부"          2 (RunW)
Check "--timeout 값 없음 거부"  2 (RunW --timeout)
Check "숫자 아닌 --timeout 거부" 2 (RunW --timeout abc run)
Check "--timeout 0 거부"        2 (RunW --timeout 0 run)
Check "없는 --stdin 파일 거부"  2 (RunW --stdin "$td\없는파일.txt" run)
Check "--stdin 디렉터리 거부"   2 (RunW --stdin "$td" --codex-bin "$td\ok.cmd" run)
$env:CODEX_RUN_TIMEOUT = "abc"
Check "환경변수 비숫자 거부"    2 (RunW --codex-bin "$td\ok.cmd" run)
Remove-Item Env:\CODEX_RUN_TIMEOUT -ErrorAction SilentlyContinue
Check "--stall 0 허용"          0 (RunW --stall 0 --codex-bin "$td\ok.cmd" run)

# --- 도움말·버전 (codex 를 호출하지 않아야 한다) ---
Check "--help rc=0" 0 (RunW --help)
$ver = & powershell -NoProfile -File $Wrapper --version 2>&1
Check "--version 문자열" $true ("$ver" -match "0\.1\.0")

# --- 기계 판독 줄 ---
$out = & powershell -NoProfile -File $Wrapper --timeout 30 --codex-bin "$td\ok.cmd" run 2>&1
Check "기계판독 줄(정상)" $true ("$out" -match "status=ok exit_code=0")
$out = & powershell -NoProfile -File $Wrapper --timeout 10 --codex-bin "$td\hang.cmd" run 2>&1
Check "기계판독 줄(timeout)" $true ("$out" -match "status=timeout exit_code=124")
$out = & powershell -NoProfile -File $Wrapper --timeout 120 --stall 10 --codex-bin "$td\hang.cmd" run 2>&1
Check "기계판독 줄(stall)" $true ("$out" -match "status=stall exit_code=125")

Remove-Item $td -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "통과 $pass / 실패 $fail"
if ($fail -gt 0) { exit 1 } else { exit 0 }
