# FAQ -- claude-code-structured-concurrency

Common questions, organized by category. If your question isn't here, [open an issue](https://github.com/ron2k1/claude-code-structured-concurrency/issues/new).

---

## Adoption (the install-vs-adoption gap)

### Q1: I ran `install-reap.ps1` and processes are still leaking. Why?

**`install-reap.ps1` does not protect any CC session that is currently running, and it cannot intercept every way you might launch CC.**

The installer does three things:
1. Seeds `~/.reap/config.json` (so the cleanup engine has a predicate)
2. Adds a `claude-jobbed` function to `$PROFILE` (PowerShell)
3. Adds a `claude-jobbed` function to `~/.bashrc` (Git Bash)

By default, plain `claude` keeps pointing at the real `claude.exe` -- you have to type `claude-jobbed` explicitly to get protection. Pass `-ShadowClaude` at install time to also shadow plain `claude` so typing it routes through the wrapper. See [Q16](#q16-how-do-i-make-typing-claude-route-through-the-wrapper-without-having-to-type-claude-jobbed) for details.

It does **not**:
- Reach into your already-running `claude.exe` and assign it to a Job Object retroactively (that's not possible -- Job Objects must be assigned at process creation or via parent inheritance).
- Modify Windows shortcuts, Run-dialog history, or VS Code terminal config.
- Replace `claude.exe` on disk with a wrapper.

The fix: open a **new** PowerShell or Git Bash window after install, then launch `claude` from that fresh shell. See [Q2](#q2-how-do-i-tell-if-my-current-cc-session-is-wrapped) for verification.

### Q2: How do I tell if my current CC session is wrapped?

Run this in any PowerShell window:

```powershell
$cc = Get-CimInstance Win32_Process -Filter "Name='claude.exe'"
foreach ($c in $cc) {
  $parent = Get-CimInstance Win32_Process -Filter "ProcessId=$($c.ParentProcessId)"
  Write-Host ("PID {0} parent: {1}" -f $c.ProcessId, $parent.Name)
}
```

| Parent process | Verdict |
|----------------|---------|
| `powershell.exe` running `claude-jobbed.ps1` | Wrapped (good) |
| `cmd.exe`, `WindowsTerminal.exe`, `Code.exe`, `explorer.exe` | Unwrapped (children will leak on crash) |

If you want a stronger check, see [Q14](#q14-how-do-i-prove-the-job-object-is-actually-active-not-just-the-wrapper-process).

### Q3: The alias is in my `$PROFILE` but `Get-Command claude` still shows `Application`

This means PowerShell didn't load your profile. Common causes:

1. **You opened the shell before installation finished.** Close all PowerShell windows and open a new one.
2. **Execution policy blocked `$PROFILE`.** Check with:
   ```powershell
   Get-ExecutionPolicy -List
   ```
   If `CurrentUser` shows `Restricted`, set it to `RemoteSigned`:
   ```powershell
   Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
   ```
3. **You're using PowerShell 5.1 but installed into the PowerShell 7 profile (or vice versa).** They have separate `$PROFILE` files. Run `$PROFILE` in each shell to see; rerun `install-reap.ps1` from the shell that's missing it.
4. **`$PROFILE` errored out before reaching the alias line.** Run `pwsh -NoProfile` then `. $PROFILE` to surface the error.

### Q4: I launch CC from a desktop shortcut / Win+R / VS Code's integrated terminal. Does it pick up the wrapper?

Generally **no**, with one exception:

| Launch method | Wrapped? | Why |
|---------------|----------|-----|
| Desktop shortcut to `claude.exe` | No | Shortcut targets the binary directly, bypasses shell aliases |
| `Win+R` -> `claude` | No | Run dialog uses Windows' search-path resolution, not your `$PROFILE` |
| VS Code integrated terminal | Sometimes | Depends on whether VS Code's `terminal.integrated.profiles.windows` is configured to source `$PROFILE`. PowerShell profile loads by default; Git Bash may not source `~/.bashrc` for non-interactive shells. |
| Windows Terminal | Yes (PowerShell tab) | Loads `$PROFILE` like any new PowerShell session |
| Task Scheduler | No | Runs in non-interactive context, ignores `$PROFILE` |

**If you must launch from a non-aliased context**, point the shortcut/scheduler at `claude-jobbed.ps1` directly:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%USERPROFILE%\.claude\skills\structured-concurrency\tools\claude-jobbed.ps1"
```

### Q5: I see candidates like `csrss.exe`, `winlogon.exe`, `explorer.exe` in `cleanup-orphans.ps1`'s output. Is the engine going to kill them?

No. Those appear in the **candidate list** because the engine surveys all processes whose parents are dead, but each is then evaluated by the predicate (your `~/.reap/config.json`). For the moderate profile, every one of those gets `predicate-false` and is skipped:

```text
skip pid=1488 name=csrss.exe class=unknown reason=predicate-false
skip pid=10292 name=explorer.exe class=unknown reason=predicate-false
```

The "candidate list" is intentionally inclusive (it's how the engine documents what it considered). The "would-kill" / "killed" lines are what actually fire. Always read the trailing `reap end mode=... would-kill=N skipped=M` line for the real outcome.

If you ever see a Windows root process in the `would-kill` line, file an issue immediately -- that would be a config bug, not a normal state.

### Q16: How do I make typing `claude` route through the wrapper without having to type `claude-jobbed`?

Re-run the installer with the `-ShadowClaude` flag:

```powershell
& "$env:USERPROFILE\.claude\skills\structured-concurrency\tools\install-reap.ps1" -ShadowClaude
```

This adds a second function inside the same managed-block markers in `$PROFILE` and `~/.bashrc`:

```powershell
# In $PROFILE:
function claude-jobbed { & '...claude-jobbed.ps1' @args }
function claude { claude-jobbed @args }   # added by -ShadowClaude
```

PowerShell resolves Functions before Applications on PATH, so `claude` now hits the function (not `claude.exe`) at parse time. Verify in a fresh shell:

```powershell
Get-Command claude
# CommandType : Function
# Definition  : claude-jobbed @args
```

**Limits:** the shadow only takes effect in shells that load `$PROFILE` (PS) or `~/.bashrc` (Git Bash). Specifically, it does **not** intercept:

- `cmd.exe` (no profile mechanism)
- `Win+R` -> `claude` (resolves against PATH, no shell)
- Desktop shortcuts pointing at `claude.exe`
- VS Code's terminal until you reload it after the install
- Anything calling `claude.exe` by absolute path

For those, see [Q4](#q4-i-launch-cc-from-a-desktop-shortcut--winr--vs-codes-integrated-terminal-does-it-pick-up-the-wrapper). The flag is opt-in and idempotent: re-run `install-reap.ps1` (without the flag) to remove the shadow but keep `claude-jobbed`. Re-run with `-Uninstall` to remove both functions.

**Why a function, not `Set-Alias`?** PowerShell's command-resolution order is: Alias -> Function -> Cmdlet -> Application. An alias named `claude` would lose to `claude.exe` on PATH. A function wins because functions are resolved before PATH lookup. Same trick the existing `claude-jobbed` shim already uses.

---

## Daily use

### Q6: Can I have multiple wrapped CC sessions running at the same time?

Yes. Each `claude-jobbed.ps1` invocation creates its **own** Job Object. Two simultaneous CC sessions = two Job Objects, fully independent. Closing one wrapper terminates only that wrapper's tree.

```powershell
# In shell A:
claude    # session A, Job Object A, ~50 children

# In shell B (separate window):
claude    # session B, Job Object B, ~50 children

# Close shell A -> Job A reaps A's children only. Session B unaffected.
```

The `~/.reap/config.json` setting `spare_classifications: ["claude"]` ensures `cleanup-orphans.ps1` won't reap an active session's children even if you run cleanup mid-session, because the live `claude.exe` is the parent of all of them and they classify as `claude`.

### Q7: What's the runtime overhead of the Job Object wrapper?

Effectively zero. Specifically:

- **Process startup**: ~10-30ms one-time cost for the P/Invoke into `CreateJobObjectW` + `AssignProcessToJobObject`. This is dwarfed by `claude.exe`'s own startup (~500ms+).
- **Per-MCP spawn**: zero. The Job is set up once; new children inherit Job membership for free via Windows process inheritance rules.
- **Memory**: a few KB for the Job kernel object + accounting structures.
- **CPU**: zero in steady state. The kernel updates Job accounting opportunistically; your MCPs don't pay any per-syscall tax.

If you're benchmarking, you won't see a difference. The wrapper adds protection without adding cost.

### Q8: How do I add my own in-house MCP to the spare list without forking the repo?

Two options, no fork required:

**Option A -- declarative (config.json):**

```jsonc
{
  "spare_cmdline_patterns": [
    "my-company-mcp",
    "internal-tools[/\\]server\\.js"
  ],
  "custom_classifiers": [
    { "pattern": "my-company-mcp", "classification": "in-house" }
  ],
  "spare_classifications": ["claude", "lsp", "in-house"]
}
```

`spare_cmdline_patterns` matches the full command line as a regex (case-insensitive). `custom_classifiers` lets you label a process so other rules can target it.

**Option B -- procedural (predicate.ps1):**

Drop a `~/.reap/predicate.ps1` next to your config; it fully overrides the JSON-based predicate. Full PowerShell available -- write whatever logic you want:

```powershell
function Test-IsKillable {
    param([object] $Process)
    if ($Process.CommandLine -match 'my-company-mcp') { return $false }
    if ((Get-Date) - $Process.StartTime -lt [TimeSpan]::FromMinutes(5)) { return $false }
    return $true
}
```

See [`docs/CONFIGURATION.md`](CONFIGURATION.md) for the full schema and decision-order spec.

### Q9: The SessionStart hook fired but `~/.claude/hooks/reap.log` is empty. Is that bad?

No, that's the success state. `cleanup-orphans.ps1` only logs when it finds candidates; an empty log means there were no orphans to consider. The first non-empty log line after a fresh boot will look like:

```text
2026-05-07T21:27:01  reap start mode=DRY-RUN candidates=0 ...
2026-05-07T21:27:01  reap end mode=DRY-RUN would-kill=0 skipped=0
```

If the file doesn't exist at all, the hook never fired. Verify hook wiring by checking `~/.claude/settings.json` for the `SessionStart` block referenced in `docs/CONFIGURATION.md`.

---

## Edge cases

### Q10: Does this work in WSL?

Not needed and not applicable. WSL processes run under Linux, which has its own structured-concurrency primitives (`prctl(PR_SET_PDEATHSIG)`, cgroups, systemd scopes). The Job Object API is Windows-kernel-only.

If you're running CC inside WSL, your MCPs are Linux processes that get cleaned up by Linux mechanisms when the WSL distro shuts down. The Win32 wrapper has nothing to wrap.

### Q11: Does this work over SSH (CC running on a remote Windows host)?

Yes, with one caveat about Session 0 isolation. If your SSH server runs as a service (most do), interactive PowerShell launched over SSH lives in Session 0 by default. Job Objects work fine in Session 0; the wrapper has no SSH-specific behavior.

The caveat: if any of your MCPs depend on a desktop session (UI automation, screenshot tools, browser launchers), those will fail anyway -- not because of this skill, but because Session 0 has no desktop. You'd need a Task Scheduler `InteractiveToken` launch to get into Session 1, and then the wrapper can run inside that.

### Q12: How do I uninstall?

```powershell
& "$env:USERPROFILE\.claude\skills\structured-concurrency\tools\install-reap.ps1" -Uninstall
```

This removes the alias block from `$PROFILE` and `~/.bashrc` (idempotent -- if the markers aren't there, it's a no-op). It does **not** delete:

- `~/.reap/config.json` (your tuned predicate)
- `~/.reap/predicate.ps1` (your custom logic)
- `~/.claude/hooks/reap.log` (audit history)
- The skill itself at `~/.claude/skills/structured-concurrency/`

Delete those manually if you want a full clean state.

To stop wrapping CC without uninstalling, just launch `claude.exe` directly (skipping the alias) -- the wrapper isn't path-injected, only aliased.

### Q13: Will the wrapper break my existing CC functionality?

It shouldn't. The wrapper does exactly four things:

1. Calls `CreateJobObjectW` (kernel-side; no observable user effect)
2. Sets `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` (kernel-side)
3. Spawns `claude.exe` exactly as you would have, forwarding all command-line arguments
4. Waits for `claude.exe` to exit, then closes the Job handle

If something does break, the smoking gun is usually one of:
- A child process that wanted to detach itself (rare in MCP-land)
- A debugger that wanted to attach to a child outside the Job (Job Objects can be configured to allow this; the shipped wrapper does not)
- Antivirus heuristics flagging the P/Invoke (whitelisting `claude-jobbed.ps1` resolves this)

To compare wrapped vs unwrapped quickly, launch with `--no-wrap` if your alias is the function form, or just call `claude.exe` directly to bypass the alias. File an issue with both behaviors documented if you find a regression.

### Q14: How do I prove the Job Object is actually active, not just the wrapper process?

Run the test suite:

```powershell
& "$env:USERPROFILE\.claude\skills\structured-concurrency\tests\test-job-object.ps1"
```

This spawns a `node`-like sleeper, assigns it to a fresh Job, closes the Job handle, and asserts the child died within 2 seconds. Expected output ends with:

```text
[PASS] child terminated within 10ms of job close
```

If you want to prove it for *your specific* CC session (rather than a synthetic test), you can use `IsProcessInJob` from kernel32 via P/Invoke. Easier alternative: kill the wrapper process (not `claude.exe`, the parent PowerShell) and watch all the children die. If they don't, the Job didn't form -- file an issue.

### Q15: Can the wrapper handle CC's auto-update behavior?

Yes. CC auto-update writes new binaries to `%APPDATA%\npm\node_modules\@anthropic-ai\claude-code\` and the next launch picks them up. Since the wrapper invokes `claude.exe` by path resolution at launch time, it always picks up the latest version -- it never caches a stale binary path.

If CC auto-relaunches itself (some update flows do this), the new `claude.exe` is a child of the old one and inherits the Job. Both old and new are members of the same Job until the old exits. This is the correct behavior; you don't lose protection across updates.

---

## Still have questions?

- Operational details: [`docs/CONFIGURATION.md`](CONFIGURATION.md)
- Architecture rationale: [`DESIGN.md`](../DESIGN.md)
- Skill reference (for use inside Claude Code): [`SKILL.md`](../SKILL.md)
- Anything not covered above: [open an issue](https://github.com/ron2k1/claude-code-structured-concurrency/issues/new)
