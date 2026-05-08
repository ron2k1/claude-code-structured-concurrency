# test-job-object.ps1 -- RED-GREEN proof that Win32 Job Object
# KILL_ON_JOB_CLOSE actually reaps members on this Windows build.
#
# Strategy:
#   1. Spawn `ping -n 60 127.0.0.1` (60-second sleeper, universally available)
#   2. Create a kill-on-close job and assign the ping process to it
#   3. Verify ping is still alive (sanity)
#   4. Close the job handle
#   5. Verify ping dies within 2 seconds
#
# Pass = we have working structured concurrency at the kernel level.
# Fail = either the P/Invoke is wrong or KILL_ON_JOB_CLOSE is not honored
#        on this system (extremely unlikely on Win10+).

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$here     = Split-Path -Parent $MyInvocation.MyCommand.Path
$skillDir = Split-Path -Parent $here
. (Join-Path $skillDir 'tools\lib\JobObject.ps1')

Write-Host "test-job-object.ps1 -- kill-on-close verification"
Write-Host "==================================================="

$child = $null
$job   = [IntPtr]::Zero
$exit  = 1

try {
    # 1. Spawn a long-running test process
    $child = Start-Process -FilePath 'ping' -ArgumentList '-n', '60', '127.0.0.1' `
        -PassThru -WindowStyle Hidden
    if (-not $child) { throw "Start-Process did not return a process object" }
    Write-Host "[setup] spawned child PID $($child.Id) (60s ping)"

    Start-Sleep -Milliseconds 200

    # 2. Create a kill-on-close job and assign the child
    $job = New-CCJobObject
    Write-Host ("[setup] created job (handle 0x{0:X})" -f $job.ToInt64())

    $ok = Add-CCJobProcess -Job $job -ProcessId $child.Id
    if (-not $ok) {
        Write-Host "[FAIL] Add-CCJobProcess returned false" -ForegroundColor Red
        exit 1
    }
    Write-Host "[setup] assigned PID $($child.Id) to job"

    # 3. Sanity: child still alive?
    $child.Refresh()
    if ($child.HasExited) {
        Write-Host "[FAIL] child died unexpectedly before kill-on-close test" -ForegroundColor Red
        exit 1
    }
    Write-Host "[check] child still alive -- good"

    # 4. Close the job handle (triggers kill-on-close)
    Close-CCJobObject -Job $job
    $job = [IntPtr]::Zero    # mark closed so finally-block doesn't double-close
    Write-Host "[act] closed job handle"

    # 5. Wait up to 2s for the kernel to terminate the child
    $deadline = (Get-Date).AddSeconds(2)
    while ((Get-Date) -lt $deadline -and -not $child.HasExited) {
        Start-Sleep -Milliseconds 50
        $child.Refresh()
    }

    if ($child.HasExited) {
        $elapsed = (Get-Date) - $deadline.AddSeconds(-2)
        Write-Host ("[PASS] child terminated within {0:n0}ms of job close" -f $elapsed.TotalMilliseconds) -ForegroundColor Green
        $exit = 0
    } else {
        Write-Host "[FAIL] child still alive 2s after job close -- KILL_ON_JOB_CLOSE NOT honored" -ForegroundColor Red
        $exit = 1
    }
} finally {
    # Belt-and-suspenders cleanup so we never leave a 60s ping running
    if ($child -and -not $child.HasExited) {
        try { Stop-Process -Id $child.Id -Force -ErrorAction SilentlyContinue } catch { }
    }
    if ($job -ne [IntPtr]::Zero) {
        try { Close-CCJobObject -Job $job } catch { }
    }
}

exit $exit
