# ProcessTree.ps1 -- analysis helpers for CC-related process trees.
#
# Read-only. No Stop-Process, no taskkill. Pure inspection: parent
# chain walking, age, classification, orphan detection.
#
# Used by:
#   tools/cc-procs.ps1         (diagnostic)
#   tools/cleanup-orphans.ps1  (calls Test-IsOrphan + Get-ProcessClassification)

function Get-CCProcessSnapshot {
    <#
    .SYNOPSIS
    Snapshot all processes with the fields we care about, indexed by PID.
    Single CIM call so PID set is consistent across analysis.

    .OUTPUTS
    Hashtable of PID -> PSCustomObject{Pid, ParentPid, Name, CmdLine,
    StartTime, MemoryMB, ExePath}
    #>
    [CmdletBinding()]
    param()

    $procs = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue
    $byPid = @{}
    foreach ($p in $procs) {
        $start = $null
        try { $start = $p.CreationDate } catch { }
        $obj = [PSCustomObject]@{
            Pid       = [int]$p.ProcessId
            ParentPid = [int]$p.ParentProcessId
            Name      = $p.Name
            CmdLine   = $p.CommandLine
            ExePath   = $p.ExecutablePath
            StartTime = $start
            MemoryMB  = [math]::Round($p.WorkingSetSize / 1MB, 1)
        }
        $byPid[$obj.Pid] = $obj
    }
    return $byPid
}

function Test-IsOrphan {
    <#
    .SYNOPSIS
    A process is a strict orphan if its ParentPid does NOT appear in the
    snapshot (the parent is dead). PID reuse is a known limitation;
    Windows recycles PIDs aggressively, so we additionally check that
    the apparent parent in the snapshot started AFTER the child -- if so,
    it's a recycled PID and the real parent is dead.

    .PARAMETER Process
    Process object from Get-CCProcessSnapshot.

    .PARAMETER Snapshot
    The full snapshot hashtable.

    .OUTPUTS
    [bool]
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] $Process,
        [Parameter(Mandatory)] [hashtable] $Snapshot
    )

    if (-not $Snapshot.ContainsKey($Process.ParentPid)) {
        return $true
    }

    $apparentParent = $Snapshot[$Process.ParentPid]
    if ($apparentParent.StartTime -and $Process.StartTime -and
        $apparentParent.StartTime -gt $Process.StartTime) {
        # apparent parent started after this child -- PID was reused, real parent is dead
        return $true
    }

    return $false
}

function Get-ProcessAge {
    <#
    .SYNOPSIS
    Age of a process as a [TimeSpan]. Returns [TimeSpan]::Zero if start
    time is unknown.
    #>
    [CmdletBinding()]
    [OutputType([TimeSpan])]
    param([Parameter(Mandatory)] $Process)
    if (-not $Process.StartTime) { return [TimeSpan]::Zero }
    return (Get-Date) - $Process.StartTime
}

function Get-ProcessClassification {
    <#
    .SYNOPSIS
    Heuristic classification of a process based on name + command line.
    Used for diagnostic output; never used as the sole basis for kill
    decisions.

    .PARAMETER CustomClassifiers
    Optional array of @{pattern=<regex>; classification=<string>} entries
    from the user's reap config. Checked BEFORE the built-in heuristics so
    user-specific tools (vault stores, custom MCPs, in-house runtimes) get
    the labels their config specifies. Pattern is matched against the
    lowercased command line OR the process name.

    .OUTPUTS
    One of: claude, mcp-stdio, mcp-http, lsp, plugin-runtime, cmd-shim,
    npx-wrapper, hook-script, unknown -- or any classification string a
    custom_classifiers entry produces.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] $Process,
        [object[]] $CustomClassifiers = @()
    )

    $name = $Process.Name
    $cl   = if ($Process.CmdLine) { $Process.CmdLine.ToLower() } else { '' }

    # Custom classifiers from user config -- user override beats default
    # heuristics. Useful for in-house tools that don't match the universal
    # MCP/LSP patterns. Each entry is { pattern: <regex>, classification: <string> }.
    foreach ($cc in $CustomClassifiers) {
        if (-not $cc) { continue }
        $pat = $cc.pattern
        if (-not $pat) { continue }
        if (($cl -and $cl -match $pat) -or ($name -and $name -match $pat)) {
            return [string]$cc.classification
        }
    }

    # Name-based fast path: a process literally named claude.exe is claude,
    # regardless of whether CmdLine resolves to a full path. This catches
    # the case where WMI returns a stripped CmdLine and is also a stronger
    # signal than path-fragment matching (paths can be obfuscated; a binary
    # name change requires renaming the executable).
    if ($name -eq 'claude.exe') {
        return 'claude'
    }

    if ($cl -match '\\claude\.exe' -or $cl -match '\\claude\b' -or
        $cl -match 'anthropic-ai[/\\]claude-code') {
        return 'claude'
    }

    if ($name -eq 'cmd.exe') {
        if ($cl -match 'npx' -or $cl -match 'mcp\b') { return 'cmd-shim' }
        return 'cmd-shim'
    }

    if ($name -eq 'node.exe') {
        if ($cl -match 'npx-cli\.js') { return 'npx-wrapper' }
        if ($cl -match '@modelcontextprotocol' -or
            $cl -match 'mcp-server' -or $cl -match 'mcp-' -or
            $cl -match '\bmcp\b') {
            return 'mcp-stdio'
        }
        if ($cl -match 'typescript-language-server' -or
            $cl -match 'typescript[/\\]bin' -or
            $cl -match 'tsserver') {
            return 'lsp'
        }
        return 'unknown'
    }

    if ($name -eq 'python.exe' -or $name -eq 'pyright-langserver.exe') {
        if ($cl -match 'pyright') { return 'lsp' }
        if ($cl -match '\.claude[/\\]hooks') { return 'hook-script' }
        return 'unknown'
    }

    if ($name -eq 'powershell.exe' -or $name -eq 'pwsh.exe') {
        if ($cl -match '\.claude[/\\]hooks') { return 'hook-script' }
        if ($cl -match 'reap[/\\]') { return 'hook-script' }
        return 'unknown'
    }

    if ($name -eq 'rust-analyzer.exe' -or $name -eq 'gopls.exe' -or
        $name -eq 'clangd.exe') {
        return 'lsp'
    }

    return 'unknown'
}

function Get-CCDescendants {
    <#
    .SYNOPSIS
    Walk the process tree downward from a root PID, collecting every
    descendant. Used to identify "everything this CC session spawned."

    .OUTPUTS
    [PSCustomObject[]] from the snapshot -- the root + all transitive children.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [int]       $RootPid,
        [Parameter(Mandatory)] [hashtable] $Snapshot
    )

    if (-not $Snapshot.ContainsKey($RootPid)) { return @() }

    $result  = @($Snapshot[$RootPid])
    $stack   = New-Object System.Collections.Generic.Stack[int]
    $stack.Push($RootPid)
    $visited = @{ $RootPid = $true }

    while ($stack.Count -gt 0) {
        $cur = $stack.Pop()
        foreach ($entry in $Snapshot.GetEnumerator()) {
            $proc = $entry.Value
            if ($proc.ParentPid -eq $cur -and -not $visited.ContainsKey($proc.Pid)) {
                $visited[$proc.Pid] = $true
                $result += $proc
                $stack.Push($proc.Pid)
            }
        }
    }
    return $result
}

function Find-ClaudeRoots {
    <#
    .SYNOPSIS
    Identify all claude.exe / claude (node) processes -- the roots of
    every active CC session on this machine.

    .OUTPUTS
    [PSCustomObject[]] from the snapshot.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [hashtable] $Snapshot)

    $roots = @()
    foreach ($entry in $Snapshot.GetEnumerator()) {
        $p = $entry.Value
        if ((Get-ProcessClassification -Process $p) -eq 'claude') {
            $roots += $p
        }
    }
    return $roots
}
