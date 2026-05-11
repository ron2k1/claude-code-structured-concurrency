# claude-code-structured-concurrency

> Kernel-enforced cleanup of orphaned Claude Code subprocesses. Win32 Job Object on Windows, `cgroup.kill` (Linux 5.14+) with a process-group fallback for older kernels. macOS support tracked for v1.2.0.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Windows%2010%2B%20%7C%20Linux-blue)](#requirements)
[![Shell](https://img.shields.io/badge/shell-PowerShell%205.1%2B%20%7C%20bash-5391FE)](#requirements)
[![Tests](https://img.shields.io/badge/tests-36%2B1%20pwsh%20%7C%2018%20bats-brightgreen)](#tests)

Claude Code spawns 40-60 child processes per session (MCP servers, plugins, LSPs, hooks). They often outlive their parent. After a few days, Task Manager (Windows) or `ps -ef` (Linux) fills with `node` entries from sessions that closed hours ago, and reboot becomes the cleanup primitive. This skill wires up the same kernel mechanisms Chrome, Edge, VS Code, and `systemd-run --scope` already use to bound helper-process lifetime, so the OS reaps the tree instead.

Verified 9 ms reap latency on Windows 11 build 26200. 36 PowerShell unit assertions plus 1 functional test (Windows side) and 18 bats tests (Linux side), all passing in CI.

## Guarantee matrix

| Platform | Mechanism | SIGKILL of wrapper survives? | Status |
|---|---|---|---|
| Windows 10+ | Win32 Job Object + `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` | Yes (kernel reaps on handle close, including Task Manager End-Task) | **STRONG** — shipped v1.0.0 |
| Linux 5.14+ | `systemd-run --user --scope` + `cgroup.kill` | Yes (cgroup-level kill, kernel-enforced) | **STRONG** — shipped v1.1.0 |
| Linux <5.14 / containers / WSL1 | bash `set -m` + `trap` on EXIT/INT/TERM/HUP + `killpg` | No (trap doesn't fire on `kill -9`) | **MEDIUM** — fallback, shipped v1.1.0 |
| macOS | `setpgid` + `trap` (planned) | No (Force-Quit of wrapper escapes cleanup) | **WEAK** — v1.2.0 milestone, with explicit honesty in install banner |

Running on Linux <5.14? The installer prints which tier you're getting at install time, so there's no surprise.

<p align="center">
  <img src="docs/architecture.svg" alt="Three-layer architecture: Visibility (cc-procs.ps1) and Cleanup (cleanup-orphans.ps1) and Prevention (claude-jobbed.ps1) over shared libraries, with the Prevention layer connecting to the Win32 Job Object kernel primitive" width="100%" />
</p>

## Demo

<p align="center">
  <video src="https://github.com/ron2k1/claude-code-structured-concurrency/raw/main/docs/demo.mp4" controls width="800"></video>
</p>

58-second screen capture. The orphan MCP count drops to zero on `claude.exe` exit, with cleanup driven by the kernel's Job Object close, not by application code. If the inline player doesn't load, [download the MP4 directly](https://github.com/ron2k1/claude-code-structured-concurrency/raw/main/docs/demo.mp4).

## Requirements

**Windows side:**
- Windows 10 build 17134 (January 2018) or later. Job Object behavior was unreliable for this pattern on older builds.
- PowerShell 5.1 (default Windows install) or PowerShell 7+. Git Bash also works (via `~/.bashrc`).

**Linux side:**
- bash 4+. The fallback path uses `set -m` job control and trap-on-signal cleanup.
- Optional but recommended: kernel 5.14+ (Aug 2021, in every supported distro) and `systemd-run` available, for the STRONG `cgroup.kill` path. Without these the installer drops to the MEDIUM trap-based fallback and tells you so.

Zero external dependencies on either platform. No PowerShell modules, no Node, no Python, no `sudo`.

> [!IMPORTANT]
> **Windows: PowerShell only. cmd.exe is not supported.** The wrapper alias relies on `$PROFILE`, which is a PowerShell concept. cmd.exe has no equivalent profile mechanism, so plain `claude` typed into a cmd.exe window bypasses the wrapper and runs unprotected. Use PowerShell or Git Bash. Per-launcher details and remedies live in [`docs/FAQ.md`](docs/FAQ.md).

## Install

### Windows

```powershell
git clone https://github.com/ron2k1/claude-code-structured-concurrency `
    "$env:USERPROFILE\.claude\skills\structured-concurrency"

& "$env:USERPROFILE\.claude\skills\structured-concurrency\tools\install-reap.ps1" -ShadowClaude
```

`-ShadowClaude` redefines plain `claude` as a function that delegates to the wrapper. Without it, you have to type `claude-jobbed` every time you want protection. PowerShell resolves Functions before PATH, so the function wins over `claude.exe` at parse time.

Open a fresh PowerShell window and confirm:

```powershell
Get-Command claude
# CommandType=Function (Definition: claude-jobbed @args)  ->  wrapped
# CommandType=Application                                  ->  NOT wrapped
```

### Linux

```bash
git clone https://github.com/ron2k1/claude-code-structured-concurrency \
    "$HOME/.claude/skills/structured-concurrency"

cd "$HOME/.claude/skills/structured-concurrency"
./install.sh
```

The installer detects your kernel version, prints which guarantee tier you're getting (STRONG on 5.14+, MEDIUM below), and asks for `[y/N]` confirmation. It injects an idempotent shell function block into `~/.bashrc`, `~/.zshrc`, and `~/.config/fish/config.fish` (each only if the rc file already exists), so plain `claude` routes through the wrapper.

```bash
# CI / unattended:
./install.sh --yes

# Re-run after editing the wrapper (rewrites the rc block in place):
./install.sh --force --yes

# Cleanly remove:
./install.sh --uninstall
```

Open a fresh shell and confirm the wrapper is in front of the real binary:

```bash
type claude
# claude is a function   ->  wrapped
# claude is /usr/bin/claude  (or similar)  ->  NOT wrapped
```

> [!WARNING]
> Install does not wrap a session that's already running. Close existing CC windows and start a new shell after install.

## Components

**Windows (`tools/`):**

| Tool | Layer | What it does |
|------|-------|--------------|
| [`tools/cc-procs.ps1`](tools/cc-procs.ps1) | Visibility | Read-only inventory: PID, parent, age, memory, classification, orphan flag. No kill capability. |
| [`tools/cleanup-orphans.ps1`](tools/cleanup-orphans.ps1) | Cleanup | Terminates strict-orphan subtrees per `~/.reap/config.json`. Dry-run by default. |
| [`tools/claude-jobbed.ps1`](tools/claude-jobbed.ps1) | Prevention | Win32 Job Object wrapper. Kernel terminates the entire CC tree on wrapper exit. |

**Linux (`tools/linux/`):**

| Tool | Layer | What it does |
|------|-------|--------------|
| [`tools/linux/find-claude.sh`](tools/linux/find-claude.sh) | Discovery | 9-probe path resolver: `command -v` → npm prefix → `/opt/homebrew/bin` → `/usr/local/bin` → nvm (highest version) → fnm → asdf → volta → yarn global. Returns 127 if nothing matches. |
| [`tools/linux/claude-jobbed.sh`](tools/linux/claude-jobbed.sh) | Prevention | Two-tier wrapper. STRONG: spawns `claude` inside `systemd-run --user --scope`, so `cgroup.kill` reaps the tree even on `kill -9` of the wrapper. FALLBACK: bash `set -m` + trap-on-EXIT/INT/TERM/HUP that issues `killpg -TERM` then `-KILL`. `CLAUDE_JOBBED_FORCE_FALLBACK=1` exercises the fallback path on systemd-equipped boxes (used in CI). |

```powershell
# Windows
.\tools\cc-procs.ps1                # see what's running
.\tools\cleanup-orphans.ps1         # dry-run a reap
.\tools\cleanup-orphans.ps1 -Force  # actually reap
```

```bash
# Linux
claude --version       # already wrapped if you ran install.sh
type claude            # confirm: should print "claude is a function"
```

Inside a Claude Code session on Windows, the same flow is `/structured-concurrency [kill|install|verify]`.

A SessionStart hook (`hooks/reap-on-start.ps1`) runs the cleanup in strict-orphan-only mode on every CC start (Windows), so leftovers from un-wrapped or crashed sessions are reaped automatically. The Linux wrapper does not need a periodic reaper — `cgroup.kill` runs at wrapper exit, not on a schedule.

## Auditable

About 642 lines of PowerShell across `tools/` and `hooks/`, plus 345 lines of tests. The runtime reads top to bottom in 20 minutes.

| Surface | Access | Note |
|---------|--------|------|
| Network | None | No `Invoke-WebRequest`, `Invoke-RestMethod`, sockets, or telemetry. |
| File reads | `~/.reap/config.json`, `~/.reap/predicate.ps1`, the wrapper's own scripts | Nothing in `Documents/`, `OneDrive/`, source repos, or anywhere else under `$env:USERPROFILE`. |
| File writes | `~/.claude/hooks/reap.log` only | Append-only log of kept, killed, and skipped decisions. No other writes. |
| Registry | None | No `HKLM:\` or `HKCU:\` access. |
| Process kills | `-Force` plus a user-authored `~/.reap/config.json` that opts in | Default install kills nothing. See [Configuration](#configuration). |
| Shell profile | `install-reap.ps1 -ShadowClaude` appends one PowerShell function to `$PROFILE` | The function is human-readable. Removing the block reverts the install. |
| `claude.exe` | Spawned as a child of the Job Object, never patched or hooked | The binary on disk is untouched. |
| Background services | None | No Windows services, no scheduled tasks, no SessionStart hook unless you opt in. |

Verify the scope yourself:

```powershell
# No network calls anywhere in the runtime:
Select-String -Path .\tools\*.ps1,.\hooks\*.ps1 -Pattern 'Invoke-WebRequest|Invoke-RestMethod|System\.Net|curl|wget'

# Every file the tool can write to:
Select-String -Path .\tools\*.ps1,.\hooks\*.ps1 -Pattern 'Out-File|Set-Content|Add-Content|Tee-Object'

# Run the full test suite without installing anything:
.\tests\test-orphan-detect.ps1
.\tests\test-config-loader.ps1
.\tests\test-job-object.ps1
```

Uninstall is three commands:

```powershell
notepad $PROFILE                                                    # delete the `function claude { ... }` block
Remove-Item -Recurse "$env:USERPROFILE\.reap"                       # remove your config (optional)
Remove-Item -Recurse "$env:USERPROFILE\.claude\skills\structured-concurrency"
```

No registry cleanup, no service removal, no leftover state.

## Configuration

The cleanup engine is **dangerous-by-omission**. Without `~/.reap/config.json`, `cleanup-orphans.ps1 -Force` is a guaranteed no-op. Aggression is opt-in.

Pick a starter profile at install time:

| Profile | Behavior |
|---------|----------|
| `conservative` | Spare almost everything. |
| `moderate` | Default. Kill standard MCP chains. |
| `aggressive` | Also kill `node.exe` and `cmd.exe` orphans. |
| `paranoid` | Observe-only. Never kills. |

```powershell
.\tools\install-reap.ps1 -ConfigProfile moderate
```

The decision flow always runs spare layers before kill layers (`spare_classifications` then `spare_cmdline_patterns` then `kill_names` then `kill_classifications`). `claude.exe` is classified as `claude` and `claude` is in the default `spare_classifications`, so it cannot be killed even if the user adds `node.exe` to `kill_names`. This invariant is exercised explicitly in `tests/test-config-loader.ps1`.

Full schema, the `predicate.ps1` escape hatch for procedural rules, and worked configs ("I run in-house MCPs", "I want aggressive cleanup with a safety net") live in [`docs/CONFIGURATION.md`](docs/CONFIGURATION.md).

## How it works

The same idea — let the OS, not the application, enforce parent-death cleanup — has different kernel primitives on each platform.

### Windows

`JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` is a flag on Win32 Job Objects: when the last handle to the job is closed, the kernel terminates every member process. Browser sandboxes use this to bound renderer and tab lifetime.

`claude-jobbed.ps1` does the wiring:

1. `CreateJobObjectW` via P/Invoke.
2. `SetInformationJobObject` with `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`.
3. Spawn `claude.exe` and assign it to the job. Descendants inherit membership.
4. Wait for `claude.exe` to exit, then exit.
5. On wrapper exit (graceful, crash, BSOD, X-button close, Task Manager End-Task), the OS closes the job handle. The kernel walks the job and calls `TerminateProcess` on every member.

### Linux

The strong path uses systemd's transient scope: every scope is its own cgroup, and writing `1` to `cgroup.kill` (kernel ≥ 5.14) atomically delivers SIGKILL to every member. systemd does that for you when the scope's main process exits.

`tools/linux/claude-jobbed.sh` STRONG path:

1. `find_claude` resolves the real binary via the 9-probe order.
2. `systemd-run --user --scope --quiet --slice=claude-code.slice --unit="claude-jobbed-$$.scope" -- "$claude_path" "$@"` launches `claude` inside a fresh transient scope.
3. When the wrapper exits (any reason, including `kill -9`), systemd notices the scope's main PID is gone, writes `1` to the scope's `cgroup.kill`, and the kernel reaps every descendant cgroup-wide.

Fallback path (kernels <5.14, containers without systemd, WSL1):

1. `set -m` so the spawned child gets its own process group (pgid == pid).
2. `trap 'kill -TERM "-$child_pgid"; sleep 0.5; kill -KILL "-$child_pgid"' EXIT INT TERM HUP`.
3. On graceful wrapper exit or signal, the trap fires `killpg`. SIGKILL of the wrapper itself escapes — the trap doesn't fire for `-9`. That's the documented MEDIUM-tier gap.

There is no application code path that can leak on the strong paths. This is structured concurrency enforced by the operating system, the way Nathaniel J. Smith [originally framed](https://vorpus.org/blog/notes-on-structured-concurrency-or-go-statement-considered-harmful/) the problem class. Application discipline is what produced the leaks in the first place.

Full architecture: [`DESIGN.md`](DESIGN.md).

## Tests

36 PowerShell unit assertions plus 1 functional test (Windows side) and 18 bats tests (Linux side), all passing in the GitHub Actions matrix.

**Windows (`tests/test-*.ps1`):**

| Suite | Coverage |
|-------|----------|
| `tests/test-job-object.ps1` | Functional. Spawns a sleeping child, closes the job handle, asserts the child died within 2 seconds. **9 ms measured** on Windows 11 build 26200. |
| `tests/test-orphan-detect.ps1` | Synthetic snapshots. Orphan detection, PID-reuse guard via `StartTime` comparison, classification, descendant tree walk. |
| `tests/test-config-loader.ps1` | Config schema. Defaults, malformed-JSON fallback, partial-config merge, and the spare-wins-over-kill safety invariant. |
| `tests/test-spawn-plan.ps1` | Wrapper host-routing for `.cmd` / `.bat` / `.ps1` shims (npm-installed Claude ships a shim, not an `.exe`). Extension-priority resolution. 14 assertions. |

**Linux (`tests/linux/test-*.bats`):**

| Suite | Coverage |
|-------|----------|
| `tests/linux/test-find-claude.bats` | Probe priority: PATH > npm prefix > nvm (highest version) > fnm > yarn global. Sandboxed PATH+HOME so probes only hit fixtures. The 127-when-not-found contract and source-mode contract. 8 tests. (Probes 3-4 — Homebrew paths — honestly skip on Linux runners; they land in v1.2.0 macOS CI.) |
| `tests/linux/test-pgid-cleanup.bats` | Forces fallback path via `CLAUDE_JOBBED_FORCE_FALLBACK=1`. Spawns a fake claude that backgrounds a grandchild, kills the wrapper with SIGTERM, polls (3s budget) for grandchild death. Plus exit-code propagation and verbatim arg forwarding. 3 tests. |
| `tests/linux/test-cgroup-kill.bats` | Load-bearing parity test against Win32 `KILL_ON_JOB_CLOSE`. Lets the wrapper take the strong (`systemd-run --scope`) path, then SIGKILLs the wrapper. Bash traps don't fire on `-9`, so only kernel-enforced cleanup via `cgroup.kill` can satisfy this. Skips with a printed reason if `systemd-run` is missing, `--user` systemd is inactive, or kernel < 5.14. 1 test. |
| `tests/linux/test-installer.bats` | Sandboxes HOME; covers `--yes` inject, idempotent re-run preserving marker count, `--force` overwrite (count stays at 2 not 4), `--uninstall` clean removal, `--uninstall` no-op, and unknown-flag exit code 2. 6 tests. |

```powershell
# Windows
.\tests\test-job-object.ps1
.\tests\test-orphan-detect.ps1
.\tests\test-config-loader.ps1
.\tests\test-spawn-plan.ps1
```

```bash
# Linux (requires bats-core: apt install bats)
bats --print-output-on-failure tests/linux/
```

CI runs both halves on every push (`.github/workflows/test.yml`): `ubuntu-latest` for the bats suite (with `loginctl enable-linger` so `systemctl --user` is active and the cgroup-kill test exercises the strong path instead of skipping), and `windows-latest` for the PowerShell suite. If a suite fails on your Windows build, file an issue with the output of `winver`. If it fails on a Linux distro, include `uname -r` and `systemctl --user is-active default.target`.

## Safety guarantees

- `cc-procs.ps1` never kills. No `Stop-Process`, no `taskkill`, no `TerminateProcess`. Run it any time.
- `cleanup-orphans.ps1` defaults to dry-run. Live kills require both `-Force` and a config that opts in. With no `~/.reap/config.json`, the engine is a guaranteed no-op even with `-Force`.
- The engine never blanket-kills `node.exe` by name. `spare_classifications` always runs first.
- `claude-jobbed.ps1` is opt-in. Plain `claude.exe` still works without the wrapper, just unprotected.

## What this does not do

- Replace Claude Code's own subprocess discipline. Anthropic can ship Job Objects + cgroups natively. This is the user-side workaround until they do.
- Help on macOS yet. macOS has neither `cgroup.kill` nor a Job-Object equivalent — `prctl(PR_SET_PDEATHSIG)` is Linux-only, and `setpgid` + `atexit` cleanup does *not* survive `kill -9` of the wrapper (Activity Monitor "Force Quit"). The v1.2.0 milestone ships a process-group wrapper with explicit honesty about this gap in the install banner; the v1.3.0+ Swift `kqueue` helper is conditional on telemetry.
- Wrap a `claude` that's already running. Restart your shell after install (Windows or Linux).
- Cover launchers that bypass shell rc files: on Windows that's `cmd.exe`, `Win+R`, desktop shortcuts to `claude.exe`, Task Scheduler entries, VS Code's terminal until reloaded; on Linux that's anything launched with `env -i` or by a service manager that strips `~/.bashrc`. See [`docs/FAQ.md`](docs/FAQ.md) for per-path remedies (Windows side; Linux equivalents land with the next docs pass).

## License

MIT. See [`LICENSE`](LICENSE).

Author: Ronil Basu ([@ron2k1](https://github.com/ron2k1)).

## Reading

- [Notes on structured concurrency, or: Go statement considered harmful](https://vorpus.org/blog/notes-on-structured-concurrency-or-go-statement-considered-harmful/), Nathaniel J. Smith, 2018. The piece that named the problem class.
- [Win32 Job Objects](https://learn.microsoft.com/en-us/windows/win32/procthread/job-objects), Microsoft documentation for the kernel primitive.
- [`AssignProcessToJobObject`](https://learn.microsoft.com/en-us/windows/win32/api/jobapi2/nf-jobapi2-assignprocesstojobobject), the Win32 call `claude-jobbed.ps1` uses to attach `claude.exe` to the job.
