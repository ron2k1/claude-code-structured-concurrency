# test-orphan-detect.ps1 -- RED-GREEN tests for ProcessTree.ps1.
#
# Uses synthetic snapshot hashtables so the tests are fully deterministic
# and don't depend on the live process table. Covers:
#   - strict orphan (parent PID not in snapshot)
#   - live parent (older than child) -> not orphan
#   - PID-reuse (apparent parent newer than child) -> orphan
#   - classification heuristics (mcp-stdio, claude)
#   - descendant tree walk (excludes unrelated processes)
#
# We deliberately do NOT plant a real orphan in the live process table --
# doing so on Windows requires P/Invoke (DETACHED_PROCESS), and the unit
# tests for the analysis library don't need it. The Layer-3 wrapper test
# (test-job-object.ps1) covers the live-process path.

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$here     = Split-Path -Parent $MyInvocation.MyCommand.Path
$skillDir = Split-Path -Parent $here
. (Join-Path $skillDir 'tools\lib\ProcessTree.ps1')

Write-Host "test-orphan-detect.ps1 -- analysis library tests"
Write-Host "==================================================="

$failed = 0

function New-FakeProc {
    param(
        [int]      $ProcId,
        [int]      $ParentPid,
        [string]   $Name,
        [string]   $CmdLine    = '',
        [DateTime] $StartTime  = (Get-Date),
        [int]      $MemoryMB   = 50
    )
    [PSCustomObject]@{
        Pid       = $ProcId
        ParentPid = $ParentPid
        Name      = $Name
        CmdLine   = $CmdLine
        ExePath   = ''
        StartTime = $StartTime
        MemoryMB  = $MemoryMB
    }
}

function Assert-Eq {
    param($Actual, $Expected, [string] $Label)
    if ($Actual -ceq $Expected) {
        Write-Host "[PASS] $Label" -ForegroundColor Green
    } else {
        Write-Host "[FAIL] $Label  (expected '$Expected', got '$Actual')" -ForegroundColor Red
        $script:failed++
    }
}

# --- Test 1: missing-parent -> orphan ------------------------------------
$snap1 = @{
    100 = New-FakeProc -ProcId 100 -ParentPid 99999 -Name 'node.exe' `
                       -StartTime (Get-Date).AddMinutes(-5)
}
Assert-Eq (Test-IsOrphan -Process $snap1[100] -Snapshot $snap1) $true `
          'missing-parent is orphan'

# --- Test 2: live parent older than child -> not orphan ------------------
$snap2 = @{
    99  = New-FakeProc -ProcId 99  -ParentPid 1  -Name 'cmd.exe' `
                       -StartTime (Get-Date).AddMinutes(-10)
    100 = New-FakeProc -ProcId 100 -ParentPid 99 -Name 'node.exe' `
                       -StartTime (Get-Date).AddMinutes(-5)
}
Assert-Eq (Test-IsOrphan -Process $snap2[100] -Snapshot $snap2) $false `
          'live parent (older) is not orphan'

# --- Test 3: PID-reuse (apparent parent newer than child) -> orphan ------
$snap3 = @{
    99  = New-FakeProc -ProcId 99  -ParentPid 1  -Name 'reused.exe' `
                       -StartTime (Get-Date).AddMinutes(-1)
    100 = New-FakeProc -ProcId 100 -ParentPid 99 -Name 'node.exe' `
                       -StartTime (Get-Date).AddMinutes(-5)
}
Assert-Eq (Test-IsOrphan -Process $snap3[100] -Snapshot $snap3) $true `
          'PID-reused parent (newer than child) is orphan'

# --- Test 4: classification -- modelcontextprotocol -> mcp-stdio ----------
$proc4 = New-FakeProc -ProcId 200 -ParentPid 1 -Name 'node.exe' `
            -CmdLine 'node @modelcontextprotocol/server-foo'
Assert-Eq (Get-ProcessClassification -Process $proc4) 'mcp-stdio' `
          'classification: @modelcontextprotocol -> mcp-stdio'

# --- Test 5: classification -- anthropic-ai/claude-code -> claude ---------
$proc5 = New-FakeProc -ProcId 300 -ParentPid 1 -Name 'node.exe' `
            -CmdLine 'node C:\path\anthropic-ai\claude-code\cli.js'
Assert-Eq (Get-ProcessClassification -Process $proc5) 'claude' `
          'classification: anthropic-ai/claude-code -> claude'

# --- Test 6: classification -- pyright LSP -------------------------------
$proc6 = New-FakeProc -ProcId 400 -ParentPid 1 -Name 'python.exe' `
            -CmdLine 'python -m pyright'
Assert-Eq (Get-ProcessClassification -Process $proc6) 'lsp' `
          'classification: pyright python -> lsp'

# --- Test 7: descendant walk includes 1->2->3 + 1->4, excludes unrelated 5 -
$snap7 = @{
    1 = New-FakeProc -ProcId 1 -ParentPid 0 -Name 'claude.exe'  `
                     -CmdLine 'claude' -StartTime (Get-Date).AddMinutes(-10)
    2 = New-FakeProc -ProcId 2 -ParentPid 1 -Name 'cmd.exe'     `
                     -CmdLine 'cmd /c npx mcp' -StartTime (Get-Date).AddMinutes(-9)
    3 = New-FakeProc -ProcId 3 -ParentPid 2 -Name 'node.exe'    `
                     -CmdLine 'node mcp' -StartTime (Get-Date).AddMinutes(-9)
    4 = New-FakeProc -ProcId 4 -ParentPid 1 -Name 'node.exe'    `
                     -CmdLine 'node lsp' -StartTime (Get-Date).AddMinutes(-9)
    5 = New-FakeProc -ProcId 5 -ParentPid 999 -Name 'firefox.exe'
}
$desc     = Get-CCDescendants -RootPid 1 -Snapshot $snap7
$descPids = ($desc | ForEach-Object { $_.Pid } | Sort-Object) -join ','
Assert-Eq $descPids '1,2,3,4' 'descendant walk: claude -> cmd -> node, claude -> node (skip unrelated)'

# --- Test 8: Find-ClaudeRoots picks the claude proc ---------------------
$roots    = Find-ClaudeRoots -Snapshot $snap7
$rootPids = ($roots | ForEach-Object { $_.Pid } | Sort-Object) -join ','
Assert-Eq $rootPids '1' 'Find-ClaudeRoots returns only the claude process'

# --- Test 9: Get-ProcessAge returns Zero for null StartTime -------------
$proc9 = [PSCustomObject]@{
    Pid = 999; ParentPid = 1; Name = 'zombie.exe'
    CmdLine = ''; ExePath = ''; StartTime = $null; MemoryMB = 0
}
Assert-Eq (Get-ProcessAge -Process $proc9) ([TimeSpan]::Zero) `
          'Get-ProcessAge handles null StartTime (returns Zero)'

# --- summary ------------------------------------------------------------
Write-Host ""
if ($failed -eq 0) {
    Write-Host "ALL TESTS PASSED" -ForegroundColor Green
    exit 0
} else {
    Write-Host "$failed test(s) FAILED" -ForegroundColor Red
    exit 1
}
