@echo off
REM claude-jobbed.cmd -- cmd.exe shim into the PowerShell Job Object wrapper.
REM
REM cmd.exe cannot host a Win32 Job Object itself: the CreateJobObjectW /
REM SetInformationJobObject P/Invoke that arms KILL_ON_JOB_CLOSE lives in
REM claude-jobbed.ps1. So instead of reimplementing it in batch (which
REM cannot call the Win32 API), this shim re-execs into PowerShell running
REM the SAME wrapper. A cmd.exe user therefore gets the IDENTICAL STRONG
REM kernel-enforced guarantee as launching from PowerShell -- no weaker
REM tier, no second code path to keep in sync.
REM
REM   %~dp0  = directory of THIS .cmd (with trailing backslash), so the
REM            sibling .ps1 resolves no matter the caller's cwd.
REM   -NoProfile           : skip the user's PS profile (fast, predictable).
REM   -ExecutionPolicy Bypass : the user invoked this script directly; it is
REM                            the trust root, same convention v1.0.3 uses
REM                            for .ps1 shim host-routing (SpawnPlan).
REM   %*    = forward every argument verbatim.
REM
REM Usage:
REM   claude-jobbed.cmd               equivalent to plain `claude`
REM   claude-jobbed.cmd --version     any args forward transparently

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0claude-jobbed.ps1" %*
exit /b %ERRORLEVEL%
