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

# Arguments come from plain $args, not a param block. A [Parameter()] attribute
# makes this an advanced script, and then claude's own flags bind to
# PowerShell's common parameters: -p is ambiguous between -ProgressAction and
# -PipelineVariable on pwsh 7.4+ and fails, -v turns on -Verbose, -d -Debug.
[string[]] $ClaudeArgs = $args

$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'lib\JobObject.ps1')
. (Join-Path $here 'lib\SpawnPlan.ps1')

# --- locate claude.exe --------------------------------------------------
#
# First hit wins:
#   a. a real `claude` application on PATH. -CommandType Application skips
#      the profile's `claude` function, so the wrapper never finds itself.
#   b. the native installer's %USERPROFILE%\.local\bin\claude.exe
#   c. npm's %APPDATA%\npm\claude.cmd
#      (then the older install locations this wrapper has always probed)
#   d. the newest claude.exe bundled with the Claude desktop app, under
#      %LOCALAPPDATA%\Packages\Claude_*\LocalCache\Roaming\Claude\claude-code\<version>\
# If none of them exists, the whole lookup is retried for up to ~5 s before
# giving up: `npm install -g` deletes the shim and writes it back, so a
# launch during an update can briefly see no claude at all.

$ClaudeRetryMs     = 5000
$ClaudeRetryStepMs = 500
$ClaudeReinstall   = 'irm https://claude.ai/install.ps1 | iex'

function Get-ClaudeCandidatePath {
    # b and c, then the older locations. Native-installer paths hold a real
    # PE binary and, unlike npm shims, are not deleted-then-recreated
    # mid-update (npm install -g leaves a window where no shim exists).
    @(
        (Join-Path $env:USERPROFILE  '.local\bin\claude.exe'),
        (Join-Path $env:APPDATA      'npm\claude.cmd'),
        (Join-Path $env:USERPROFILE  '.claude\local\claude.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\@anthropic-ai\claude-code\claude.exe'),
        (Join-Path $env:APPDATA      'npm\claude.ps1'),
        (Join-Path $env:ProgramFiles 'nodejs\claude.cmd')
    )
}

function Find-ClaudeExe {
    # Extension preference: prefer a real PE binary when one exists, then
    # the most stable shim. .ps1 is last because the npm-shipped claude.ps1
    # hangs when stdin is a redirected pipe (interactive-mode autodetect),
    # while claude.cmd -> cmd.exe -> node.exe survives any I/O attachment.
    $extRank = @{ '.exe' = 0; '.cmd' = 1; '.bat' = 2; '.ps1' = 3 }

    # a. PATH. Applications only, never the `claude` function or an alias.
    $onPath = Get-Command claude -CommandType Application -All -ErrorAction SilentlyContinue
    if ($onPath) {
        $cmd = $onPath | Sort-Object {
            $ext = ([System.IO.Path]::GetExtension($_.Source)).ToLowerInvariant()
            if ($extRank.ContainsKey($ext)) { $extRank[$ext] } else { 99 }
        } | Select-Object -First 1
        if ($cmd) { return $cmd.Source }
    }

    # b, c and the older locations
    foreach ($c in (Get-ClaudeCandidatePath)) {
        if (Test-Path -LiteralPath $c) { return (Resolve-Path -LiteralPath $c).Path }
    }
    return $null
}

function Find-ClaudeDesktopExe {
    # d. The desktop app keeps one folder per bundled CLI version. Compare
    # them as [version] so 2.1.100 beats 2.1.99, and skip any folder whose
    # name is not a version.
    $packages = Join-Path $env:LOCALAPPDATA 'Packages'
    if (-not (Test-Path -LiteralPath $packages)) { return $null }
    $best = $null
    foreach ($pkg in @(Get-ChildItem -LiteralPath $packages -Directory -Filter 'Claude_*' -ErrorAction SilentlyContinue)) {
        $root = Join-Path $pkg.FullName 'LocalCache\Roaming\Claude\claude-code'
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($dir in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
            $ver = $null
            if (-not [version]::TryParse($dir.Name, [ref] $ver)) { continue }
            $exe = Join-Path $dir.FullName 'claude.exe'
            if (-not (Test-Path -LiteralPath $exe)) { continue }
            if (($null -eq $best) -or ($ver -gt $best.Version)) {
                $best = @{ Path = $exe; Version = $ver }
            }
        }
    }
    return $best
}

function Write-WrapperNote {
    # stderr, so `claude -p ... > out.txt` keeps clean output. The colour is
    # best effort: there is no console colour to set when stderr is redirected.
    param([string] $Text, [ConsoleColor] $Color)
    $old = $null
    try { $old = [Console]::ForegroundColor; [Console]::ForegroundColor = $Color } catch { $old = $null }
    [Console]::Error.WriteLine($Text)
    if ($null -ne $old) { try { [Console]::ForegroundColor = $old } catch { } }
}

$claudePath = $null
$desktop = $null
$clock = [System.Diagnostics.Stopwatch]::StartNew()
while ($true) {
    $claudePath = Find-ClaudeExe
    if ($claudePath) { break }
    $desktop = Find-ClaudeDesktopExe
    if ($desktop) { $claudePath = $desktop.Path; break }
    if ($clock.ElapsedMilliseconds -ge $ClaudeRetryMs) { break }
    Start-Sleep -Milliseconds $ClaudeRetryStepMs
}

if (-not $claudePath) {
    Write-WrapperNote 'claude-jobbed: claude not found. Checked, in order:' Red
    Write-WrapperNote '  PATH (Get-Command claude -CommandType Application)' Red
    foreach ($c in (Get-ClaudeCandidatePath)) { Write-WrapperNote ('  ' + $c) Red }
    Write-WrapperNote ('  ' + (Join-Path $env:LOCALAPPDATA 'Packages\Claude_*\LocalCache\Roaming\Claude\claude-code\<version>\claude.exe')) Red
    Write-WrapperNote ('Rechecked for {0} s in case an npm update had removed the shim. Reinstall with: {1}' -f ($ClaudeRetryMs / 1000), $ClaudeReinstall) Red
    exit 127
}

if ($desktop) {
    Write-WrapperNote ('claude-jobbed: standalone Claude Code CLI not found. Using the copy bundled with the Claude desktop app ({0}). Reinstall: {1}' -f $desktop.Version, $ClaudeReinstall) Yellow
}

# --- bypass: CLAUDE_NO_WRAPPER skips the Job Object ---------------------
#
# Runs the resolved binary directly, with no job, so orphans on that run
# are NOT reaped. Meant for debugging the wrapper itself. EAP goes back to
# Continue first: under Stop, Windows PowerShell 5.1 can turn a line of
# claude's stderr into a terminating error.

if ($env:CLAUDE_NO_WRAPPER) {
    $ErrorActionPreference = 'Continue'
    & $claudePath @ClaudeArgs
    exit $LASTEXITCODE
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

# Start-Process joins an -ArgumentList array with bare spaces, so
# `claude -p "two words"` used to reach claude as -p, two, words. The command
# line is built here instead, each argument quoted the way CommandLineToArgvW
# (and node, and bun) split it back. A shim runs as cmd.exe /s /c "<line>":
# /s makes cmd strip exactly the outer pair of quotes, so a quoted shim path
# and quoted arguments survive, and & | < > ^ ( ) stay literal inside quotes.
function ConvertTo-CommandLineArg([string] $Arg) {
    if ($Arg.Length -gt 0 -and $Arg -notmatch '[\s"&|<>^()]') { return $Arg }
    # backslashes double only where they end up before a quote
    '"' + ($Arg -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

$quotedArgs = @($ClaudeArgs | ForEach-Object { ConvertTo-CommandLineArg $_ })
if ($plan.HostExe -eq 'cmd.exe') {
    # Get-ClaudeSpawnPlan's cmd plan is /c <shim>; the shim is $claudePath
    $line = '/s /c "' + ((@(ConvertTo-CommandLineArg $claudePath) + $quotedArgs) -join ' ') + '"'
} else {
    $line = (@($plan.HostArgs | ForEach-Object { ConvertTo-CommandLineArg $_ }) + $quotedArgs) -join ' '
}
if ($line) {
    $startParams.ArgumentList = $line
}

$proc = Start-Process @startParams
if (-not $proc) {
    Write-Error "failed to start claude (Start-Process returned null)"
    Close-CCJobObject -Job $job
    exit 126
}
# Windows PowerShell 5.1: a Process from Start-Process -PassThru has no
# ExitCode unless its handle was opened while it ran, and the final
# `exit $proc.ExitCode` came out 0. Reading .Handle opens and keeps it.
$null = $proc.Handle

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
