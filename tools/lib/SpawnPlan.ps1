# SpawnPlan.ps1 -- host-routing for the claude binary or shim.
#
# Start-Process -NoNewWindow only accepts true PE binaries. npm-installed
# CLIs ship as a .cmd / .bat / .ps1 shim plus a .js entry; handing the
# shim to Start-Process directly returns ERROR_BAD_EXE_FORMAT
# ("%1 is not a valid Win32 application"). This helper picks the right
# host process so the spawn succeeds while still letting the Job Object
# inherit through to the real node.exe child the shim launches.
#
# The host process is what the wrapper assigns to the Job Object; on
# Win8+ children inherit that assignment automatically, so the
# KILL_ON_JOB_CLOSE guarantee still reaps the entire tree.
#
# Pure function -- no side effects, easy to unit-test in isolation.

function Get-ClaudeSpawnPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $ClaudePath
    )

    $ext = ([System.IO.Path]::GetExtension($ClaudePath)).ToLowerInvariant()

    switch ($ext) {
        '.cmd' {
            return @{
                HostExe  = 'cmd.exe'
                HostArgs = @('/c', $ClaudePath)
            }
        }
        '.bat' {
            return @{
                HostExe  = 'cmd.exe'
                HostArgs = @('/c', $ClaudePath)
            }
        }
        '.ps1' {
            return @{
                HostExe  = 'powershell.exe'
                HostArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ClaudePath)
            }
        }
        default {
            # .exe or unknown: best-effort direct spawn. If it isn't a real
            # PE binary, Start-Process will raise the same loader error the
            # caller used to see -- but at least we tried the documented
            # install path (claude.exe under LOCALAPPDATA\Programs).
            return @{
                HostExe  = $ClaudePath
                HostArgs = @()
            }
        }
    }
}
