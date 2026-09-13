//! Win32 declarations the bridge needs that std.os.windows lacks.

const std = @import("std");
const windows = std.os.windows;

pub const FILE_FLAG_FIRST_PIPE_INSTANCE: windows.DWORD = 0x00080000;

pub extern "kernel32" fn CreatePipe(
    hReadPipe: *windows.HANDLE,
    hWritePipe: *windows.HANDLE,
    lpPipeAttributes: ?*const windows.SECURITY_ATTRIBUTES,
    nSize: windows.DWORD,
) callconv(.winapi) windows.BOOL;

pub extern "kernel32" fn CreateJobObjectW(
    lpJobAttributes: ?*windows.SECURITY_ATTRIBUTES,
    lpName: ?[*:0]const u16,
) callconv(.winapi) ?windows.HANDLE;

pub extern "kernel32" fn SetInformationJobObject(
    hJob: windows.HANDLE,
    JobObjectInformationClass: windows.DWORD,
    lpJobObjectInformation: windows.LPVOID,
    cbJobObjectInformationLength: windows.DWORD,
) callconv(.winapi) windows.BOOL;

pub extern "kernel32" fn AssignProcessToJobObject(
    hJob: windows.HANDLE,
    hProcess: windows.HANDLE,
) callconv(.winapi) windows.BOOL;

pub const JOBOBJECT_BASIC_LIMIT_INFORMATION = extern struct {
    PerProcessUserTimeLimit: windows.LARGE_INTEGER,
    PerJobUserTimeLimit: windows.LARGE_INTEGER,
    LimitFlags: windows.DWORD,
    MinimumWorkingSetSize: windows.SIZE_T,
    MaximumWorkingSetSize: windows.SIZE_T,
    ActiveProcessLimit: windows.DWORD,
    Affinity: windows.ULONG_PTR,
    PriorityClass: windows.DWORD,
    SchedulingClass: windows.DWORD,
};

pub const IO_COUNTERS = extern struct {
    ReadOperationCount: windows.ULONGLONG,
    WriteOperationCount: windows.ULONGLONG,
    OtherOperationCount: windows.ULONGLONG,
    ReadTransferCount: windows.ULONGLONG,
    WriteTransferCount: windows.ULONGLONG,
    OtherTransferCount: windows.ULONGLONG,
};

pub const JOBOBJECT_EXTENDED_LIMIT_INFORMATION = extern struct {
    BasicLimitInformation: JOBOBJECT_BASIC_LIMIT_INFORMATION,
    IoInfo: IO_COUNTERS,
    ProcessMemoryLimit: windows.SIZE_T,
    JobMemoryLimit: windows.SIZE_T,
    PeakProcessMemoryUsed: windows.SIZE_T,
    PeakJobMemoryUsed: windows.SIZE_T,
};

/// JobObjectExtendedLimitInformation
pub const JobObjectExtendedLimitInformation: windows.DWORD = 9;
pub const JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE: windows.DWORD = 0x00002000;
