using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using Microsoft.Win32.SafeHandles;

namespace ThinkFast.Bastion
{
    // Suspended launch closes the spawn-before-assignment race. Only this job
    // handle authorizes termination; PIDs are never termination authority.
    public sealed class OwnedProcess : IDisposable
    {
        private SafeFileHandle job;
        private bool closed;
        public Process Process { get; private set; }
        public int Id { get; private set; }
        public bool ClosureProven { get { return closed; } }

        [StructLayout(LayoutKind.Sequential)]
        private struct Security { public int Length; public IntPtr Descriptor; public int Inherit; }
        [StructLayout(LayoutKind.Sequential)]
        private struct Startup
        {
            public int Size; public IntPtr Reserved, Desktop, Title;
            public int X, Y, XSize, YSize, XChars, YChars, Fill, Flags;
            public short Show, ReservedSize; public IntPtr ReservedBytes, Input, Output, Error;
        }
        [StructLayout(LayoutKind.Sequential)]
        private struct ExtendedStartup { public Startup Startup; public IntPtr Attributes; }
        [StructLayout(LayoutKind.Sequential)]
        private struct ProcessInfo { public IntPtr Process, Thread; public uint Id, ThreadId; }
        [StructLayout(LayoutKind.Sequential)]
        private struct BasicLimit
        {
            public long ProcessTime, JobTime; public uint Flags;
            public UIntPtr MinWorkingSet, MaxWorkingSet; public uint ActiveLimit;
            public UIntPtr Affinity; public uint Priority, Scheduling;
        }
        [StructLayout(LayoutKind.Sequential)]
        private struct IoCounters { public ulong ReadOps, WriteOps, OtherOps, ReadBytes, WriteBytes, OtherBytes; }
        [StructLayout(LayoutKind.Sequential)]
        private struct Limits
        {
            public BasicLimit Basic; public IoCounters Io;
            public UIntPtr ProcessMemory, JobMemory, PeakProcessMemory, PeakJobMemory;
        }
        [StructLayout(LayoutKind.Sequential)]
        private struct Accounting
        {
            public long User, Kernel, PeriodUser, PeriodKernel;
            public uint Faults, Total, Active, Terminated;
        }
        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern SafeFileHandle CreateJobObjectW(IntPtr attributes, string name);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool SetInformationJobObject(SafeFileHandle job, int kind, ref Limits limits, int size);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool QueryInformationJobObject(SafeFileHandle job, int kind, out Accounting data, int size, IntPtr length);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool AssignProcessToJobObject(SafeFileHandle job, IntPtr process);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool TerminateJobObject(SafeFileHandle job, uint exit);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool IsProcessInJob(SafeFileHandle process, SafeFileHandle job, out bool result);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern SafeFileHandle OpenProcess(uint access, bool inherit, int pid);
        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern SafeFileHandle CreateFileW(string path, uint access, uint share, ref Security attributes, uint creation, uint flags, IntPtr template);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool InitializeProcThreadAttributeList(IntPtr list, int count, int flags, ref IntPtr size);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool UpdateProcThreadAttribute(IntPtr list, uint flags, IntPtr kind, IntPtr value, IntPtr size, IntPtr previous, IntPtr returned);
        [DllImport("kernel32.dll")]
        private static extern void DeleteProcThreadAttributeList(IntPtr list);
        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern bool CreateProcessW(string app, StringBuilder command, IntPtr processAttributes, IntPtr threadAttributes,
            bool inherit, uint flags, IntPtr environment, string directory, ref ExtendedStartup startup, out ProcessInfo process);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern uint ResumeThread(IntPtr thread);
        [DllImport("kernel32.dll")]
        private static extern bool TerminateProcess(IntPtr process, uint exit);
        [DllImport("kernel32.dll")]
        private static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
        [DllImport("kernel32.dll")]
        private static extern bool CloseHandle(IntPtr handle);

        private static Exception Failure(string operation)
        { return new InvalidOperationException("OWNED_JOB_" + operation + ": win32=" + Marshal.GetLastWin32Error()); }

        private static string Quote(string value)
        {
            var result = new StringBuilder("\""); int slashes = 0;
            foreach (char c in value)
            {
                if (c == '\\') { slashes++; continue; }
                result.Append('\\', c == '"' ? slashes * 2 + 1 : slashes);
                result.Append(c); slashes = 0;
            }
            result.Append('\\', slashes * 2); return result.Append('"').ToString();
        }

        public static OwnedProcess Launch(string application, string[] arguments)
        {
            if (!RuntimeInformation.IsOSPlatform(OSPlatform.Windows)) throw new PlatformNotSupportedException();
            var owner = new OwnedProcess();
            ProcessInfo native = default(ProcessInfo);
            IntPtr list = IntPtr.Zero, value = IntPtr.Zero;
            bool initialized = false;
            try
            {
                owner.job = CreateJobObjectW(IntPtr.Zero, null);
                if (owner.job.IsInvalid) throw Failure("CREATE");
                var limits = new Limits(); limits.Basic.Flags = 0x2000;
                if (!SetInformationJobObject(owner.job, 9, ref limits, Marshal.SizeOf<Limits>())) throw Failure("LIMIT");
                var security = new Security { Length = Marshal.SizeOf<Security>(), Inherit = 1 };
                using (var discard = CreateFileW("NUL", 0xC0000000, 3, ref security, 3, 0, IntPtr.Zero))
                {
                    if (discard.IsInvalid) throw Failure("DISCARD");
                    IntPtr size = IntPtr.Zero;
                    InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref size);
                    list = Marshal.AllocHGlobal(size);
                    if (!InitializeProcThreadAttributeList(list, 1, 0, ref size)) throw Failure("ATTRIBUTES");
                    initialized = true;
                    value = Marshal.AllocHGlobal(IntPtr.Size);
                    Marshal.WriteIntPtr(value, discard.DangerousGetHandle());
                    if (!UpdateProcThreadAttribute(list, 0, new IntPtr(0x20002), value, new IntPtr(IntPtr.Size), IntPtr.Zero, IntPtr.Zero))
                        throw Failure("INHERITANCE");
                    var startup = new ExtendedStartup();
                    startup.Startup.Size = Marshal.SizeOf<ExtendedStartup>();
                    startup.Startup.Flags = 0x100;
                    startup.Startup.Input = startup.Startup.Output = startup.Startup.Error = discard.DangerousGetHandle();
                    startup.Attributes = list;
                    var command = new StringBuilder(Quote(application));
                    foreach (string argument in arguments) command.Append(' ').Append(Quote(argument));
                    if (!CreateProcessW(application, command, IntPtr.Zero, IntPtr.Zero, true, 0x00080004 | 0x08000000,
                        IntPtr.Zero, Directory.GetCurrentDirectory(), ref startup, out native)) throw Failure("LAUNCH");
                    if (!AssignProcessToJobObject(owner.job, native.Process)) throw Failure("ASSIGN");
                    owner.Id = checked((int)native.Id);
                    owner.Process = Process.GetProcessById(owner.Id);
                    var retainedHandle = owner.Process.SafeHandle;
                    if (ResumeThread(native.Thread) == uint.MaxValue) throw Failure("RESUME");
                    return owner;
                }
            }
            catch (Exception primary)
            {
                bool closureUnknown = native.Process != IntPtr.Zero &&
                    (!TerminateProcess(native.Process, 1) || WaitForSingleObject(native.Process, 5000) != 0);
                if (owner.job != null) owner.job.Dispose();
                if (owner.Process != null) owner.Process.Dispose();
                if (closureUnknown) throw new InvalidOperationException(
                    "OWNED_JOB_LAUNCH_CLOSURE_UNKNOWN: suspended owned root termination was not proved.", primary);
                throw;
            }
            finally
            {
                if (native.Thread != IntPtr.Zero) CloseHandle(native.Thread);
                if (native.Process != IntPtr.Zero) CloseHandle(native.Process);
                if (initialized) DeleteProcThreadAttributeList(list);
                if (list != IntPtr.Zero) Marshal.FreeHGlobal(list);
                if (value != IntPtr.Zero) Marshal.FreeHGlobal(value);
            }
        }

        public uint ActiveCount()
        {
            if (closed) return 0;
            Accounting data;
            if (!QueryInformationJobObject(job, 1, out data, Marshal.SizeOf<Accounting>(), IntPtr.Zero)) throw Failure("QUERY");
            return data.Active;
        }

        public bool ContainsPid(int pid)
        {
            if (closed || pid <= 0) return false;
            using (var process = OpenProcess(0x1000, false, pid))
            {
                if (process.IsInvalid) return false;
                bool contained;
                if (!IsProcessInJob(process, job, out contained)) throw Failure("MEMBERSHIP");
                return contained;
            }
        }

        public void Stop(int timeoutMilliseconds)
        {
            if (closed) return;
            if (!TerminateJobObject(job, 1)) throw Failure("TERMINATE");
            var watch = Stopwatch.StartNew();
            while (ActiveCount() != 0)
            {
                if (watch.ElapsedMilliseconds >= timeoutMilliseconds)
                    throw new InvalidOperationException("OWNED_JOB_CLOSURE_UNKNOWN: active owned processes remain.");
                Thread.Sleep(20);
            }
            closed = true;
            job.Dispose();
        }

        public void Dispose() { Stop(5000); Process.Dispose(); }
    }
}
