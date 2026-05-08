# JobObject.ps1 -- Win32 Job Object wrapper for kill-on-close
#
# Wraps the kernel primitive that gives us structured concurrency at the
# process-tree level: when the wrapper that holds the job handle exits
# (graceful, crash, BSOD, anything), the kernel terminates every process
# in the job. Used by Chrome, Edge, VS Code; underdocumented in Node land.
#
# This file exposes three functions:
#   New-CCJobObject       -> [IntPtr]  : create a job with KILL_ON_JOB_CLOSE
#   Add-CCJobProcess      -> [bool]    : assign a PID to the job
#   Close-CCJobObject     -> [void]    : (test-only) close handle to trigger kill
#
# Dot-source this file. Type definition is idempotent (guarded against re-load).

if (-not ([System.Management.Automation.PSTypeName]'CCReap.JobObject').Type) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace CCReap {
    public static class JobObject {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern IntPtr CreateJobObjectW(IntPtr lpJobAttributes, string lpName);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool SetInformationJobObject(
            IntPtr hJob,
            int JobObjectInformationClass,
            IntPtr lpJobObjectInformation,
            uint cbJobObjectInformationLength);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool AssignProcessToJobObject(IntPtr hJob, IntPtr hProcess);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern IntPtr OpenProcess(uint dwDesiredAccess, bool bInheritHandle, uint dwProcessId);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool CloseHandle(IntPtr hObject);

        [StructLayout(LayoutKind.Sequential)]
        public struct JOBOBJECT_BASIC_LIMIT_INFORMATION {
            public Int64  PerProcessUserTimeLimit;
            public Int64  PerJobUserTimeLimit;
            public UInt32 LimitFlags;
            public IntPtr MinimumWorkingSetSize;
            public IntPtr MaximumWorkingSetSize;
            public UInt32 ActiveProcessLimit;
            public IntPtr Affinity;
            public UInt32 PriorityClass;
            public UInt32 SchedulingClass;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct IO_COUNTERS {
            public UInt64 ReadOperationCount;
            public UInt64 WriteOperationCount;
            public UInt64 OtherOperationCount;
            public UInt64 ReadTransferCount;
            public UInt64 WriteTransferCount;
            public UInt64 OtherTransferCount;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION {
            public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
            public IO_COUNTERS                       IoInfo;
            public IntPtr                            ProcessMemoryLimit;
            public IntPtr                            JobMemoryLimit;
            public IntPtr                            PeakProcessMemoryUsed;
            public IntPtr                            PeakJobMemoryUsed;
        }

        public const int  JobObjectExtendedLimitInformation = 9;
        public const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x00002000;
        public const uint PROCESS_TERMINATE                  = 0x0001;
        public const uint PROCESS_SET_QUOTA                  = 0x0100;
        public const uint PROCESS_QUERY_INFORMATION          = 0x0400;

        // Create a job with KILL_ON_JOB_CLOSE. Throws Win32Exception on failure.
        public static IntPtr CreateKillOnCloseJob() {
            IntPtr job = CreateJobObjectW(IntPtr.Zero, null);
            if (job == IntPtr.Zero) {
                int err = Marshal.GetLastWin32Error();
                throw new System.ComponentModel.Win32Exception(err, "CreateJobObjectW failed");
            }

            JOBOBJECT_EXTENDED_LIMIT_INFORMATION info = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
            info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;

            int    len = Marshal.SizeOf(info);
            IntPtr ptr = Marshal.AllocHGlobal(len);
            try {
                Marshal.StructureToPtr(info, ptr, false);
                if (!SetInformationJobObject(job, JobObjectExtendedLimitInformation, ptr, (uint)len)) {
                    int err = Marshal.GetLastWin32Error();
                    CloseHandle(job);
                    throw new System.ComponentModel.Win32Exception(err, "SetInformationJobObject failed");
                }
            } finally {
                Marshal.FreeHGlobal(ptr);
            }
            return job;
        }

        // Assign PID to job. Returns true on success, false if OpenProcess or
        // AssignProcessToJobObject failed (caller can read GetLastWin32Error).
        public static bool AssignPidToJob(IntPtr job, int pid) {
            IntPtr proc = OpenProcess(
                PROCESS_TERMINATE | PROCESS_SET_QUOTA | PROCESS_QUERY_INFORMATION,
                false,
                (uint)pid);
            if (proc == IntPtr.Zero) {
                return false;
            }
            try {
                return AssignProcessToJobObject(job, proc);
            } finally {
                CloseHandle(proc);
            }
        }
    }
}
'@
}

# --- PowerShell wrapper functions ------------------------------------------

function New-CCJobObject {
    <#
    .SYNOPSIS
    Create a Win32 Job Object configured to terminate all member processes
    when the last handle to the job is closed.

    .OUTPUTS
    [IntPtr] handle to the job. The caller is responsible for keeping the
    handle alive; when the powershell process holding it exits, the kernel
    closes the handle and reaps the job.
    #>
    [CmdletBinding()]
    [OutputType([IntPtr])]
    param()
    return [CCReap.JobObject]::CreateKillOnCloseJob()
}

function Add-CCJobProcess {
    <#
    .SYNOPSIS
    Assign a process (by PID) to a job. Children spawned by the process
    after assignment are automatically inherited into the job (Windows
    8+ behavior).

    .OUTPUTS
    [bool] true on success, false on failure (PID may be invalid, gone,
    or in another non-nestable job on pre-Windows-8 systems).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [IntPtr] $Job,
        [Parameter(Mandatory)] [int]    $ProcessId
    )
    $ok = [CCReap.JobObject]::AssignPidToJob($Job, $ProcessId)
    if (-not $ok) {
        $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
        Write-Verbose "AssignProcessToJobObject failed for PID $ProcessId. Win32 error: $err"
    }
    return $ok
}

function Close-CCJobObject {
    <#
    .SYNOPSIS
    Close the job handle. With KILL_ON_JOB_CLOSE set, this terminates every
    process in the job. Used in tests to trigger reaping deterministically.
    Production code does NOT call this -- letting the wrapper exit naturally
    closes the handle for us.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [IntPtr] $Job
    )
    [void] [CCReap.JobObject]::CloseHandle($Job)
}
