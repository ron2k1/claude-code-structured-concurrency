# test-config-loader.ps1 -- RED-GREEN tests for ConfigLoader.ps1.
#
# 9 unit tests on:
#   - default config when no file exists
#   - malformed JSON falls back to defaults
#   - partial config merges with defaults
#   - Test-ReapPredicate decision order
#     * spare_classifications wins over kill_names
#     * spare_cmdline_patterns wins over kill_classifications
#     * not-orphan always returns false
#     * too-young always returns false
#     * kill_names fires when no spare matches
#
# Uses temp config files in $env:TEMP so the user's real ~/.reap/ is
# never touched.

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$here     = Split-Path -Parent $MyInvocation.MyCommand.Path
$skillDir = Split-Path -Parent $here
. (Join-Path $skillDir 'tools\lib\ConfigLoader.ps1')

Write-Host "test-config-loader.ps1 -- config + predicate tests"
Write-Host "==================================================="

$failed = 0

function Assert-Eq {
    param($Actual, $Expected, [string] $Label)
    if ($Actual -ceq $Expected) {
        Write-Host "[PASS] $Label" -ForegroundColor Green
    } else {
        Write-Host "[FAIL] $Label  (expected '$Expected', got '$Actual')" -ForegroundColor Red
        $script:failed++
    }
}

function New-FakeProc {
    param(
        [int]      $ProcId    = 100,
        [int]      $ParentPid = 1,
        [string]   $Name      = 'node.exe',
        [string]   $CmdLine   = '',
        [int]      $MemoryMB  = 50
    )
    [PSCustomObject]@{
        Pid = $ProcId; ParentPid = $ParentPid; Name = $Name
        CmdLine = $CmdLine; ExePath = ''
        StartTime = (Get-Date).AddMinutes(-10); MemoryMB = $MemoryMB
    }
}

function New-TempConfig {
    param([Parameter(Mandatory)] [string] $Json)
    $path = Join-Path $env:TEMP ("reap-test-{0}.json" -f ([guid]::NewGuid().ToString('N')))
    [IO.File]::WriteAllText($path, $Json)
    return $path
}

# --- Test 1: no file -> built-in safe defaults --------------------------
$missing = Join-Path $env:TEMP "reap-test-does-not-exist-$([guid]::NewGuid().ToString('N')).json"
$cfg1 = Get-ReapConfig -Path $missing
Assert-Eq $cfg1.source 'built-in-default' 'no config file -> built-in-default source'
Assert-Eq $cfg1.kill_classifications.Count 0 'built-in default has empty kill_classifications'
Assert-Eq $cfg1.min_age_seconds 30 'built-in default min_age_seconds=30'

# --- Test 2: malformed JSON -> falls back to defaults -------------------
$badPath = New-TempConfig -Json '{ this is not valid json'
$cfg2 = Get-ReapConfig -Path $badPath
Assert-Eq $cfg2.source 'built-in-default' 'malformed json -> falls back to built-in-default'
Remove-Item $badPath -ErrorAction SilentlyContinue

# --- Test 3: partial config merges with defaults ------------------------
$partialPath = New-TempConfig -Json '{ "min_age_seconds": 90, "kill_names": ["node.exe"] }'
$cfg3 = Get-ReapConfig -Path $partialPath
Assert-Eq $cfg3.min_age_seconds 90 'partial config: user min_age_seconds applied'
Assert-Eq ($cfg3.kill_names -join ',') 'node.exe' 'partial config: user kill_names applied'
Assert-Eq ($cfg3.spare_classifications -contains 'claude') $true 'partial config: default spare_classifications kept'
Remove-Item $partialPath -ErrorAction SilentlyContinue

# --- Test 4: spare_classifications wins over kill_names -----------------
# claude.exe by name is in kill_names, but classification 'claude' is in
# spare_classifications -- spare wins. This is the safety invariant.
$cfg4 = @{
    min_age_seconds = 30
    spare_classifications = @('claude','lsp','plugin-runtime','unknown')
    spare_cmdline_patterns = @()
    kill_classifications = @('mcp-stdio')
    kill_names = @('node.exe')
    custom_classifiers = @()
}
$proc4 = New-FakeProc -Name 'node.exe' -CmdLine 'claude'
$verdict4 = Test-ReapPredicate -Process $proc4 -Classification 'claude' `
            -Age ([TimeSpan]::FromMinutes(10)) -IsOrphan $true -Config $cfg4
Assert-Eq $verdict4 $false 'spare_classifications=claude wins over kill_names=node.exe'

# --- Test 5: spare_cmdline_patterns wins over kill_classifications -----
$cfg5 = @{
    min_age_seconds = 30
    spare_classifications = @('claude')
    spare_cmdline_patterns = @('lead-agent', 'in-house-tool')
    kill_classifications = @('mcp-stdio')
    kill_names = @()
    custom_classifiers = @()
}
$proc5 = New-FakeProc -Name 'node.exe' -CmdLine 'node lead-agent/lieutenant.js'
$verdict5 = Test-ReapPredicate -Process $proc5 -Classification 'mcp-stdio' `
            -Age ([TimeSpan]::FromMinutes(10)) -IsOrphan $true -Config $cfg5
Assert-Eq $verdict5 $false 'spare_cmdline_patterns wins over kill_classifications'

# --- Test 6: not orphan -> always returns false -------------------------
$cfg6 = @{
    min_age_seconds = 30
    spare_classifications = @()
    spare_cmdline_patterns = @()
    kill_classifications = @('mcp-stdio')
    kill_names = @('node.exe')
    custom_classifiers = @()
}
$proc6 = New-FakeProc -Name 'node.exe' -CmdLine 'node mcp'
$verdict6 = Test-ReapPredicate -Process $proc6 -Classification 'mcp-stdio' `
            -Age ([TimeSpan]::FromMinutes(10)) -IsOrphan $false -Config $cfg6
Assert-Eq $verdict6 $false 'not orphan -> always returns false'

# --- Test 7: too young -> always returns false --------------------------
$proc7 = New-FakeProc -Name 'node.exe' -CmdLine 'node mcp'
$verdict7 = Test-ReapPredicate -Process $proc7 -Classification 'mcp-stdio' `
            -Age ([TimeSpan]::FromSeconds(10)) -IsOrphan $true -Config $cfg6
Assert-Eq $verdict7 $false 'too young (10s < 30s min_age) -> always returns false'

# --- Test 8: kill_names fires when no spare matches ---------------------
$proc8 = New-FakeProc -Name 'node.exe' -CmdLine 'node my-foo'
$verdict8 = Test-ReapPredicate -Process $proc8 -Classification 'unknown' `
            -Age ([TimeSpan]::FromMinutes(10)) -IsOrphan $true -Config $cfg6
Assert-Eq $verdict8 $true 'kill_names=node.exe fires for unknown classification'

# --- Test 9: kill_classifications fires when no spare or kill_names ----
$cfg9 = @{
    min_age_seconds = 30
    spare_classifications = @('claude','lsp','plugin-runtime')
    spare_cmdline_patterns = @()
    kill_classifications = @('mcp-stdio','cmd-shim','npx-wrapper')
    kill_names = @()
    custom_classifiers = @()
}
$proc9 = New-FakeProc -Name 'node.exe' -CmdLine 'node @modelcontextprotocol/server-foo'
$verdict9 = Test-ReapPredicate -Process $proc9 -Classification 'mcp-stdio' `
            -Age ([TimeSpan]::FromMinutes(10)) -IsOrphan $true -Config $cfg9
Assert-Eq $verdict9 $true 'kill_classifications=mcp-stdio fires when no spare matches'

# --- summary ------------------------------------------------------------
Write-Host ""
if ($failed -eq 0) {
    Write-Host "ALL TESTS PASSED" -ForegroundColor Green
    exit 0
} else {
    Write-Host "$failed test(s) FAILED" -ForegroundColor Red
    exit 1
}
