# claude-jobbed.ps1 -- Layer 3: Win32 Job Object wrapper for claude.exe.
#
# Spawns claude.exe inside a kernel job configured with KILL_ON_JOB_CLOSE.
# When this wrapper exits -- graceful, Ctrl+C, crash, terminal-X-button,
# Task Manager End-Task, BSOD -- the kernel closes our handle to the job
# and reaps every member process. No application code path can leak.
#
# Usage:
#   .\claude-jobbed.ps1               # equivalent to plain `claude`
#   .\claude-jobbed.ps1 --version     # any args forward transparently
#   .\claude-jobbed.ps1 -p "prompt"   # ditto
#
# Best-effort caveat (v0.1.0): assigning the parent to the job happens
# AFTER Start-Process returns, so there is a ???1ms window in which
# claude.exe could spawn a child that escapes the job. Practically
# negligible for interactive use; v0.1.x will close it via
# CREATE_SUSPENDED + ResumeThread when it matters.

[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $ClaudeArgs
)

$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'lib\JobObject.ps1')
. (Join-Path $here 'lib\SpawnPlan.ps1')

# --- locate claude.exe --------------------------------------------------

function Find-ClaudeExe {
    # Extension preference: prefer a real PE binary when one exists, then
    # the most stable shim. .ps1 is last because the npm-shipped claude.ps1
    # hangs when stdin is a redirected pipe (interactive-mode autodetect),
    # while claude.cmd -> cmd.exe -> node.exe survives any I/O attachment.
    $extRank = @{ '.exe' = 0; '.cmd' = 1; '.bat' = 2; '.ps1' = 3 }

    # 1. PATH (Get-Command may return both shims; bias by extension)
    $matches = Get-Command claude -All -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandType -in 'Application', 'ExternalScript' }
    if ($matches) {
        $cmd = $matches | Sort-Object {
            $ext = ([System.IO.Path]::GetExtension($_.Source)).ToLowerInvariant()
            if ($extRank.ContainsKey($ext)) { $extRank[$ext] } else { 99 }
        } | Select-Object -First 1
        if ($cmd) { return $cmd.Source }
    }

    # 2. Common install locations
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\@anthropic-ai\claude-code\claude.exe'),
        (Join-Path $env:APPDATA      'npm\claude.cmd'),
        (Join-Path $env:APPDATA      'npm\claude.ps1'),
        (Join-Path $env:ProgramFiles 'nodejs\claude.cmd')
    )
    foreach ($c in $candidates) {
        if (Test-Path $c) { return (Resolve-Path $c).Path }
    }
    return $null
}

$claudePath = Find-ClaudeExe
if (-not $claudePath) {
    Write-Error "claude not found in PATH or common install locations. Install Claude Code first."
    exit 127
}

# --- create job (kill-on-close) -----------------------------------------

$job = New-CCJobObject

# --- spawn claude as a child, preserving console I/O --------------------
#
# Start-Process -NoNewWindow only accepts true PE binaries. npm-installed
# claude resolves to claude.cmd (a shim), and PowerShell .ps1 install
# paths exist too -- both must be host-routed via cmd.exe / powershell.exe
# or the OS loader returns ERROR_BAD_EXE_FORMAT ("%1 is not a valid Win32
# application"). The host process is what gets assigned to the job; on
# Win8+ children inherit the assignment, so KILL_ON_JOB_CLOSE still reaps
# the real node.exe child the shim launches.

$plan = Get-ClaudeSpawnPlan -ClaudePath $claudePath

$startParams = @{
    FilePath    = $plan.HostExe
    PassThru    = $true
    NoNewWindow = $true   # share console -> stdin/stdout/stderr forward
}

$allArgs = @($plan.HostArgs)
if ($ClaudeArgs -and $ClaudeArgs.Count -gt 0) {
    $allArgs += $ClaudeArgs
}
if ($allArgs.Count -gt 0) {
    $startParams.ArgumentList = $allArgs
}

$proc = Start-Process @startParams
if (-not $proc) {
    Write-Error "failed to start claude (Start-Process returned null)"
    Close-CCJobObject -Job $job
    exit 126
}

# --- assign claude to the job (children inherit on Win8+) ---------------

$assigned = Add-CCJobProcess -Job $job -ProcessId $proc.Id
if (-not $assigned) {
    Write-Warning ("could not assign claude (PID {0}) to job -- orphans on this run will NOT be reaped automatically" -f $proc.Id)
}

# --- wait, then exit (kernel reaps job on handle close) -----------------
#
# Important: do NOT call Close-CCJobObject explicitly here. We want the
# OS to close it for us when this script process terminates. That way,
# even if this wrapper is hard-killed (Task Manager End-Task), the job
# still reaps. Manual close would defeat the kernel-level guarantee.

$proc.WaitForExit()
exit $proc.ExitCode
