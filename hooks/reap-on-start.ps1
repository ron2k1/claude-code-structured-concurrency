# reap-on-start.ps1 -- SessionStart hook handler.
#
# Wired from ~/.claude/settings.json, runs once when a new Claude Code
# session begins. Calls cleanup-orphans.ps1 -Force to reap any leftovers
# from the prior (presumably ungraceful) session.
#
# Contract:
#   - 10s timeout (set in settings.json hook entry)
#   - Logs to ~/.claude/hooks/reap.log
#   - NEVER throws -- failures are swallowed so they cannot block CC startup.
#
# The cleanup-orphans.ps1 it invokes will be a no-op until Ronil writes
# the IsKillable() predicate. Until then, this hook just produces a
# "candidates=N skipped=N" line per session start, which is fine.

$ErrorActionPreference = 'Continue'

$logPath = Join-Path $env:USERPROFILE '.claude\hooks\reap.log'

function Write-HookLog {
    param([string] $Msg)
    try {
        $dir = Split-Path -Parent $logPath
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $ts = (Get-Date).ToString('s')
        Add-Content -Path $logPath -Value "$ts  hook  $Msg" -Encoding utf8
    } catch {
        # Even logging failure must not block CC. Swallow.
    }
}

try {
    $here     = Split-Path -Parent $MyInvocation.MyCommand.Path  # hooks/
    $skillDir = Split-Path -Parent $here                          # skill root
    $cleanup  = Join-Path $skillDir 'tools\cleanup-orphans.ps1'

    if (-not (Test-Path $cleanup)) {
        Write-HookLog "skill not found at expected path; cleanup=$cleanup"
        exit 0
    }

    Write-HookLog "starting cleanup pass (cleanup=$cleanup)"
    & $cleanup -Force *>&1 | Out-Null
    Write-HookLog "cleanup pass returned exitcode=$LASTEXITCODE"
} catch {
    Write-HookLog "hook-error: $($_.Exception.Message)"
}

# Always exit 0 -- hook failure must not block Claude Code startup.
exit 0
