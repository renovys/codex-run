# codex-run

A watchdog wrapper for the [OpenAI Codex CLI](https://github.com/openai/codex) that keeps `codex exec` from hanging forever in unattended automation.

`codex exec` is great in a terminal, where a human notices when it stops responding. In cron jobs, CI steps, and headless agent pipelines there is nobody watching — a stuck run just sits there holding a process slot until someone finds it hours later. `codex-run` puts a time limit on the run, kills the whole process tree when it trips, and reports *why* it stopped through a standard exit code so the calling script can decide what to do next.

```bash
codex-run --timeout 900 exec --sandbox workspace-write "refactor the parser"
echo $?   # 0 = finished, 124 = hit the time limit, 125 = went silent
```

## What it actually does

**Closes stdin by default.** This is the single most common cause of a hung `codex exec`. If stdin stays open, Codex can sit waiting for input that will never arrive. `codex-run` redirects stdin from an empty file unless you explicitly pass `--stdin <file>`.

**Enforces a wall-clock limit** (`--timeout`, default 900s). When the limit trips, the process is terminated — and so are its children and grandchildren. Codex spawns subprocesses; killing only the parent leaves orphans behind. The bash version uses process-group signalling (`kill -TERM -PGID`) plus a `pkill -P` sweep; the PowerShell version uses `taskkill /T /F`.

**Optionally watches for silence** (`--stall`, default off). If the log file stops growing for N seconds, the run is treated as stuck. This is off by default on purpose — see [Why `--stall` defaults to off](#why---stall-defaults-to-off).

**Reports the reason as an exit code**, so automation can branch on it without parsing text:

| Code | Meaning |
| ---- | ------- |
| `0` | Codex finished normally |
| `2` | Bad usage — unknown value, missing argument, unreadable `--stdin` file |
| `124` | Wall-clock limit exceeded, process tree killed |
| `125` | No output for `--stall` seconds, process tree killed |
| *other* | Passed through from Codex itself |

It also prints a language-neutral status line that automation can parse without reading the human-facing summary:

```
codex-run: status=timeout exit_code=124 elapsed_sec=15 log=/home/you/.codex-runs/20260724-233844-2986093.log
```

**Writes a standard log** to `~/.codex-runs/<timestamp>-<pid>.log` and prints the path in its summary, so a failed run leaves a breadcrumb you can pick up later. The directory is created `0700` and logs `0600`, because the command line — which may carry your prompt — is recorded in the header. Logs older than 30 days are pruned automatically.

**Adds `--skip-git-repo-check` to `exec` calls.** Codex refuses to run outside a git repository, which is a surprising failure mode for a cron job working in a scratch directory. The flag is injected only for the `exec` subcommand, and only when you have not already passed it.

## Why not just use `timeout`?

For the simple case, `timeout` really is enough, and you should use it:

```bash
timeout -k 10 900 codex exec "..." < /dev/null
```

That covers the wall-clock limit and closing stdin. `codex-run` exists for the parts it does not cover:

- **`timeout` signals one process, not the tree.** Codex spawns subprocesses, and this is a [known, still-open problem in Codex itself](https://github.com/openai/codex/issues/4337) — when a run is killed, orphaned children keep the stdout/stderr pipes open, which is exactly what makes an "already terminated" job keep hanging. `codex-run` signals the whole process group and escalates to `SIGKILL` for children that ignore `SIGTERM`.
- **`timeout` cannot see a stalled-but-alive process.** A Codex run that stops making progress while still holding its process is not distinguishable from a slow one by wall clock alone. `--stall` watches output instead — off by default, for reasons explained below.
- **`timeout` returns `124` for everything.** There is no way for the caller to tell "hit the limit" from "went silent", which matters when you want to retry one and escalate the other.
- **No breadcrumbs.** When a cron job fails at 4am, `timeout` leaves nothing behind. `codex-run` writes a log with the exact command and prints its path.

If none of that matters to you, `timeout` is the smaller dependency and the right answer.

## Install

There is nothing to build. Drop the script somewhere on your `PATH` and make it executable.

**Linux / macOS**

```bash
curl -fsSL https://raw.githubusercontent.com/renovys/codex-run/main/codex-run -o ~/.local/bin/codex-run
chmod +x ~/.local/bin/codex-run
```

**Windows (PowerShell 5.1)**

```powershell
Invoke-WebRequest -Uri https://raw.githubusercontent.com/renovys/codex-run/main/codex-run.ps1 `
  -OutFile "$HOME\.claude\codex-run.ps1"
```

Requires `codex` on your `PATH` (or point at it with `--codex-bin`). The bash version targets bash 3.2, so it runs on stock macOS without installing a newer bash.

## Usage

```
codex-run [--timeout SEC] [--stall SEC] [--stdin FILE] [--tail N] [--codex-bin PATH]
          [--help] [--version] [--] <codex args...>
```

| Flag | Default | Description |
| ---- | ------- | ----------- |
| `--timeout SEC` | `900` | Wall-clock limit, minimum `1`. On exceed: kill tree, exit `124`. |
| `--stall SEC` | `0` (off) | Kill if the log has not grown for SEC seconds; exit `125`. |
| `--stdin FILE` | *(empty)* | Feed FILE to Codex on stdin instead of closing it. Must be a regular file. |
| `--tail N` | `40` | Lines of Codex output to echo in the summary. |
| `--codex-bin PATH` | `codex` | Path to the Codex binary. |
| `--help` | | Print this usage and exit `0` without calling Codex. |
| `--version` | | Print the wrapper version and exit `0`. |
| `--` | | Stop parsing wrapper flags; everything after goes to Codex. |

Defaults can also come from the environment — `CODEX_RUN_TIMEOUT`, `CODEX_RUN_STALL`, `CODEX_RUN_TAIL`, `CODEX_BIN` — on both platforms. Values are validated the same way as command-line flags, so a typo in a cron environment fails loudly with exit `2` instead of silently disabling the limit.

On Windows the flags are identical, so the same call shape works on all three platforms:

```powershell
powershell -NoProfile -File $HOME\.claude\codex-run.ps1 --timeout 900 exec --sandbox workspace-write "your prompt"
```

### Passing a long prompt

Prompts with quotes, newlines, or shell metacharacters are much safer in a file than on the command line:

```bash
codex-run --timeout 1200 --stall 0 --stdin ./prompt.md \
  exec --model gpt-5.6-sol --output-last-message ./answer.md
```

Note the pairing with `--output-last-message`: Codex's stdout is a long reasoning-and-tooling transcript, while the final answer goes to that file. Reading the transcript to decide whether the run "worked" is a trap — check the exit code and the answer file instead.

### Reacting to the outcome

```bash
codex-run --timeout 600 exec "$PROMPT"
case $? in
  0)   echo "done" ;;
  124) echo "timed out — resuming manually" ;;
  125) echo "went silent — resuming manually" ;;
  *)   echo "codex failed with $?" ;;
esac
```

## Why `--stall` defaults to off

Stall detection watches the log file's modification time. That is a good proxy for "is it still working" only when the run produces steady output. Codex spends most of its wall-clock time in model inference, and a long reasoning step can legitimately produce no output for several minutes — in measured runs, over 90% of elapsed time was inference wait, with individual quiet stretches running into the minutes on large contexts.

So the rule of thumb is:

- **Leave `--stall` off** for calls where the answer arrives at the end (`--output-last-message`), or where you expect long reasoning. Rely on `--timeout` alone.
- **Turn `--stall` on** only for interactive-style coding runs that stream progress continuously, where silence really does mean something is wrong.

Turning it on for a quiet-by-design call will kill healthy runs.

## Logs

Every run appends to `~/.codex-runs/<timestamp>-<pid>.log`, starting with a header that records the limits and the exact command line. The summary block printed at the end tells you what happened, how long it took, and where the full log is:

```
----- codex-run 요약 -----
상태: 전체 상한 900초 초과로 강제 종료 — 본체가 이어받을 것
판정 시각: 900초 / 총 경과: 905초 / 로그 전문: /home/you/.codex-runs/20260724-213035-2542577.log
codex-run: status=timeout exit_code=124 elapsed_sec=905 log=/home/you/.codex-runs/20260724-213035-2542577.log
```

The human-facing summary is Korean (`상태` status, `판정 시각` when the limit tripped, `총 경과` total elapsed including the kill grace period, `로그 전문` full log path) — see [A note on the source](#a-note-on-the-source). The `codex-run: status=…` line below it is the one to parse.

If a process somehow survives the kill, the summary says so explicitly rather than reporting a clean stop.

## Platform support

| Platform | Shell | Status |
| -------- | ----- | ------ |
| Linux | bash 5.x | Verified — 23/23 |
| macOS | bash 3.2 (stock) | Verified — 23/23 |
| Windows | PowerShell 5.1 | Verified — 18/18 |

The suites run against stub binaries, so they never call the real Codex and cost nothing:

```bash
./test/run-tests.sh              # Linux / macOS
```
```powershell
.\test\run-tests.ps1             # Windows
```

They cover normal exit, exit-code pass-through, timeout, stall, cleanup of grandchildren (including one that ignores `SIGTERM`), every argument-validation rule, `--help`/`--version`, stdin delivery, the machine-readable status line, and log permissions. CI runs the bash suite on Ubuntu and macOS and the PowerShell suite on Windows.

## A note on the source

The inline comments and the runtime messages are in Korean. These files are used daily on the author's own machines, and keeping the published copy byte-identical to the one in use is deliberate: a translated fork would drift from the version that actually gets exercised. The behaviour, flags, and exit codes are documented here in English, and you do not need to read the comments to use or audit the script.

## License

MIT — see [LICENSE](LICENSE).
