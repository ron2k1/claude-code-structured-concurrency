# Configuring claude-code-structured-concurrency

The cleanup engine ships **dangerous-by-omission, never dangerous-by-default**. Out of the box, `cleanup-orphans.ps1 -Force` is a no-op. You opt into aggression by editing one JSON file.

> "reap" stays as the operational verb inside the codebase (function names, `~/.reap/` config dir, `reap.log`). The skill is named after the OS-level concept (structured concurrency); the verb describes what it does to a process tree.

## Where config lives

| Path | Purpose |
|------|---------|
| `~/.reap/config.json` | Declarative rules. The normal user path. |
| `~/.reap/predicate.ps1` | Optional procedural override. Power-user escape hatch. |
| `$env:REAP_CONFIG_PATH` | Override the default config path (CI/scripts only). |

`install-reap.ps1` seeds `~/.reap/config.json` from `config-examples/<profile>.json` on first run. It will **not overwrite** an existing config -- rename or delete first if you want to re-seed.

## Picking a starter profile

```powershell
# Pick at install time:
.\tools\install-reap.ps1 -ConfigProfile conservative   # most defensive
.\tools\install-reap.ps1 -ConfigProfile moderate       # balanced (default)
.\tools\install-reap.ps1 -ConfigProfile aggressive     # heavy users
.\tools\install-reap.ps1 -ConfigProfile paranoid       # observe-only
```

| Profile | What it kills | When to use |
|---------|---------------|-------------|
| `conservative` | Only `cmd.exe` shim chains and `npx.cmd` wrappers. Spares all MCPs. | First install, or when you run custom in-house MCPs you can't risk killing. |
| `moderate` | Standard MCP/shim orphan chains older than 30s. Spares LSPs, plugin runtimes, anything `unknown`. | Most users, most of the time. |
| `aggressive` | Adds `node.exe` and `cmd.exe` by name; drops `unknown` from the spare list. | Heavy multi-session users with their in-house tools listed in `spare_cmdline_patterns`. |
| `paranoid` | Nothing. Pure observability. | Compliance environments, shared dev boxes, CI auditing. |

You can switch profiles any time -- just copy a different example over `~/.reap/config.json`.

## Schema

```jsonc
{
  "schema_version": 1,

  // Don't touch processes younger than this. Protects fresh subprocesses
  // that just happen to be orphaned by a slow parent handoff.
  "min_age_seconds": 30,

  // NEVER kill if classification is one of these. First check that runs.
  "spare_classifications": [
    "claude",         // active CC sessions
    "lsp",            // language servers
    "plugin-runtime", // stateful plugin processes
    "unknown"         // remove this for aggressive profiles
  ],

  // NEVER kill if cmdline matches any of these regexes (case-insensitive).
  // Use to protect specific in-house tools the classifier doesn't know.
  "spare_cmdline_patterns": [
    "my-stateful-tool",
    "company-internal-mcp"
  ],

  // Kill if classification is one of these AND no spare rule matched.
  "kill_classifications": [
    "mcp-stdio",   // standard stdio MCP servers
    "cmd-shim",    // cmd.exe shims (mostly leftover from npx)
    "npx-wrapper"  // node running npx-cli.js
  ],

  // Kill by exact process name (e.g. node.exe, cmd.exe). Aggressive --
  // use only after spare_cmdline_patterns is populated with your protected
  // tools. spare_classifications still wins, so claude.exe is safe.
  "kill_names": ["node.exe", "cmd.exe"],

  // Extend the classifier with your own patterns. Each entry is matched
  // against cmdline OR name; first match wins. Useful for in-house tools
  // that don't match the universal MCP/LSP heuristics.
  "custom_classifiers": [
    { "pattern": "my-internal-mcp",  "classification": "mcp-stdio" },
    { "pattern": "my-vector-store",  "classification": "plugin-runtime" }
  ]
}
```

(JSON doesn't support comments at runtime; ConvertFrom-Json silently ignores fields like `_description` -- the example files use that for inline notes.)

## Decision order

`Test-ReapPredicate` evaluates rules in this order. First match wins:

1. **Not orphan** -> skip *(defensive; the caller already filters)*
2. **Age < `min_age_seconds`** -> skip
3. **Classification in `spare_classifications`** -> skip
4. **CmdLine matches any `spare_cmdline_patterns`** -> skip
5. **Name in `kill_names`** -> KILL
6. **Classification in `kill_classifications`** -> KILL
7. **Default** -> skip *(fail-safe)*

The spare layers always run before the kill layers. That's why `claude.exe` cannot be accidentally killed even if you set `kill_names: ["node.exe"]` -- the classifier tags it `claude` and `claude` is in `spare_classifications`.

## Power-user escape hatch: `predicate.ps1`

If you need logic too procedural for JSON ("only kill MCPs spawned by a CC session that exited more than 5 minutes ago AND whose memory exceeds 200MB AND not on weekends"), drop a `predicate.ps1` next to your config:

```powershell
# ~/.reap/predicate.ps1
function IsKillable {
    param(
        $Process,
        [string]   $Classification,
        [TimeSpan] $Age,
        [bool]     $IsOrphan
    )
    if (-not $IsOrphan) { return $false }
    if ($Age.TotalSeconds -lt 300) { return $false }
    if ($Classification -in 'claude', 'lsp', 'plugin-runtime') { return $false }
    if ($Process.MemoryMB -lt 200) { return $false }
    if ((Get-Date).DayOfWeek -in 'Saturday', 'Sunday') { return $false }
    return $Classification -in 'mcp-stdio', 'cmd-shim', 'npx-wrapper' -or
           $Process.Name -in 'node.exe', 'cmd.exe'
}
```

When this file exists, `cleanup-orphans.ps1` dot-sources it AFTER its built-in `IsKillable`, so your function shadows the default. The JSON config is still loaded (used for the classifier's `custom_classifiers` field), but the predicate logic is yours.

## Wiring the SessionStart hook

After your config is tuned and you've run `.\tools\cleanup-orphans.ps1` in dry-run for a few sessions to confirm only intended targets get hit, wire the hook so reap fires on every CC startup:

Edit `~/.claude/settings.json`:

```jsonc
{
  "hooks": {
    "SessionStart": [
      {
        "command": "powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"%USERPROFILE%\\.claude\\skills\\structured-concurrency\\hooks\\reap-on-start.ps1\"",
        "timeout_ms": 10000
      }
    ]
  }
}
```

The hook script never throws -- it logs and exits 0 even on failure, so a bad reap config can never block CC startup. Logs land at `~/.claude/hooks/reap.log`.

## Verifying your config

```powershell
# Dry-run with verbose output -- shows every decision
.\tools\cleanup-orphans.ps1

# Override config path for testing
.\tools\cleanup-orphans.ps1 -ConfigPath .\config-examples\aggressive.json

# Check the log
Get-Content "$env:USERPROFILE\.claude\hooks\reap.log" -Tail 50
```

Log lines look like:
```
2026-05-07T12:34:56  reap start mode=DRY-RUN candidates=12 min_age=30s predicate=config:C:\Users\...\.reap\config.json
2026-05-07T12:34:56  would-kill pid=8472 name=node.exe class=mcp-stdio age=180s memMB=98.4 reason=predicate-true
2026-05-07T12:34:56  would-kill pid=8473 name=cmd.exe  class=cmd-shim  age=180s memMB=2.1  reason=descendant-of-8472
2026-05-07T12:34:56  skip pid=9012 name=python.exe class=lsp age=600s reason=predicate-false
2026-05-07T12:34:56  reap end mode=DRY-RUN would-kill=2 skipped=10
```

## Common patterns

### "I run a few in-house MCPs that hold state"

Add their distinguishing pattern to `spare_cmdline_patterns`:

```json
"spare_cmdline_patterns": [
  "my-vector-store",
  "internal-rag-server",
  "company-data-bridge"
]
```

### "I want to identify my custom tools in the cc-procs.ps1 diagnostic table"

Add `custom_classifiers` entries:

```json
"custom_classifiers": [
  { "pattern": "my-vector-store",     "classification": "plugin-runtime" },
  { "pattern": "internal-rag-server", "classification": "mcp-stdio" }
]
```

This makes the diagnostic readable AND lets you reference the classification name in `spare_classifications` / `kill_classifications`.

### "I want aggressive cleanup but with a safety net"

```json
"min_age_seconds": 120,
"spare_cmdline_patterns": ["my-tool-1", "my-tool-2"],
"kill_classifications": ["mcp-stdio", "cmd-shim", "npx-wrapper"],
"kill_names": ["node.exe", "cmd.exe"]
```

`min_age_seconds: 120` means newly-spawned subprocesses get a 2-minute grace window before reap will touch them. Combined with `spare_cmdline_patterns`, this gives two layers of defense.

### "I'm in CI / a shared dev box"

Use `paranoid.json` and rely on dry-run reports for telemetry. Engine never destroys anything.
