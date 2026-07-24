#!/usr/bin/env bash
# codex-run 자체 검증 하네스 — 가짜 codex 바이너리로 각 시나리오를 재현한다.
# 사용: test/run-tests.sh [codex-run 경로]   (기본: 저장소 루트의 ./codex-run)
# 종료코드: 0=전부 통과 / 1=실패 있음
# 실제 codex를 호출하지 않으므로 API 사용량·과금이 발생하지 않는다.
set -u

CR="${1:-$(cd "$(dirname "$0")/.." && pwd)/codex-run}"
# 임시 폴더로 이동해 검증하므로 상대경로는 반드시 절대경로로 바꾼다.
# (안 그러면 cd 후 실행이 전부 127 로 죽고, 프로세스 정리 검사는 아무것도 안 떠서 거짓 통과한다)
case "$CR" in
  /*) ;;
  *)  CR="$(cd "$(dirname "$CR")" && pwd)/$(basename "$CR")" ;;
esac
[ -x "$CR" ] || { echo "codex-run을 찾을 수 없다(실행권한 확인): $CR"; exit 2; }

TD="$(mktemp -d)"
# 표식: 이 실행이 띄운 프로세스만 세기 위한 고유 문자열.
# 시스템 전체의 sleep 을 세면 다른 프로세스 때문에 오탐한다.
MARK="codexrun-test-$$"
cleanup_all() { pkill -KILL -f "$MARK" 2>/dev/null; rm -rf "$TD"; }
trap cleanup_all EXIT
cd "$TD" || exit 2

PASS=0; FAIL=0
check() {  # check <이름> <기대값> <실제값>
  if [ "$2" = "$3" ]; then
    printf '  ok   %-34s (%s)\n' "$1" "$3"; PASS=$((PASS+1))
  else
    printf '  FAIL %-34s 기대=%s 실제=%s\n' "$1" "$2" "$3"; FAIL=$((FAIL+1))
  fi
}
# 표식이 붙은 프로세스 개수. pgrep 은 자기 자신을 세지 않는다.
# macOS(BSD) pgrep 에는 -c 가 없으므로 행 수를 직접 센다.
alive() { pgrep -f "$1" 2>/dev/null | grep -c . | tr -d ' '; }

printf '#!/bin/bash\necho "진행 1"; sleep 1; echo "진행 2"; exit 0\n'  > ok.sh
printf '#!/bin/bash\necho "실패함"; exit 7\n'                          > rc7.sh
printf '#!/bin/bash\necho "시작"; sleep 300\n'                         > hang.sh
# 손자를 남기는 스텁 — 리더가 죽어도 손자가 정리돼야 한다
cat > child.sh <<EOF
#!/bin/bash
echo "부모"
bash -c 'exec -a ${MARK}-soft sleep 120' &
sleep 300
EOF
# TERM 을 무시하는 손자 — 리더가 TERM 에 먼저 죽으면 KILL 이 생략되던 회귀 지점
cat > stubborn.sh <<EOF
#!/bin/bash
echo "부모"
bash -c 'trap "" TERM; exec -a ${MARK}-hard sleep 120' &
sleep 300
EOF
chmod +x ./*.sh

echo "codex-run 검증: $CR"
echo "bash: $BASH_VERSION"

# --- 기본 동작 ---
"$CR" --codex-bin ./ok.sh run >/dev/null 2>&1
check "정상 종료" 0 $?

"$CR" --codex-bin ./rc7.sh run >/dev/null 2>&1
check "codex 종료코드 전달" 7 $?

"$CR" --timeout 10 --codex-bin ./hang.sh run >/dev/null 2>&1
check "전체 상한 초과" 124 $?

"$CR" --timeout 120 --stall 10 --codex-bin ./hang.sh run >/dev/null 2>&1
check "무출력 정체" 125 $?

# --- 프로세스 트리 정리 ---
"$CR" --timeout 10 --codex-bin ./child.sh run >/dev/null 2>&1
sleep 3
check "손자 프로세스 정리" 0 "$(alive "${MARK}-soft")"

# 회귀: 리더가 TERM 에 먼저 죽고 손자가 TERM 을 무시하는 경우.
# KILL 을 리더 생존 조건부로 보내면 여기서 손자가 살아남는다.
"$CR" --timeout 10 --codex-bin ./stubborn.sh run >/dev/null 2>&1
sleep 3
check "TERM 무시 손자 강제정리" 0 "$(alive "${MARK}-hard")"

# 강제 종료 경로에서 잡 제어 알림이 stderr 로 새면 안 된다(cron 메일 오염)
"$CR" --timeout 10 --codex-bin ./hang.sh run >/dev/null 2>joberr.txt
check "잡 알림 stderr 유출 없음" 0 "$(wc -c < joberr.txt | tr -d ' ')"

# --- 인자 계약 ---
"$CR" >/dev/null 2>&1
check "인자 없음 거부" 2 $?
"$CR" --timeout >/dev/null 2>&1
check "--timeout 값 없음 거부" 2 $?
"$CR" --timeout abc run >/dev/null 2>&1
check "숫자 아닌 --timeout 거부" 2 $?
"$CR" --timeout 0 run >/dev/null 2>&1
check "--timeout 0 거부" 2 $?
"$CR" --stdin /존재하지않는파일 run >/dev/null 2>&1
check "없는 --stdin 파일 거부" 2 $?
"$CR" --stdin "$TD" --codex-bin /bin/echo run >/dev/null 2>&1
check "--stdin 디렉터리 거부" 2 $?
CODEX_RUN_TIMEOUT=abc "$CR" --codex-bin /bin/echo run >/dev/null 2>&1
check "환경변수 비숫자 거부" 2 $?

# --stall 0 은 "감시 끔"이라 허용돼야 한다
"$CR" --stall 0 --codex-bin ./ok.sh run >/dev/null 2>&1
check "--stall 0 허용" 0 $?

# exec 단독: "${@:2}" 가 빈 배열이 되는 조합에서 set -u 로 깨지면 안 된다
"$CR" --timeout 10 --codex-bin /bin/echo exec >/dev/null 2>&1
check "exec 단독(빈 인자 배열)" 0 $?

# --- 도움말·버전 (codex 를 호출하지 않아야 한다) ---
"$CR" --help >/dev/null 2>&1
check "--help rc=0" 0 $?
"$CR" --version 2>/dev/null | grep -q "0\.1\.0"
check "--version 문자열" 0 $?

# --- stdin 전달 ---
# cat 에 파일명을 주면 stdin 대신 그 파일을 읽으므로 반드시 "-" 를 넘긴다
echo "입력테스트" > in.txt
OUT="$("$CR" --timeout 10 --stdin in.txt --codex-bin /bin/cat - 2>&1)"
case "$OUT" in *입력테스트*) R=0 ;; *) R=1 ;; esac
check "--stdin 내용 전달" 0 "$R"

# --- 기계 판독 줄 (자동화가 한국어를 파싱하지 않아도 되게) ---
OUT="$("$CR" --codex-bin ./ok.sh run 2>&1)"
case "$OUT" in *"status=ok exit_code=0"*) R=0 ;; *) R=1 ;; esac
check "기계판독 줄(정상)" 0 "$R"

OUT="$("$CR" --timeout 10 --codex-bin ./hang.sh run 2>&1)"
case "$OUT" in *"status=timeout exit_code=124"*) R=0 ;; *) R=1 ;; esac
check "기계판독 줄(timeout)" 0 "$R"

OUT="$("$CR" --timeout 120 --stall 10 --codex-bin ./hang.sh run 2>&1)"
case "$OUT" in *"status=stall exit_code=125"*) R=0 ;; *) R=1 ;; esac
check "기계판독 줄(stall)" 0 "$R"

# --- 로그 권한 (프롬프트가 명령행에 실릴 수 있어 타 사용자가 읽으면 안 된다) ---
"$CR" --codex-bin ./ok.sh run >/dev/null 2>&1
NEWEST="$(ls -t "$HOME/.codex-runs"/*.log 2>/dev/null | head -1)"
if [ -n "$NEWEST" ]; then
  PERM="$(ls -l "$NEWEST" | cut -c2-10)"
  check "로그 파일 권한 rw-------" "rw-------" "$PERM"
fi

echo
echo "통과 $PASS / 실패 $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
