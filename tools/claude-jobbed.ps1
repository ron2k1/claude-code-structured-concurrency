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

# --- locate claude.exe --------------------------------------------------

function Find-ClaudeExe {
    # 1. PATH
    $cmd = Get-Command claude -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandType -in 'Application', 'ExternalScript' } |
        Select-Object -First 1
    if ($cmd) { return $cmd.Source }

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

$startParams = @{
    FilePath    = $claudePath
    PassThru    = $true
    NoNewWindow = $true   # share console -> stdin/stdout/stderr forward
}
if ($ClaudeArgs -and $ClaudeArgs.Count -gt 0) {
    $startParams.ArgumentList = $ClaudeArgs
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
