# claude-code-structured-concurrency — Design Specification

> Version: 1.0.0
> Status: shipped — 18+1 tests passing, 9ms reap latency verified on Windows 11 build 26200
> Author: Ronil Basu ([@ron2k1](https://github.com/ron2k1))
> Created: 2026-05-07

## Naming note

The skill is named after the OS-level concept (**structured concurrency**) -- that's what senior engineers will recognize from Trio, Kotlin coroutines, and Swift Concurrency. Inside the codebase, **"reap"** stays as the operational verb (function names, `~/.reap/` config dir, `reap.log`). The name signals *what it is*; the verb describes *what it does*.

## Problem statement

Claude Code (CC) on Windows spawns N stdio MCP child processes per session, where N grows with active plugins. Each stdio MCP is a 2-3 process chain: `cmd.exe → npx.cmd → node.exe` (or `cmd.exe → uvx → python.exe`). When CC exits ungracefully — terminal X-button close, parent crash, OS task-end — those chains are not signaled. They stay alive until the OS reboots.

Cumulative effect, observed 2026-05-07:
- 14 user-global MCPs + ~30 plugin MCPs ≈ 40-60 node.exe per active session
- Multiple concurrent sessions multiply this
- After several days of use, tens of GB of resident memory held by orphans
- User's screenshots showed 80+ Node.js Runtime entries from accumulated dead-parent children (resolved by reboot, but reboot is the wrong cleanup primitive)

## Non-goals

- Killing all `node.exe` by name alone — would terminate active CC itself. The decision flow always checks `spare_classifications` first, so `claude.exe` (classified as `claude`) cannot be killed even if `node.exe` is in `kill_names`. This invariant is exercised explicitly in `tests/test-config-loader.ps1`.
- Replacing CC's own subprocess discipline. Anthropic's harness can and should ship Job Objects natively; this skill is the user-side workaround until then.
- Running on macOS or Linux. Those platforms already have OS-level reapers (`prctl(PR_SET_PDEATHSIG)` + cgroups on Linux, equivalent semantics on macOS).

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

All three suites must pass before any release tag. **18+1 tests passing as of v1.0.0.** CI on Windows runners is a v1.1 follow-up.

## Open questions (deferred)

- WSL interaction: if user runs `claude` from WSL, does the wrapper need a Linux equivalent? (Likely no -- WSL already reaps via cgroups, but verify.)
- Multi-session telemetry: should we track per-session spawn counts and report at end? (v1.1 feature.)
- Plugin authors writing their own predicates: pluggable filter chain at the Layer-2 level? (v1.2 if asked.)
- Windows Server / older Windows 10 builds: Job Object behavior was unreliable pre-build 17134 (January 2018). Currently documented as a hard floor; could be loosened with a runtime probe.

## Versioning

- v1.0.0 -- this release. Three tools, three test suites, config-driven predicate, four starter profiles, SessionStart hook, install script.
- v1.1.0 -- CI on Windows runners; multi-session telemetry; configurable log retention.
- v1.2.0 -- pluggable filter chain; companion macOS/Linux verifier (so cross-platform users can lint-check their config).

## Related work

- [Notes on structured concurrency, or: Go statement considered harmful](https://vorpus.org/blog/notes-on-structured-concurrency-or-go-statement-considered-harmful/) -- Nathaniel J. Smith, 2018. The piece that named the problem class.
- [Win32 Job Objects](https://learn.microsoft.com/en-us/windows/win32/procthread/job-objects) -- Microsoft documentation for the kernel primitive.
- [`AssignProcessToJobObject`](https://learn.microsoft.com/en-us/windows/win32/api/jobapi2/nf-jobapi2-assignprocesstojobobject) -- the call `claude-jobbed.ps1` uses to attach `claude.exe` to the job.
- Trio (Python), Kotlin coroutines, Swift Concurrency -- language-level solutions to the same problem class. None of them help here because the leaked processes are spawned by Node.js, which has no structured-concurrency runtime, on a platform whose OS-level primitive nobody wired up.
