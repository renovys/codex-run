#!/usr/bin/env bash
# Self-test harness for codex-run, using fake codex binaries to reproduce each scenario.
# Usage: test/run-tests.sh [path to codex-run]   (default: ./codex-run at the repository root)
# Exit codes: 0=all passed / 1=one or more failures
# The real codex is never called, so this consumes no API quota or credits.
set -u

CR="${1:-$(cd "$(dirname "$0")/.." && pwd)/codex-run}"
# Tests run from a temporary directory, so the wrapper path must be made absolute.
# Otherwise every run dies with 127 after cd, while process-cleanup checks falsely pass because nothing started.
case "$CR" in
  /*) ;;
  *)  CR="$(cd "$(dirname "$CR")" && pwd)/$(basename "$CR")" ;;
esac
[ -x "$CR" ] || { echo "codex-run not found or not executable: $CR"; exit 2; }

TD="$(mktemp -d)"
# Use a unique marker to count only processes started by this test run.
# Counting every sleep process on the system would produce false positives.
MARK="codexrun-test-$$"
cleanup_all() { pkill -KILL -f "$MARK" 2>/dev/null; rm -rf "$TD"; }
trap cleanup_all EXIT
cd "$TD" || exit 2

PASS=0; FAIL=0
check() {  # check <name> <expected> <actual>
  if [ "$2" = "$3" ]; then
    printf '  ok   %-34s (%s)\n' "$1" "$3"; PASS=$((PASS+1))
  else
    printf '  FAIL %-34s expected=%s actual=%s\n' "$1" "$2" "$3"; FAIL=$((FAIL+1))
  fi
}
# Count marked processes. pgrep does not count itself.
# macOS (BSD) pgrep has no -c, so count the matching lines directly.
alive() { pgrep -f "$1" 2>/dev/null | grep -c . | tr -d ' '; }

printf '#!/bin/bash\necho "progress 1"; sleep 1; echo "progress 2"; exit 0\n'  > ok.sh
printf '#!/bin/bash\necho "failed"; exit 7\n'                                > rc7.sh
printf '#!/bin/bash\necho "start"; sleep 300\n'                               > hang.sh
# Stub that leaves a grandchild, which must be cleaned up even after the leader dies.
cat > child.sh <<EOF
#!/bin/bash
echo "parent"
bash -c 'exec -a ${MARK}-soft sleep 120' &
sleep 300
EOF
# A TERM-ignoring grandchild exposed a regression where KILL was skipped after the leader died first.
cat > stubborn.sh <<EOF
#!/bin/bash
echo "parent"
bash -c 'trap "" TERM; exec -a ${MARK}-hard sleep 120' &
sleep 300
EOF
chmod +x ./*.sh

echo "codex-run tests: $CR"
echo "bash: $BASH_VERSION"

# --- Basic behavior ---
"$CR" --codex-bin ./ok.sh run >/dev/null 2>&1
check "normal exit" 0 $?

"$CR" --codex-bin ./rc7.sh run >/dev/null 2>&1
check "codex exit-code pass-through" 7 $?

"$CR" --timeout 10 --codex-bin ./hang.sh run >/dev/null 2>&1
check "wall-clock limit" 124 $?

"$CR" --timeout 120 --stall 10 --codex-bin ./hang.sh run >/dev/null 2>&1
check "output stall" 125 $?

# --- Process-tree cleanup ---
"$CR" --timeout 10 --codex-bin ./child.sh run >/dev/null 2>&1
sleep 3
check "grandchild cleanup" 0 "$(alive "${MARK}-soft")"

# Regression case: the leader exits on TERM before a grandchild that ignores TERM.
# If KILL is conditional on the leader still being alive, the grandchild survives here.
"$CR" --timeout 10 --codex-bin ./stubborn.sh run >/dev/null 2>&1
sleep 3
check "force TERM-ignoring grandchild" 0 "$(alive "${MARK}-hard")"

# Job-control notifications must not leak to stderr during forced termination because they pollute cron mail.
"$CR" --timeout 10 --codex-bin ./hang.sh run >/dev/null 2>joberr.txt
check "no job notification on stderr" 0 "$(wc -c < joberr.txt | tr -d ' ')"

# --- Argument contract ---
"$CR" >/dev/null 2>&1
check "reject no arguments" 2 $?
"$CR" --timeout >/dev/null 2>&1
check "reject missing --timeout value" 2 $?
"$CR" --timeout abc run >/dev/null 2>&1
check "reject nonnumeric --timeout" 2 $?
"$CR" --timeout 0 run >/dev/null 2>&1
check "reject --timeout 0" 2 $?
"$CR" --stdin /nonexistent-file run >/dev/null 2>&1
check "reject missing --stdin file" 2 $?
"$CR" --stdin "$TD" --codex-bin /bin/echo run >/dev/null 2>&1
check "reject --stdin directory" 2 $?
CODEX_RUN_TIMEOUT=abc "$CR" --codex-bin /bin/echo run >/dev/null 2>&1
check "reject nonnumeric environment" 2 $?

# --stall 0 means monitoring is off, so it must be accepted.
"$CR" --stall 0 --codex-bin ./ok.sh run >/dev/null 2>&1
check "accept --stall 0" 0 $?

# A bare exec leaves "${@:2}" empty and must not fail under set -u.
"$CR" --timeout 10 --codex-bin /bin/echo exec >/dev/null 2>&1
check "bare exec with empty arg array" 0 $?

# --- Help and version (must not call codex) ---
"$CR" --help >/dev/null 2>&1
check "--help rc=0" 0 $?
"$CR" --version 2>/dev/null | grep -q "0\.1\.0"
check "--version string" 0 $?

# --- stdin delivery ---
# Passing a filename to cat reads that file instead of stdin, so "-" is required.
echo "input-test" > in.txt
OUT="$("$CR" --timeout 10 --stdin in.txt --codex-bin /bin/cat - 2>&1)"
case "$OUT" in *input-test*) R=0 ;; *) R=1 ;; esac
check "--stdin content delivery" 0 "$R"

# --- Machine-readable line (automation must not need to parse human-facing text) ---
OUT="$("$CR" --codex-bin ./ok.sh run 2>&1)"
case "$OUT" in *"status=ok exit_code=0"*) R=0 ;; *) R=1 ;; esac
check "machine line (ok)" 0 "$R"

OUT="$("$CR" --timeout 10 --codex-bin ./hang.sh run 2>&1)"
case "$OUT" in *"status=timeout exit_code=124"*) R=0 ;; *) R=1 ;; esac
check "machine line (timeout)" 0 "$R"

OUT="$("$CR" --timeout 120 --stall 10 --codex-bin ./hang.sh run 2>&1)"
case "$OUT" in *"status=stall exit_code=125"*) R=0 ;; *) R=1 ;; esac
check "machine line (stall)" 0 "$R"

# --- Log permissions (the command line may contain a prompt, so other users must not read it) ---
"$CR" --codex-bin ./ok.sh run >/dev/null 2>&1
NEWEST="$(ls -t "$HOME/.codex-runs"/*.log 2>/dev/null | head -1)"
if [ -n "$NEWEST" ]; then
  PERM="$(ls -l "$NEWEST" | cut -c2-10)"
  check "log file mode rw-------" "rw-------" "$PERM"
fi

echo
echo "passed $PASS / failed $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
