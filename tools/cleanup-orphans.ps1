# cleanup-orphans.ps1 -- Layer 2: find and (with -Force) terminate strict-orphan
# Claude Code subprocesses.
#
# Default mode is dry-run: lists what *would* be killed, kills nothing.
# Pass -Force to actually call Stop-Process. Logs every decision (kept,
# would-kill, killed, skipped) to stdout AND to ~/.claude/hooks/reap.log
# so the SessionStart hook entry is auditable later.
#
# WHICH orphans are killable is decided by config, not code. Three layers:
#
#   1. ~/.reap/predicate.ps1   -- if present, fully replaces IsKillable.
#                                  Power-user procedural override; full PS
#                                  expressiveness. See docs/CONFIGURATION.md.
#   2. ~/.reap/config.json     -- declarative rules (allowlist + killset +
#                                  custom classifiers). Normal user path.
#   3. Built-in safe default   -- kills nothing. Out-of-the-box `-Force`
#                                  is a no-op until the user opts in.
#
# Aggression is opt-in. A misconfigured engine fails closed.
#
# Usage:
#   .\cleanup-orphans.ps1                     # dry-run (default)
#   .\cleanup-orphans.ps1 -Force              # actually kill per config
#   .\cleanup-orphans.ps1 -ConfigPath foo.json    # override config location
#
# Exit code:
#   live mode (-Force):  number of processes terminated
#   dry-run mode:        always 0 (no side effects, no failure semantics)

[CmdletBinding()]
param(
    [switch] $Force,
    [string] $ConfigPath,
    [string] $LogPath = (Join-Path $env:USERPROFILE '.claude\hooks\reap.log')
)

$ErrorActionPreference = 'Stop'
$DryRun = -not $Force

# Dot-source analysis library + config loader
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'lib\ProcessTree.ps1')
. (Join-Path $here 'lib\ConfigLoader.ps1')

# Load config (built-in safe-no-op default if no ~/.reap/config.json)
$script:ReapConfig = if ($ConfigPath) {
    Get-ReapConfig -Path $ConfigPath
} else {
    Get-ReapConfig
}

# Default IsKillable: dispatch to the config-driven predicate.
function IsKillable {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]            $Process,
        [Parameter(Mandatory)] [string]   $Classification,
        [Parameter(Mandatory)] [TimeSpan] $Age,
        [Parameter(Mandatory)] [bool]     $IsOrphan
    )
    return Test-ReapPredicate `
        -Process $Process `
        -Classification $Classification `
        -Age $Age `
        -IsOrphan $IsOrphan `
        -Config $script:ReapConfig
}

# Escape hatch: ~/.reap/predicate.ps1 can fully redefine IsKillable.
# Loaded AFTER the default so the user's function shadows ours.
$predicateOverride = Join-Path $env:USERPROFILE '.reap\predicate.ps1'
if (Test-Path $predicateOverride) {
    try {
        . $predicateOverride
        $script:PredicateSource = $predicateOverride
    } catch {
        Write-Warning "reap: predicate.ps1 failed to load -- falling back to config. error=$_"
        $script:PredicateSource = "config:$($script:ReapConfig.source)"
    }
} else {
    $script:PredicateSource = "config:$($script:ReapConfig.source)"
}

# --- log helper ---------------------------------------------------------

function Write-ReapLog {
    param([Parameter(Mandatory)] [string] $Msg)
    $ts   = (Get-Date).ToString('s')
    $line = "$ts  $Msg"
    Write-Host $line
    try {
        $dir = Split-Path -Parent $LogPath
        if (-not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        Add-Content -Path $LogPath -Value $line -Encoding utf8
    } catch {
        Write-Verbose "log write failed: $_"
    }
}

# --- main ---------------------------------------------------------------

$snap = Get-CCProcessSnapshot
$candidates = @()
foreach ($entry in $snap.GetEnumerator()) {
    $p = $entry.Value
    if (Test-IsOrphan -Process $p -Snapshot $snap) {
        $candidates += $p
    }
}

$mode = if ($DryRun) { 'DRY-RUN' } else { 'LIVE' }
Write-ReapLog "reap start mode=$mode candidates=$($candidates.Count) min_age=$($script:ReapConfig.min_age_seconds)s predicate=$script:PredicateSource"

$wouldKill = 0
$killed    = 0
$skipped   = 0
$processed = @{}   # PID -> $true; prevents double-handling when descendant
                   # subtrees of multiple orphans overlap.

foreach ($p in $candidates) {
    if ($processed.ContainsKey($p.Pid)) { continue }

    $cls    = Get-ProcessClassification -Process $p -CustomClassifiers $script:ReapConfig.custom_classifiers
    $age    = Get-ProcessAge -Process $p
    $orphan = $true   # filtered above

    $verdict = $false
    try {
        $verdict = IsKillable `
            -Process $p `
            -Classification $cls `
            -Age $age `
            -IsOrphan $orphan
    } catch {
        Write-ReapLog "predicate-error pid=$($p.Pid) name=$($p.Name) err=$_"
    }

    if (-not $verdict) {
        Write-ReapLog ("skip pid={0} name={1} class={2} age={3}s reason=predicate-false" -f
                      $p.Pid, $p.Name, $cls, [int]$age.TotalSeconds)
        $skipped++
        $processed[$p.Pid] = $true
        continue
    }

    # DOOMED SET: the orphan + every descendant in the snapshot. Descendants
    # are dragged in regardless of their own classification — once the parent
    # is going, conhost shims and child helper exes have nothing to attach to
    # and would just become new orphans on the next sweep. This is the
    # "kill the chain" semantic the user asked for.
    $doomed = @($p) + (Get-CCDescendants -RootPid $p.Pid -Snapshot $snap |
                       Where-Object { $_.Pid -ne $p.Pid })

    foreach ($d in $doomed) {
        if ($processed.ContainsKey($d.Pid)) { continue }
        $processed[$d.Pid] = $true

        $dCls = Get-ProcessClassification -Process $d -CustomClassifiers $script:ReapConfig.custom_classifiers
        $dAge = Get-ProcessAge -Process $d
        $reason = if ($d.Pid -eq $p.Pid) { 'predicate-true' } else { "descendant-of-$($p.Pid)" }

        if ($DryRun) {
            Write-ReapLog ("would-kill pid={0} name={1} class={2} age={3}s memMB={4} reason={5}" -f
                          $d.Pid, $d.Name, $dCls, [int]$dAge.TotalSeconds, $d.MemoryMB, $reason)
            $wouldKill++
            continue
        }

        try {
            Stop-Process -Id $d.Pid -Force -ErrorAction Stop
            Write-ReapLog ("killed pid={0} name={1} class={2} age={3}s memMB={4} reason={5}" -f
                          $d.Pid, $d.Name, $dCls, [int]$dAge.TotalSeconds, $d.MemoryMB, $reason)
            $killed++
        } catch {
            Write-ReapLog ("kill-failed pid={0} name={1} reason={2} err={3}" -f
                          $d.Pid, $d.Name, $reason, $_)
        }
    }
}

if ($DryRun) {
    Write-ReapLog "reap end mode=DRY-RUN would-kill=$wouldKill skipped=$skipped"
    if ($wouldKill -gt 0) {
        Write-Host ""
        Write-Host "  Re-run with -Force to actually terminate the $wouldKill orphan(s)." `
                   -ForegroundColor DarkYellow
    }
    exit 0
} else {
    Write-ReapLog "reap end mode=LIVE killed=$killed skipped=$skipped"
    exit $killed
}
