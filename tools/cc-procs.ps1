# cc-procs.ps1 -- Layer 1: read-only diagnostic for Claude Code process trees.
#
# Prints a colored tree of every active CC session and its descendants,
# plus any strict orphans whose lineage suggests CC heritage (mcp-stdio,
# lsp, hook-script, etc.). Never calls Stop-Process / taskkill /
# TerminateProcess. Safe to run at any time.
#
# Usage:
#   .\cc-procs.ps1                 # tree + orphan list + summary (default)
#   .\cc-procs.ps1 -OrphansOnly    # only the orphans section
#   .\cc-procs.ps1 -AsObject       # returns [PSCustomObject[]] for piping
#
# Exit code: always 0. Diagnostics never fail the caller.

[CmdletBinding()]
param(
    [switch] $AsObject,
    [switch] $OrphansOnly
)

$ErrorActionPreference = 'Stop'

# Dot-source the analysis library next to us
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'lib\ProcessTree.ps1')

# --- formatting helpers -------------------------------------------------

function Format-Age {
    param([TimeSpan] $Span)
    if ($Span.TotalDays    -ge 1) { return "{0:n0}d{1:n0}h" -f [math]::Floor($Span.TotalDays),    $Span.Hours   }
    if ($Span.TotalHours   -ge 1) { return "{0:n0}h{1:n0}m" -f [math]::Floor($Span.TotalHours),   $Span.Minutes }
    if ($Span.TotalMinutes -ge 1) { return "{0:n0}m{1:n0}s" -f [math]::Floor($Span.TotalMinutes), $Span.Seconds }
    return "{0:n0}s" -f [math]::Floor($Span.TotalSeconds)
}

function Get-ClassColor {
    param([string] $Cls)
    switch ($Cls) {
        'claude'         { 'Yellow'   }
        'mcp-stdio'      { 'Cyan'     }
        'mcp-http'       { 'Cyan'     }
        'lsp'            { 'Magenta'  }
        'plugin-runtime' { 'Blue'     }
        'cmd-shim'       { 'DarkGray' }
        'npx-wrapper'    { 'DarkGray' }
        'hook-script'    { 'Green'    }
        default          { 'Gray'     }
    }
}

function Get-CmdSnippet {
    param([string] $Cmd)
    if (-not $Cmd) { return '' }
    $c = $Cmd.Trim()
    if ($c.Length -gt 90) {
        return '...' + $c.Substring($c.Length - 87)
    }
    return $c
}

function Show-Line {
    param(
        [Parameter(Mandatory)]            $Process,
        [Parameter(Mandatory)] [bool]     $IsOrphan,
        [string]                          $Indent = ''
    )
    $cls   = Get-ProcessClassification -Process $Process
    $age   = Format-Age (Get-ProcessAge -Process $Process)
    $color = if ($IsOrphan) { 'Red' } else { Get-ClassColor $cls }
    $tag   = if ($IsOrphan) { '[ORPHAN] ' } else { '' }
    $line  = ("{0}{1,6}  {2,-13}  age={3,-7}  mem={4,6:n0}MB  {5}" -f
              $tag, $Process.Pid, $cls, $age, $Process.MemoryMB, $Process.Name)
    Write-Host ($Indent + $line) -ForegroundColor $color
    if ($Process.CmdLine) {
        Write-Host ($Indent + '         ' + (Get-CmdSnippet $Process.CmdLine)) -ForegroundColor DarkGray
    }
}

function Show-Tree {
    param(
        [Parameter(Mandatory)]              $Root,
        [Parameter(Mandatory)] [hashtable]  $Snapshot,
        [string]                            $Indent  = '',
        [hashtable]                         $Visited = $null
    )
    if ($null -eq $Visited) { $Visited = @{} }
    if ($Visited.ContainsKey($Root.Pid)) { return }
    $Visited[$Root.Pid] = $true

    Show-Line -Process $Root -IsOrphan $false -Indent $Indent

    $children = $Snapshot.Values | Where-Object {
        $_.ParentPid -eq $Root.Pid -and $_.Pid -ne $Root.Pid
    } | Sort-Object Pid

    foreach ($child in $children) {
        Show-Tree -Root $child -Snapshot $Snapshot -Indent ('  ' + $Indent) -Visited $Visited
    }
}

# --- data gathering -----------------------------------------------------

$snap  = Get-CCProcessSnapshot
$roots = Find-ClaudeRoots -Snapshot $snap

# Build the universe: every claude tree + every CC-shaped strict orphan.
# Hashtable keyed by PID gives us deduplication for free.
$tracked = @{}
foreach ($r in $roots) {
    foreach ($d in (Get-CCDescendants -RootPid $r.Pid -Snapshot $snap)) {
        $tracked[$d.Pid] = $d
    }
}

$orphans   = @()
$ccClasses = @('mcp-stdio', 'mcp-http', 'lsp', 'plugin-runtime',
               'cmd-shim', 'npx-wrapper', 'hook-script')
foreach ($entry in $snap.GetEnumerator()) {
    $p = $entry.Value
    if (Test-IsOrphan -Process $p -Snapshot $snap) {
        $cls = Get-ProcessClassification -Process $p
        if ($ccClasses -contains $cls) {
            $orphans += $p
            if (-not $tracked.ContainsKey($p.Pid)) {
                $tracked[$p.Pid] = $p
            }
        }
    }
}

# Build records
$records = foreach ($p in $tracked.Values) {
    $cls    = Get-ProcessClassification -Process $p
    $ageTs  = Get-ProcessAge -Process $p
    $orphan = Test-IsOrphan -Process $p -Snapshot $snap
    [PSCustomObject]@{
        Pid            = $p.Pid
        ParentPid      = $p.ParentPid
        Name           = $p.Name
        Classification = $cls
        Age            = $ageTs
        AgeText        = Format-Age $ageTs
        MemoryMB       = $p.MemoryMB
        IsOrphan       = $orphan
        CmdLine        = $p.CmdLine
        StartTime      = $p.StartTime
    }
}

if ($OrphansOnly) {
    $records = $records | Where-Object IsOrphan
}

# --- output -------------------------------------------------------------

if ($AsObject) {
    return $records
}

if ($roots.Count -eq 0 -and $orphans.Count -eq 0) {
    Write-Host ""
    Write-Host "No active Claude Code sessions and no orphans detected." -ForegroundColor Green
    Write-Host "(This is the post-restart baseline state.)"             -ForegroundColor DarkGray
    exit 0
}

if (-not $OrphansOnly) {
    foreach ($r in ($roots | Sort-Object Pid)) {
        Write-Host ""
        Write-Host ("=== Claude session: PID {0} ===" -f $r.Pid) -ForegroundColor Yellow
        Show-Tree -Root $r -Snapshot $snap -Indent ''
    }
}

if ($orphans.Count -gt 0) {
    Write-Host ""
    Write-Host "=== ORPHANS (parent dead -- candidates for cleanup) ===" -ForegroundColor Red
    foreach ($o in ($orphans | Sort-Object StartTime)) {
        Show-Line -Process $o -IsOrphan $true -Indent ''
    }
}

# Summary
$totalMem    = ($records | Measure-Object -Sum MemoryMB).Sum
$orphanCount = ($records | Where-Object IsOrphan).Count

Write-Host ""
Write-Host "=== SUMMARY ===" -ForegroundColor White
Write-Host ("  Active claude sessions:   {0}" -f $roots.Count)
Write-Host ("  Total tracked processes:  {0}" -f $records.Count)
Write-Host ("  Strict orphans:           {0}" -f $orphanCount) `
    -ForegroundColor $(if ($orphanCount -gt 0) { 'Red' } else { 'Green' })
Write-Host ("  Memory total:             {0:n1} MB" -f $totalMem)

if ($orphanCount -gt 0) {
    Write-Host ""
    Write-Host "  Run cleanup-orphans.ps1 -DryRun to preview cleanup." -ForegroundColor DarkYellow
}

exit 0
