# claude-code-structured-concurrency — Design Specification

> Version: 1.2.0
> Status: shipped — Windows STRONG (v1.0.0), Linux STRONG+MEDIUM (v1.1.0), macOS MEDIUM + cmd.exe shim (v1.2.0). 36+1 pwsh + 40 bats tests passing; 9ms reap latency verified on Windows 11 build 26200.
> Author: Ronil Basu ([@ron2k1](https://github.com/ron2k1))
> Created: 2026-05-07
> Revised: 2026-05-16 — v1.2.0 macOS MEDIUM tier + cmd.exe shim

## Naming note

The skill is named after the OS-level concept (**structured concurrency**) -- that's what senior engineers will recognize from Trio, Kotlin coroutines, and Swift Concurrency. Inside the codebase, **"reap"** stays as the operational verb (function names, `~/.reap/` config dir, `reap.log`). The name signals *what it is*; the verb describes *what it does*.

## Problem statement

Claude Code (CC) spawns N stdio MCP child processes per session, where N grows with active plugins. Each stdio MCP is a 2-3 process chain — on Windows `cmd.exe → npx.cmd → node.exe` (or `cmd.exe → uvx → python.exe`); on Linux/macOS the analogous `sh → npx → node` / `sh → uvx → python`. When CC exits ungracefully — terminal X-button close, parent crash, OS task-end — those chains are not signaled. They stay alive until the OS reboots.

Cumulative effect, observed 2026-05-07:
- 14 user-global MCPs + ~30 plugin MCPs ≈ 40-60 node.exe per active session
- Multiple concurrent sessions multiply this
- After several days of use, tens of GB of resident memory held by orphans
- User's screenshots showed 80+ Node.js Runtime entries from accumulated dead-parent children (resolved by reboot, but reboot is the wrong cleanup primitive)

## Non-goals

- Killing all `node.exe` by name alone — would terminate active CC itself. The decision flow always checks `spare_classifications` first, so `claude.exe` (classified as `claude`) cannot be killed even if `node.exe` is in `kill_names`. This invariant is exercised explicitly in `tests/test-config-loader.ps1`.
- Replacing CC's own subprocess discipline. Anthropic's harness can and should ship Job Objects natively; this skill is the user-side workaround until then.
- A STRONG (kernel-enforced, SIGKILL-proof) guarantee on macOS. macOS has no Job Object, no `cgroup.kill`, and no `prctl(PR_SET_PDEATHSIG)` — there is no kernel primitive that atomically reaps a process subtree on ancestor death. macOS is MEDIUM by construction (process group + `trap` + a disowned out-of-process watchdog); the honest ceiling — a simultaneous `kill -9` of both wrapper and watchdog — is stated in the guarantee matrix below and pinned by `tests/macos/test-honesty.bats`. Closing that gap would need a Swift `kqueue`/`launchd` helper and is conditional on telemetry.

> Note: an earlier draft listed "Running on macOS or Linux" as a non-goal, asserting those platforms "already have OS-level reapers ... equivalent semantics on macOS." That was wrong on both counts: Linux shipped STRONG+MEDIUM in v1.1.0 and macOS shipped MEDIUM in v1.2.0, and macOS specifically has *no* such reaper — that absence is the entire reason it tops out at MEDIUM. The only genuine remaining non-goal is the macOS STRONG gap above.

## Cross-platform guarantee matrix

The design goal is identical on every platform — *the OS, not application code, enforces parent-death cleanup* — but the available kernel primitive differs, so the strength of the guarantee differs. That difference is stated honestly rather than papered over; the install banner and the test suite both encode it.

| Platform | Mechanism | Survives SIGKILL of wrapper? | Tier |
|---|---|---|---|
| Windows 10+ | Win32 Job Object + `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` | Yes — kernel reaps on job-handle close, including Task Manager End-Task | **STRONG** (v1.0.0) |
| Linux ≥5.14 | `systemd-run --user --scope` + `cgroup.kill` | Yes — cgroup-level kill, kernel-enforced; an out-of-process watchdog supervises the scope so even SIGKILL of the wrapper still triggers `cgroup.kill` | **STRONG** (v1.1.0) |
| Linux <5.14 / no systemd / WSL1 | `set -m` + `trap` on EXIT/INT/TERM/HUP + `killpg` | No — a bash trap cannot fire on `kill -9` | **MEDIUM** (v1.1.0) |
| macOS | `set -m` + `trap` + disowned out-of-process watchdog | Partial — survives Force-Quit/SIGKILL of the wrapper *alone* (the watchdog outlives it and reaps the tree); does **not** survive a simultaneous SIGKILL of wrapper *and* watchdog | **MEDIUM** (v1.2.0) |

### Why macOS is MEDIUM, not STRONG

Windows has the Job Object; Linux ≥5.14 has `cgroup.kill`. macOS has neither, and `prctl(PR_SET_PDEATHSIG)` is Linux-only. There is no macOS syscall that says "kill this whole subtree when the ancestor dies." The MEDIUM design extracts the maximum the OS allows:

1. `set -m` puts the spawned `claude` in its own process group, so it can be `killpg`'d without signaling the wrapper.
2. `trap 'cleanup' EXIT INT TERM HUP` handles every *catchable* exit of the wrapper.
3. A disowned watchdog subshell — in its *own* process group, so step 2's `killpg` cannot take it down — records the wrapper's PID and start time (`ps -p $pid -o lstart=`; macOS has no `/proc`) and polls. When the wrapper vanishes for *any* reason, including the un-catchable `kill -9` that defeats step 2, the watchdog runs the same `cleanup()` and reaps the tree. On graceful exit the wrapper `kill -KILL`s the watchdog (the watchdog traps catchable signals by design, so SIGTERM would not stop it).

The watchdog is what lifts macOS from WEAK (`setpgid`+`trap` only, which dies with the wrapper on `kill -9`) to MEDIUM. The residual gap — a *simultaneous* `kill -9` of wrapper and watchdog — is unrecoverable because nothing is left alive and macOS has no kernel fallback. That exact scenario is asserted, and proven still-failing-by-design, in `tests/macos/test-honesty.bats`, so the ceiling is documented as an executable test, not just prose.

This reuses the Linux v1.1.0 watchdog architecture: the out-of-process supervisor pattern was first built so the Linux STRONG path could survive a wrapper SIGKILL (the watchdog re-triggers `cgroup.kill`). macOS borrows the same supervisor idea but, lacking `cgroup.kill`, tops out at MEDIUM instead of STRONG.

## Architecture

Three independent components, composable:

```
+--------------------------------------------------------------+
| Layer 3: Prevention      claude-jobbed.ps1                   |
|   wraps claude.exe in a Win32 Job Object (KILL_ON_JOB_CLOSE) |
|   when wrapper dies, kernel reaps the entire tree            |
+--------------------------------------------------------------+
| Layer 2: Reactive cleanup    cleanup-orphans.ps1             |
|   enumerates strict orphans (parent PID dead)                |
|   config-driven predicate (~/.reap/config.json) for safety   |
|   dry-run default, -Force to actually kill                   |
+--------------------------------------------------------------+
| Layer 1: Visibility    cc-procs.ps1                          |
|   read-only inventory: tree + flat table                     |
|   per-process: PID, parent, age, mem, classification         |
|   no kill capability                                         |
+--------------------------------------------------------------+
                          |
                          v
                +------------------------+
                | Shared libraries       |
                |  lib/JobObject.ps1     | <- P/Invoke, used by Layer 3 + tests
                |  lib/ProcessTree.ps1   | <- analysis, used by Layers 1-2
                |  lib/ConfigLoader.ps1  | <- JSON schema + Test-ReapPredicate
                +------------------------+
```

Plus a SessionStart hook (`hooks/reap-on-start.ps1`) that runs Layer 2 with strict-orphan-only filter on every CC start, so leftovers from prior sessions are reaped automatically.

## Why Job Objects (Layer 3)

The Win32 Job Object is the kernel's native primitive for **structured concurrency at the process level**. A job is a kernel-managed group of processes with shared limits and lifecycle semantics.

The flag `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` says: "when the last handle to this job is closed, the kernel terminates every process that's a member of the job."

When `claude-jobbed.ps1` exits — for any reason, including SIGKILL, BSOD, power loss after recovery, or Task Manager End-Task — the OS itself closes its handles, including the job handle. The kernel then walks the job and calls `TerminateProcess` on each member. There is no application code path that can leak.

This is what Chrome, Edge, VS Code, and every modern browser sandbox uses. It is not exotic. Anthropic just hasn't wired it in yet.

## Why a config-driven predicate (Layer 2)

The predicate is the security-critical decision: which processes is this engine allowed to terminate? Too lax -> kills active sessions. Too strict -> no cleanup happens.

The engine ships **dangerous-by-omission**: with no `~/.reap/config.json`, `cleanup-orphans.ps1 -Force` is a guaranteed no-op. Aggression is opt-in via a declarative JSON config that the user owns.

Three load layers, in precedence order:

1. `~/.reap/predicate.ps1` -- procedural override. Power-user escape hatch when "only kill MCPs that haven't shown a heartbeat in 5 minutes AND total memory across siblings exceeds 200 MB AND not on weekends" type rules require real PowerShell, not declarative JSON.
2. `~/.reap/config.json` -- declarative rules. The normal user path. Schema lives in `lib/ConfigLoader.ps1`; profiles in `config-examples/`.
3. Built-in safe default -- if neither user file exists, the engine kills nothing.

The decision flow is: **spare layers always run before kill layers**. `spare_classifications` -> `spare_cmdline_patterns` -> `kill_names` -> `kill_classifications`. This ordering is the safety invariant: `claude.exe` is classified as `claude` and `claude` is in the default `spare_classifications`, so it cannot be killed even if the user adds `node.exe` to `kill_names`. Tested explicitly in `tests/test-config-loader.ps1`.

Why config over a Claude-written predicate:
1. **Portability.** A JSON config copy-pastes between machines, lives in dotfiles, and survives an upstream `git pull` of this repo without merge conflicts.
2. **Auditability.** The config is the entire policy surface. No "spooky action at a distance" from a procedural predicate the user has to reason about.
3. **Safety.** A typo in declarative JSON usually fails closed (unknown field ignored, malformed JSON falls back to safe-no-op default). A typo in procedural PowerShell can silently kill the wrong thing.
4. **Power users still have the escape hatch.** `predicate.ps1` shadows the JSON path when present.

## Component contracts

### `tools/cc-procs.ps1` (Layer 1)

- Read-only. Must never call `Stop-Process`, `taskkill`, `TerminateProcess`.
- Output: `-AsObject` returns `[PSCustomObject[]]`; default returns formatted table + tree.
- Classification labels: `claude`, `mcp-stdio`, `mcp-http`, `lsp`, `plugin-runtime`, `cmd-shim`, `unknown`.
- Exit code: 0 always (read-only never fails).

### `tools/cleanup-orphans.ps1` (Layer 2)

- Default: `-DryRun` (lists what *would* be killed, kills nothing). `-Force` to actually kill.
- Calls `IsKillable($proc)` predicate per candidate. False → skip. True + `-Force` → terminate.
- Logs every decision (kept/killed/skipped + reason) to stdout and to `~/.claude/hooks/reap.log`.
- Exit code: count of killed processes (0 in dry-run).

### `tools/claude-jobbed.ps1` (Layer 3)

- Args forwarded transparently to `claude.exe`.
- stdin/stdout/stderr forwarded.
- Exit code: forwarded from claude.exe.
- Sets job to KILL_ON_JOB_CLOSE before spawning claude (so the protection applies from t=0).
- Best-effort: assigns claude.exe to job after CreateProcess; existing children of claude.exe inherit job membership automatically.

### `hooks/reap-on-start.ps1`

- Called from SessionStart hook entry in `~/.claude/settings.json`.
- Runs `cleanup-orphans.ps1 -Force` with strict-orphan filter.
- Timeout: 10 seconds (per existing hook conventions).
- Logs to `~/.claude/hooks/reap.log` with timestamp.
- Never throws — failures are logged and swallowed (don't block CC startup).

## Verification

Tests in `tests/`:

1. `test-job-object.ps1` -- functional proof that `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` works on this Windows build. Spawns a sleeping `node`-like child, closes the job handle, asserts the child died within 2 seconds. **Verified 9ms reap latency on Windows 11 build 26200.**
2. `test-orphan-detect.ps1` -- 9 unit tests on synthetic process snapshots: orphan detection (with PID-reuse guard via `StartTime` comparison), classification, descendant tree walk.
3. `test-config-loader.ps1` -- 9 unit tests on the config schema: defaults, malformed-JSON fallback, partial-config merge, and the spare-wins-over-kill safety invariant.
4. `test-spawn-plan.ps1` -- 14 assertions on wrapper host-routing for `.cmd`/`.bat`/`.ps1` Claude shims (npm-installed Claude ships a shim, not an `.exe`) and extension-priority resolution.
5. `tests/linux/*.bats` (18) + `tests/macos/*.bats` (22) -- find-claude probe priority, pgid/watchdog cleanup, installer idempotency, and the two load-bearing *negative* tests: `tests/linux/test-cgroup-kill.bats` (Linux STRONG must survive wrapper SIGKILL via `cgroup.kill`) and `tests/macos/test-honesty.bats` (the macOS MEDIUM ceiling — simultaneous wrapper+watchdog SIGKILL leaks by design, and is asserted to still leak so it cannot silently regress).

All suites must pass before any release tag. **36+1 PowerShell + 40 bats (18 Linux + 22 macOS) passing as of v1.2.0.** CI runs the full matrix — `ubuntu-latest`, `macos-13`, `macos-14`, `windows-latest` — on every push; see `.github/workflows/test.yml`. (CI on Windows runners was the v1.1 follow-up promised in the original spec; it shipped in v1.1.0 alongside the Linux port and was extended to macOS in v1.2.0.)

## Open questions (deferred)

- ~~WSL interaction: if user runs `claude` from WSL, does the wrapper need a Linux equivalent?~~ Resolved in v1.1.0. WSL2 (real Linux kernel ≥5.14) takes the Linux STRONG `cgroup.kill` path; WSL1 (no real cgroup v2 / systemd) falls to the MEDIUM `set -m`+`trap` path. `CLAUDE_JOBBED_FORCE_FALLBACK=1` exercises that fallback in CI on a systemd-equipped runner.
- Multi-session telemetry: should we track per-session spawn counts and report at end? (v1.1 feature.)
- Plugin authors writing their own predicates: pluggable filter chain at the Layer-2 level? (v1.2 if asked.)
- Windows Server / older Windows 10 builds: Job Object behavior was unreliable pre-build 17134 (January 2018). Currently documented as a hard floor; could be loosened with a runtime probe.

## Versioning

- v1.0.0 -- Windows. Three tools, three test suites, config-driven predicate, four starter profiles, SessionStart hook, install script.
- v1.0.2 / v1.0.3 -- installer `-ShadowClaude` (plain `claude` routes through the wrapper as a function, not a `Set-Alias`); wrapper host-routes npm-installed `.cmd`/`.ps1` Claude shims through `cmd.exe /c` / `powershell.exe -File`.
- v1.1.0 -- Linux. `tools/linux/` find-claude (9-probe) + two-tier wrapper: STRONG via `systemd-run --user --scope` + `cgroup.kill` (kernel ≥5.14) with an out-of-process watchdog supervising the scope, MEDIUM `set -m`+`trap` fallback for older kernels / no-systemd / WSL1. GitHub Actions matrix added (`ubuntu-latest` + `windows-latest`). bats suite.
- v1.2.0 -- macOS + cmd.exe (this release). `tools/macos/` find-claude (bash-3.2-safe; fnm probe also checks `~/Library/Application Support/fnm`) + MEDIUM wrapper (`set -m` + `trap` + disowned out-of-process watchdog; honest simultaneous-SIGKILL ceiling pinned by `tests/macos/test-honesty.bats`). `tools/claude-jobbed.cmd` shim so cmd.exe inherits the Windows STRONG Job Object. CI extended with `macos-13` (Intel) + `macos-14` (Apple Silicon) legs plus a `/bin/bash -n` static-parse step against Apple's stock 3.2.57.
- Deferred -- pluggable Layer-2 filter chain; multi-session spawn telemetry; configurable log retention; a Swift `kqueue`/`launchd` helper to lift macOS toward STRONG (conditional on telemetry showing real demand).

## Related work

- [Notes on structured concurrency, or: Go statement considered harmful](https://vorpus.org/blog/notes-on-structured-concurrency-or-go-statement-considered-harmful/) -- Nathaniel J. Smith, 2018. The piece that named the problem class.
- [Win32 Job Objects](https://learn.microsoft.com/en-us/windows/win32/procthread/job-objects) -- Microsoft documentation for the kernel primitive.
- [`AssignProcessToJobObject`](https://learn.microsoft.com/en-us/windows/win32/api/jobapi2/nf-jobapi2-assignprocesstojobobject) -- the call `claude-jobbed.ps1` uses to attach `claude.exe` to the job.
- Trio (Python), Kotlin coroutines, Swift Concurrency -- language-level solutions to the same problem class. None of them help here because the leaked processes are spawned by Node.js, which has no structured-concurrency runtime, on a platform whose OS-level primitive nobody wired up.
