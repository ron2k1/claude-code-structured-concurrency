---
name: structured-concurrency
description: Use when the user types `/structured-concurrency`, mentions orphan or zombie processes, MCP process leaks, node.exe accumulation, Claude Code subprocess bloat, "task manager full of node processes", subprocess leak, structured concurrency on Windows, kill-on-close, Win32 Job Objects, or wants to reap leftover children from prior Claude Code sessions. Also triggers on questions about why memory fills up after multiple CC sessions, before planning heavy multi-session work that needs subprocess hygiene, or when troubleshooting "claude code spawned too many processes".
---

# /structured-concurrency -- Claude Code Subprocess Lifetime Manager (Windows)

## Overview

Claude Code spawns dozens of child processes per session (MCP servers, plugin runtimes, LSPs, hook scripts). On graceful exit they should die. They often don't -- Windows has no `init` reaper, and stdio MCPs leak as `cmd.exe -> npx.cmd -> node.exe` chains. Across sessions this compounds into multi-gigabyte zombies that only a reboot clears.

This is the same problem Nathaniel J. Smith framed as "structured concurrency" in 2018: child task lifetimes should be bounded by their parent, enforced by the runtime, not by application discipline. Trio, Kotlin coroutines, and Swift Concurrency solved it at the language level. Linux has the OS primitive (`prctl(PR_SET_PDEATHSIG)` + cgroups). Windows has the OS primitive too -- Win32 Job Objects with `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` -- but no language runtime wires it up for Node.js child processes. This skill does.

Three layers of fix, each composable:

1. **Diagnostic** (`cc-procs.ps1`) -- read-only inventory of every CC-related process, parent chain, age, classification, orphan status
2. **Cleanup** (`cleanup-orphans.ps1`) -- terminate strict orphans (and their descendants) per `~/.reap/config.json`. Dry-run default; safe-no-op when no config exists. See `docs/CONFIGURATION.md`.
3. **Prevention** (`claude-jobbed.ps1`) -- Win32 Job Object wrapper. The kernel terminates the entire CC process tree when the wrapper exits, even on crash, BSOD, or X-button close.

## When to Use

Trigger on:
- Task Manager shows many `Node.js JavaScript Runtime` or `Windows Command Processor` entries
- Memory pressure after several CC sessions
- "Why are there 80 node.exe processes?"
- Before any heavy multi-session work where leak compounding would hurt
- After a CC crash, hard close, or terminal X-button kill

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

## Workflow

When invoked:

1. **Default (no args)**: run `tools/cc-procs.ps1` and report tree + orphan count + memory total.
2. **`kill`**: run `tools/cleanup-orphans.ps1 -Force` with strict-orphan filter and report kills.
3. **`install`**: run `tools/install-reap.ps1`, confirm it modified `$PROFILE` + `~/.bashrc`; show backup path. SessionStart hook wiring is documented but the user opts in by editing `~/.claude/settings.json` after a few dry-run sessions.
4. **`verify`**: run `tests/test-job-object.ps1`, `tests/test-orphan-detect.ps1`, and `tests/test-config-loader.ps1`. All must pass before claiming the wrapper works.
5. **`wrap`**: invoke `tools/claude-jobbed.ps1` with the user's args, do not return until child claude exits.

If user asks "what's running" without typing the slash command, still invoke `cc-procs.ps1` -- that's the read-only diagnostic, zero risk.

## File Map

```
~/.claude/skills/structured-concurrency/
+-- SKILL.md                    (this file)
+-- README.md                   (public-facing pitch, repo-ready)
+-- DESIGN.md                   (architecture spec)
+-- LICENSE                     (MIT)
+-- tools/
|   +-- cc-procs.ps1            (diagnostic, read-only)
|   +-- cleanup-orphans.ps1     (reaper, config-driven via ~/.reap/config.json)
|   +-- claude-jobbed.ps1       (Job Object wrapper)
|   +-- install-reap.ps1        (one-time setup + seeds ~/.reap/config.json)
|   +-- lib/
|       +-- JobObject.ps1       (Win32 P/Invoke for kill-on-close)
|       +-- ProcessTree.ps1     (parent-chain analysis + classifier)
|       +-- ConfigLoader.ps1    (JSON config schema + Test-ReapPredicate)
+-- hooks/
|   +-- reap-on-start.ps1       (SessionStart hook handler)
+-- tests/
|   +-- test-job-object.ps1     (spawn -> kill wrapper -> verify reaped)
|   +-- test-orphan-detect.ps1  (9 unit tests on snapshot + classifier)
|   +-- test-config-loader.ps1  (9 unit tests on config schema + predicate)
+-- config-examples/
|   +-- conservative.json       (spare almost everything)
|   +-- moderate.json           (shipped default)
|   +-- aggressive.json         (also kills node.exe / cmd.exe by name)
|   +-- paranoid.json           (observe-only, never kills)
+-- docs/
    +-- CONFIGURATION.md        (schema reference + escape-hatch + patterns)

User-side state (NOT in repo, created by install-reap.ps1):
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
