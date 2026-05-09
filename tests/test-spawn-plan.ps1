# test-spawn-plan.ps1 -- RED-GREEN tests for SpawnPlan.ps1.
#
# Verifies that Get-ClaudeSpawnPlan returns the correct host process and
# prefix arguments for each shim type the wrapper might encounter.
#
# Regression test for the v1.0.2 -ShadowClaude bug:
#   Start-Process -NoNewWindow on a .cmd shim returns
#   ERROR_BAD_EXE_FORMAT ("%1 is not a valid Win32 application"),
#   silently breaking the wrapper because npm-installed `claude`
#   resolves to claude.cmd, not claude.exe.
#
# Pure unit tests -- no live processes, no PATH manipulation. The
# end-to-end live spawn path is exercised by the wrapper's actual usage.

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$here     = Split-Path -Parent $MyInvocation.MyCommand.Path
$skillDir = Split-Path -Parent $here
. (Join-Path $skillDir 'tools\lib\SpawnPlan.ps1')

Write-Host "test-spawn-plan.ps1 -- shim host-routing tests"
Write-Host "==================================================="

$failed = 0

function Assert-Eq {
    param($Actual, $Expected, [string] $Label)
    if ($Actual -ceq $Expected) {
        Write-Host "[PASS] $Label" -ForegroundColor Green
    } else {
        Write-Host "[FAIL] $Label" -ForegroundColor Red
        Write-Host "       expected: $Expected"
        Write-Host "       got     : $Actual"
        $script:failed++
    }
}

function Assert-ArrayEq {
    param([string[]] $Actual, [string[]] $Expected, [string] $Label)
    $a = ($Actual   -join '|')
    $e = ($Expected -join '|')
    Assert-Eq -Actual $a -Expected $e -Label $Label
}

# --- Test 1: .exe -> direct spawn ----------------------------------------
$plan = Get-ClaudeSpawnPlan -ClaudePath 'C:\Apps\claude.exe'
Assert-Eq      -Actual $plan.HostExe  -Expected 'C:\Apps\claude.exe' -Label '.exe HostExe is the path itself'
Assert-ArrayEq -Actual $plan.HostArgs -Expected @()                  -Label '.exe HostArgs is empty'

# --- Test 2: .cmd -> cmd.exe /c <path> -----------------------------------
$plan = Get-ClaudeSpawnPlan -ClaudePath 'C:\npm\claude.cmd'
Assert-Eq      -Actual $plan.HostExe  -Expected 'cmd.exe'                     -Label '.cmd HostExe is cmd.exe'
Assert-ArrayEq -Actual $plan.HostArgs -Expected @('/c', 'C:\npm\claude.cmd')  -Label '.cmd HostArgs prefixes /c then path'

# --- Test 3: .bat -> cmd.exe /c <path> -----------------------------------
$plan = Get-ClaudeSpawnPlan -ClaudePath 'C:\npm\claude.bat'
Assert-Eq      -Actual $plan.HostExe  -Expected 'cmd.exe'                     -Label '.bat HostExe is cmd.exe'
Assert-ArrayEq -Actual $plan.HostArgs -Expected @('/c', 'C:\npm\claude.bat')  -Label '.bat HostArgs prefixes /c then path'

# --- Test 4: .ps1 -> powershell.exe -File <path> -------------------------
$plan = Get-ClaudeSpawnPlan -ClaudePath 'C:\npm\claude.ps1'
Assert-Eq      -Actual $plan.HostExe  -Expected 'powershell.exe' -Label '.ps1 HostExe is powershell.exe'
Assert-ArrayEq -Actual $plan.HostArgs `
    -Expected @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', 'C:\npm\claude.ps1') `
    -Label '.ps1 HostArgs uses -NoProfile + -ExecutionPolicy Bypass + -File'

# --- Test 5: case-insensitive extension matching -------------------------
$plan = Get-ClaudeSpawnPlan -ClaudePath 'C:\npm\claude.CMD'
Assert-Eq      -Actual $plan.HostExe -Expected 'cmd.exe' -Label '.CMD (uppercase) routed via cmd.exe'

$plan = Get-ClaudeSpawnPlan -ClaudePath 'C:\npm\claude.PS1'
Assert-Eq      -Actual $plan.HostExe -Expected 'powershell.exe' -Label '.PS1 (uppercase) routed via powershell.exe'

# --- Test 6: unknown extension -> best-effort direct spawn ---------------
$plan = Get-ClaudeSpawnPlan -ClaudePath 'C:\Apps\claude'
Assert-Eq      -Actual $plan.HostExe  -Expected 'C:\Apps\claude' -Label 'no-extension path falls through to direct spawn'
Assert-ArrayEq -Actual $plan.HostArgs -Expected @()              -Label 'no-extension HostArgs is empty'

$plan = Get-ClaudeSpawnPlan -ClaudePath 'C:\Apps\claude.weird'
Assert-Eq      -Actual $plan.HostExe  -Expected 'C:\Apps\claude.weird' -Label 'unknown extension falls through to direct spawn'
Assert-ArrayEq -Actual $plan.HostArgs -Expected @()                    -Label 'unknown extension HostArgs is empty'

# --- Summary -------------------------------------------------------------
Write-Host ""
if ($failed -eq 0) {
    Write-Host "[OK] all spawn-plan tests passed" -ForegroundColor Green
    exit 0
} else {
    Write-Host ("[FAIL] {0} test(s) failed" -f $failed) -ForegroundColor Red
    exit 1
}
