# claude-code-structured-concurrency

> Structured concurrency for Claude Code on Windows. Stop reboot-as-cleanup.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Windows%2010%2B-blue)](#compatibility)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%20%7C%207%2B-5391FE)](#compatibility)
[![Tests](https://img.shields.io/badge/tests-18%2B1%20passing-brightgreen)](#tests)

## The problem

Claude Code spawns child processes for every MCP server, plugin runtime, LSP, and hook script. On Windows, these often outlive their parent. Task Manager fills with `Node.js JavaScript Runtime` and `Windows Command Processor` entries from sessions that closed hours ago. Reboot fixes it. Until next time.

This is the **orphaned-subprocess** problem, and it has a name in the literature: it's exactly what Nathaniel J. Smith framed in 2018 as the absence of [structured concurrency](https://vorpus.org/blog/notes-on-structured-concurrency-or-go-statement-considered-harmful/). Child task lifetimes should be bounded by their parent's, enforced by the runtime, not by application discipline. Trio, Kotlin coroutines, and Swift Concurrency formalized it at the language level. Linux has the OS primitive (`prctl(PR_SET_PDEATHSIG)` + cgroups). Windows has the OS primitive too -- Win32 Job Objects with `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` -- but no language runtime wires it up for Node.js child processes spawned by Claude Code.

After a few days of heavy use without it:
- 14 MCPs x 2-3 process chain each = ~40 `node.exe` per active session
- Multiple concurrent CC sessions multiply this
- Tens of GB of resident memory held by zombies
- Reboot becomes the only reliable cleanup

## The fix

Three independent layers, each composable. Use any subset:

| Layer | Tool | What it does |
|-------|------|--------------|
| Visibility | `tools/cc-procs.ps1` | Read-only inventory of every CC-related process. Parent chain, age, memory, classification, orphan flag. Never kills. |
| Cleanup | `tools/cleanup-orphans.ps1` | Terminates strict-orphan subprocess trees per `~/.reap/config.json`. Dry-run by default. Chain-kills descendants. |
| Prevention | `tools/claude-jobbed.ps1` | Win32 Job Object wrapper. Kernel terminates the entire CC process tree on wrapper exit -- even on crash, BSOD, or X-button close. |

Plus a SessionStart hook so leftovers from prior un-wrapped sessions get reaped automatically on every CC start.

## Quick start

```powershell
# 1. Clone into your skills directory
git clone https://github.com/ron2k1/claude-code-structured-concurrency `
    "$env:USERPROFILE\.claude\skills\structured-concurrency"

# 2. Install (creates ~/.reap/config.json + claude-jobbed alias)
& "$env:USERPROFILE\.claude\skills\structured-concurrency\tools\install-reap.ps1"

# 3. See what's running
& "$env:USERPROFILE\.claude\skills\structured-concurrency\tools\cc-procs.ps1"

# 4. Dry-run a reap (shows would-kill list, doesn't touch anything)
& "$env:USERPROFILE\.claude\skills\structured-concurrency\tools\cleanup-orphans.ps1"

# 5. When you trust the dry-run output, do it for real
& "$env:USERPROFILE\.claude\skills\structured-concurrency\tools\cleanup-orphans.ps1" -Force
```

Inside a Claude Code session, the same flow is also available as slash commands:

```
/structured-concurrency           # diagnostic
/structured-concurrency kill      # cleanup
/structured-concurrency install   # one-time setup
/structured-concurrency verify    # run tests
```

## Configuration

The cleanup engine is **dangerous-by-omission, never dangerous-by-default**. `cleanup-orphans.ps1 -Force` is a no-op out of the box; aggression is opt-in via `~/.reap/config.json`.

Three load layers, in precedence order:

1. `~/.reap/predicate.ps1` -- procedural override (power users, full PowerShell)
2. `~/.reap/config.json` -- declarative rules (most users)
3. Built-in safe default -- kills nothing if neither exists

Pick a starter profile at install time:

```powershell
.\tools\install-reap.ps1 -ConfigProfile conservative   # spare almost everything
.\tools\install-reap.ps1 -ConfigProfile moderate       # default; kill standard MCP chains
.\tools\install-reap.ps1 -ConfigProfile aggressive     # also kill node.exe / cmd.exe orphans
.\tools\install-reap.ps1 -ConfigProfile paranoid       # observe-only, never kills
```

See [`docs/CONFIGURATION.md`](docs/CONFIGURATION.md) for the full schema, the `predicate.ps1` escape hatch, and worked patterns ("I run in-house MCPs", "I want aggressive cleanup with a safety net", etc.).

## Architecture (1 minute version)

The Win32 primitive `Job Object` with the `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` flag is what Chrome, Edge, and VS Code use to bound the lifetime of their helper processes. When the handle to the job is closed (which happens when the parent process dies for *any* reason -- graceful exit, crash, force-kill, BSOD), the kernel walks the job's process list and terminates every member. This is documented behavior backed by [`AssignProcessToJobObject`](https://learn.microsoft.com/en-us/windows/win32/api/jobapi2/nf-jobapi2-assignprocesstojobobject) and verified by the test below.

`claude-jobbed.ps1`:

1. Calls `CreateJobObjectW` via P/Invoke
2. Sets `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` via `SetInformationJobObject`
3. Spawns `claude.exe` and assigns it (and all descendants by inheritance) to the job
4. Waits for `claude.exe` to exit
5. On wrapper exit, the job handle closes; kernel terminates the tree

This is structured concurrency enforced by the operating system kernel, not by application discipline. Application discipline is what produced the leaks in the first place.

See [`DESIGN.md`](DESIGN.md) for the full spec.

## Why "reap" stays inside the codebase

The skill is named after the OS-level concept (structured concurrency); inside the codebase, "reap" stays as the operational verb (function names, `~/.reap/` config dir, log file). Same way Linux is named after Linus but `init`, `fork`, `exec` are the verbs. This is deliberate: the name signals *what it is*, the verbs describe *what it does*.

## Tests

Functional, not synthetic:

- `tests/test-job-object.ps1` -- spawns a sleeping `node`-like child, closes the job handle, asserts the child died within 2 seconds. **Verified 9ms reap latency on Windows 11 build 26200.**
- `tests/test-orphan-detect.ps1` -- 9 unit tests on synthetic process snapshots: orphan detection (with PID-reuse guard via `StartTime` comparison), classification, descendant tree walk.
- `tests/test-config-loader.ps1` -- 9 unit tests on the config schema: defaults, malformed JSON fallback, partial-config merge, and the spare-wins-over-kill safety invariant.

Run all three:

```powershell
.\tests\test-job-object.ps1
.\tests\test-orphan-detect.ps1
.\tests\test-config-loader.ps1
```

If any fails on your Windows build, file an issue with `winver` output. The Job Object test in particular catches kernel-level edge cases on older builds.

## Compatibility

- Windows 10 / 11 (build >= 17134, January 2018 -- when Job Objects became fully reliable for this pattern)
- PowerShell 5.1 (default Windows install) or PowerShell 7+
- Git Bash (alias setup via `~/.bashrc` function; wrapper itself is PowerShell)
- WSL: not needed -- Linux already reaps via cgroups + `prctl(PR_SET_PDEATHSIG)`

Zero external dependencies. No PowerShell modules to install. No Python, no Node.js needed for the engine itself (only for the things it manages).

## Safety guarantees

- `cc-procs.ps1` is **always** read-only. It contains no `Stop-Process`, no `taskkill`, no `TerminateProcess`. Run it any time without risk.
- `cleanup-orphans.ps1` defaults to dry-run. Live kills require both `-Force` AND a config that opts in. With no `~/.reap/config.json`, the engine is a guaranteed no-op even with `-Force`.
- The engine MUST NEVER blanket-kill `node.exe` based on name alone. The decision flow always checks `spare_classifications` first, so `claude.exe` (classified as `claude`) cannot be killed even if `node.exe` is in `kill_names`. This invariant is exercised explicitly in `test-config-loader.ps1`.
- `claude-jobbed.ps1` is opt-in. Plain `claude` still works; the wrapper just adds the kill-on-close guarantee around it.

## Real-world impact

Pre-skill, on a Dell G15 5530 (i7-13650HX, 16GB DDR5):
- 80+ orphan `Node.js JavaScript Runtime` entries after 2 days of heavy use
- Reboot was the only reliable cleanup primitive
- Memory accumulation forced restart mid-work

Post-skill:
- Job Object wrapper: zero orphans on exit, kernel-enforced (verified 9ms reap latency)
- SessionStart hook: any leftovers from un-wrapped sessions cleared on next CC start
- Diagnostic surface: `cc-procs.ps1` shows orphan count + memory total any time

## License

MIT -- see [`LICENSE`](LICENSE). Author: Ronil Basu ([@ron2k1](https://github.com/ron2k1)).

## Related

- [Notes on structured concurrency, or: Go statement considered harmful](https://vorpus.org/blog/notes-on-structured-concurrency-or-go-statement-considered-harmful/) -- Nathaniel J. Smith, 2018. The piece that named the problem.
- [Win32 Job Objects](https://learn.microsoft.com/en-us/windows/win32/procthread/job-objects) -- Microsoft docs.
- [Anthropic MCP transport spec](https://modelcontextprotocol.io)

## Contributing

The leak is real, the fix shouldn't have to be reinvented per-developer. Issues and PRs welcome, particularly:

- Edge cases in PID-reuse detection (the `StartTime` comparison in `Test-IsOrphan`)
- Additional **universal** MCP-server detection patterns (in-house tools belong in `custom_classifiers`, not the shipped classifier)
- Job Object behavior on Windows Server or older builds
- Documentation improvements
