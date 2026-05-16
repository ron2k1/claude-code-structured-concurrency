---
name: structured-concurrency
description: Use when the user types `/structured-concurrency`, mentions orphan or zombie processes, MCP process leaks, node.exe (or `node`) accumulation, Claude Code subprocess bloat, "task manager full of node processes", "activity monitor full of node", subprocess leak, structured concurrency, kill-on-close, Win32 Job Objects, `cgroup.kill`, `setpgid`/`PR_SET_PDEATHSIG`, or wants to reap leftover children from prior Claude Code sessions. Cross-platform -- this skill covers Windows (PowerShell AND cmd.exe), macOS, and Linux, so make sure to use it for subprocess-hygiene questions on ANY of those platforms, including a Mac user asking how to stop Claude Code leaking processes, "orphaned node processes on my mac", launching `claude` so its children die with it, or wrapping CC in a job / cgroup / process group. Also triggers on questions about why memory fills up after multiple CC sessions, before planning heavy multi-session work that needs subprocess hygiene, or when troubleshooting "claude code spawned too many processes".
---

# /structured-concurrency -- Claude Code Subprocess Lifetime Manager (Windows, macOS, Linux)

## Overview

Claude Code spawns dozens of child processes per session (MCP servers, plugin runtimes, LSPs, hook scripts). On graceful exit they should die. They often don't -- neither Windows nor macOS reaps a process subtree when the ancestor dies, and stdio MCPs leak as `cmd.exe -> npx.cmd -> node.exe` on Windows or `sh -> npx -> node` on macOS/Linux. Across sessions this compounds into multi-gigabyte zombies that only a reboot clears.

This is the same problem Nathaniel J. Smith framed as "structured concurrency" in 2018: child task lifetimes should be bounded by their parent, enforced by the OS, not by application discipline. Trio, Kotlin coroutines, and Swift Concurrency solved it at the language level. The OS-level primitive differs by platform, so the strength of the guarantee differs too -- and that difference is stated honestly rather than papered over:

- **Windows** -- Win32 Job Object with `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`. Kernel-enforced, survives SIGKILL / Task-Manager End-Task: **STRONG**.
- **Linux >= 5.14** -- `cgroup.kill` via `systemd-run --user --scope`, with an out-of-process watchdog supervising the scope: **STRONG**. Older kernels / no-systemd / WSL1 fall back to `setpgid` + `trap`: **MEDIUM** (a bash trap cannot fire on `kill -9`).
- **macOS** -- has NONE of those primitives (no Job Object, no `cgroup.kill`, no `prctl(PR_SET_PDEATHSIG)`), so it uses `setpgid` + `trap` + a disowned out-of-process watchdog: **MEDIUM**. It survives Force-Quit / SIGKILL of the wrapper *alone* (the watchdog outlives it and reaps the tree) but NOT a simultaneous SIGKILL of wrapper *and* watchdog. That honest ceiling is pinned by `tests/macos/test-honesty.bats` so it cannot silently regress.

No language runtime wires any of this up for Node.js child processes. This skill does, on all three platforms.

Three layers of fix, each composable:

1. **Diagnostic** (`cc-procs.ps1`, Windows) -- read-only inventory of every CC-related process, parent chain, age, classification, orphan status
2. **Cleanup** (`cleanup-orphans.ps1`, Windows) -- terminate strict orphans (and their descendants) per `~/.reap/config.json`. Dry-run default; safe-no-op when no config exists. See `docs/CONFIGURATION.md`.
3. **Prevention** -- the OS reaps the entire CC tree when the wrapper exits, even on crash, BSOD, Force-Quit, or X-button close. This is the cross-platform layer: `tools/claude-jobbed.ps1` (Windows Job Object), `tools/claude-jobbed.cmd` (cmd.exe shim that re-execs the PowerShell wrapper, inheriting the same STRONG Job Object), `tools/linux/claude-jobbed.sh` (cgroup.kill scope, or setpgid+trap fallback), `tools/macos/claude-jobbed.sh` (setpgid+trap+disowned watchdog).

## When to Use

Trigger on (any platform):
- Windows Task Manager shows many `Node.js JavaScript Runtime` / `Windows Command Processor` entries; OR macOS Activity Monitor / `ps aux | grep node` shows piled-up `node`; OR Linux `ps`/`htop` shows orphaned `node` reparented to PID 1
- Memory pressure after several CC sessions
- "Why are there 80 node.exe processes?" / "why is my Mac full of `node` processes?"
- Before any heavy multi-session work where leak compounding would hurt
- After a CC crash, hard close, Force-Quit, or terminal X-button kill

Do **not** trigger on:
- High CPU from a *single* legit MCP (that's a different problem -- kill that MCP, not orphans)
- Renderer/Electron subprocess noise from non-CC apps

## Quick Reference

| Invocation | Action |
|------------|--------|
| `/structured-concurrency` | Diagnostic only -- list, classify, flag orphans, no kills |
| `/structured-concurrency kill` | Run `cleanup-orphans.ps1` live (no dry-run) |
| `/structured-concurrency install` | One-time setup -- alias `claude` to `claude-jobbed`, wire SessionStart hook |
| `/structured-concurrency verify` | Run `tests/` -- proves Job Object kill-on-close works on this machine |
| `/structured-concurrency wrap <args>` | Launch CC under the Job Object wrapper for one session |

The table above is the Windows (PowerShell) surface. **Platform dispatch:**

- **cmd.exe** -- call `tools\claude-jobbed.cmd <args>` (or `doskey claude=C:\path\to\tools\claude-jobbed.cmd $*`). It re-execs the PowerShell wrapper and inherits the same STRONG Job Object.
- **macOS / Linux** -- run `bash install.sh` (auto-detects the platform, picks the STRONG or MEDIUM tier, shadows `claude` via `~/.bashrc` plus `~/.bash_profile` on macOS for Terminal.app's login shell), or invoke `tools/macos/claude-jobbed.sh` / `tools/linux/claude-jobbed.sh <args>` directly.
- The diagnostic and cleanup layers (`cc-procs.ps1`, `cleanup-orphans.ps1`) are Windows-only; on macOS/Linux the prevention wrapper *is* the hygiene story (cleanup happens at wrapper exit, not on a schedule), so there is no periodic-reaper equivalent to port.

## Workflow

When invoked:

1. **Default (no args)**: run `tools/cc-procs.ps1` and report tree + orphan count + memory total.
2. **`kill`**: run `tools/cleanup-orphans.ps1 -Force` with strict-orphan filter and report kills.
3. **`install`**: run `tools/install-reap.ps1`, confirm it modified `$PROFILE` + `~/.bashrc`; show backup path. SessionStart hook wiring is documented but the user opts in by editing `~/.claude/settings.json` after a few dry-run sessions.
4. **`verify`**: run the Windows suite (`tests/test-job-object.ps1`, `tests/test-orphan-detect.ps1`, `tests/test-config-loader.ps1`, `tests/test-spawn-plan.ps1`). The POSIX suites live in `tests/linux/*.bats` and `tests/macos/*.bats` and run in CI on the `ubuntu-latest` / `macos-13` / `macos-14` legs (bats is not on Windows). All must pass before claiming the wrapper works.
5. **`wrap`**: invoke `tools/claude-jobbed.ps1` with the user's args, do not return until child claude exits.

If user asks "what's running" without typing the slash command, still invoke `cc-procs.ps1` -- that's the read-only diagnostic, zero risk.

## File Map

```
Repo root (== installed skill dir ~/.claude/skills/structured-concurrency/).
Tree below mirrors `git ls-files` exactly:

+-- SKILL.md                    (this file)
+-- README.md                   (public-facing pitch, repo-ready)
+-- DESIGN.md                   (architecture spec + cross-platform guarantee matrix)
+-- SECURITY.md                 (vulnerability disclosure policy)
+-- LICENSE                     (MIT)
+-- .gitignore
+-- install.sh                  (POSIX installer: macOS + Linux; auto-detects tier, shadows claude via ~/.bashrc + ~/.bash_profile on macOS)
+-- tools/
|   +-- cc-procs.ps1            (Layer 1 diagnostic, read-only -- Windows)
|   +-- cleanup-orphans.ps1     (Layer 2 reaper, config-driven via ~/.reap/config.json -- Windows)
|   +-- claude-jobbed.ps1       (Layer 3 wrapper -- Win32 Job Object, Windows)
|   +-- claude-jobbed.cmd       (cmd.exe shim -> re-execs claude-jobbed.ps1, inherits the Job Object)
|   +-- install-reap.ps1        (Windows one-time setup + seeds ~/.reap/config.json)
|   +-- lib/
|   |   +-- JobObject.ps1       (Win32 P/Invoke for kill-on-close)
|   |   +-- ProcessTree.ps1     (parent-chain analysis + classifier)
|   |   +-- ConfigLoader.ps1    (JSON config schema + Test-ReapPredicate)
|   |   +-- SpawnPlan.ps1       (Claude-shim host-routing: .cmd/.bat/.ps1 resolution)
|   +-- linux/
|   |   +-- claude-jobbed.sh    (STRONG cgroup.kill via systemd-run scope; MEDIUM setpgid+trap fallback)
|   |   +-- find-claude.sh      (9-probe claude resolver)
|   +-- macos/
|       +-- claude-jobbed.sh    (MEDIUM setpgid+trap+disowned watchdog; bash-3.2-safe)
|       +-- find-claude.sh      (9-probe; fnm probe also checks ~/Library/Application Support/fnm)
+-- hooks/
|   +-- reap-on-start.ps1       (SessionStart hook handler -- Windows)
+-- tests/
|   +-- test-job-object.ps1     (functional: spawn -> kill wrapper -> verify reaped)
|   +-- test-orphan-detect.ps1  (unit: snapshot + classifier)
|   +-- test-config-loader.ps1  (unit: config schema + spare-wins-over-kill invariant)
|   +-- test-spawn-plan.ps1     (unit: Claude-shim host-routing, 14 assertions)
|   +-- linux/
|   |   +-- test-find-claude.bats   (probe priority)
|   |   +-- test-pgid-cleanup.bats  (setpgid + trap reap)
|   |   +-- test-cgroup-kill.bats   (NEGATIVE: STRONG must survive wrapper SIGKILL via cgroup.kill)
|   |   +-- test-installer.bats     (install.sh idempotency + Linux rc contract)
|   +-- macos/
|       +-- test-find-claude.bats   (probe priority + fnm dual-dir)
|       +-- test-pgid-cleanup.bats  (setpgid + trap + watchdog reap)
|       +-- test-honesty.bats       (NEGATIVE: pins the honest MEDIUM ceiling -- simultaneous SIGKILL leaks by design)
|       +-- test-installer.bats     (install.sh idempotency + ~/.bash_profile + honest-ceiling banner)
+-- config-examples/
|   +-- conservative.json       (spare almost everything)
|   +-- moderate.json           (shipped default)
|   +-- aggressive.json         (also kills node.exe / cmd.exe by name)
|   +-- paranoid.json           (observe-only, never kills)
+-- docs/
|   +-- CONFIGURATION.md        (schema reference + escape-hatch + patterns)
|   +-- FAQ.md                  (common questions)
|   +-- architecture.svg        (diagram)
|   +-- demo.mp4                (screen capture)
+-- .github/workflows/
    +-- test.yml                (CI matrix: ubuntu-latest, macos-13, macos-14, windows-latest)

User-side state (NOT in repo, created by install-reap.ps1 / install.sh):
~/.reap/
+-- config.json                 (user's reap config)
+-- predicate.ps1               (OPTIONAL procedural override)
```

## Why "reap" stays as the operational verb

The skill is named after the OS-level concept (structured concurrency) -- that's what senior devs will recognize when they read the description. Inside the codebase, "reap" stays as the operational verb (function names, config dir, log file). Same way Linux is named after Linus but `init`, `fork`, `exec` are the verbs. This is deliberate.

## Safety Invariants

- `cc-procs.ps1` is **always** read-only. It must never call `Stop-Process`, `taskkill`, or `TerminateProcess`.
- `cleanup-orphans.ps1` defaults to `-DryRun`. Live kills require `-Force` AND a config that opts in. With no `~/.reap/config.json`, the engine is a guaranteed no-op even with `-Force`.
- `cleanup-orphans.ps1` MUST NEVER blanket-kill `node.exe` based on name alone. The decision flow ALWAYS checks `spare_classifications` first, so `claude.exe` (classified as `claude`) cannot be killed even if `node.exe` is in `kill_names`.
- `claude-jobbed.ps1` is opt-in. Plain `claude` still works.

## Common Mistakes

| Mistake | Fix |
|---------|-----|
| Calling `taskkill /IM node.exe` to clean up | Kills active CC. Use `/structured-concurrency kill` (filters to orphans + spares classification=claude) |
| Treating "alive children of this CC session" as orphans | They're not -- strict orphan = parent process is dead, not "parent is some other CC" |
| Skipping `verify` before relying on the wrapper | Job Object behavior varies by Windows build; always run the test |
| Editing `cleanup-orphans.ps1` directly to add aggression | Don't. Edit `~/.reap/config.json` instead -- survives upstream updates without merge conflicts |
| Adding in-house tools to the shipped classifier | Don't. Use `custom_classifiers` in your config -- keeps the public engine generic |

## Real-World Impact

Pre-skill, on a Dell G15 5530 (i7-13650HX, 16GB DDR5):
- 80+ orphan `Node.js JavaScript Runtime` entries after 2 days of heavy use
- Reboot was the only reliable cleanup primitive
- Memory accumulation forced restarts mid-work

Post-skill:
- Job Object wrapper: zero orphans on exit, kernel-enforced (verified 9ms reap latency on Windows 11 build 26200)
- SessionStart hook: leftovers from un-wrapped sessions cleared on next CC start
- Diagnostic surface: `cc-procs.ps1` shows orphan count + memory total any time

macOS and Linux: validated in CI (GitHub `macos-13` / `macos-14` / `ubuntu-latest` legs), not locally micro-benched. The bats suites assert the wrapper reaps the tree and, for macOS, that the honest MEDIUM ceiling still holds (`tests/macos/test-honesty.bats`). The latency figures above are Windows-measured only -- no synthetic numbers are claimed for the POSIX tiers.
