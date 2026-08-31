using System;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;

namespace GDJobsystem
{
    /// <summary>
    /// P/Invoke declarations for the GDJS C export layer, EntJoy-style:
    /// all native entry points are held as `delegate* unmanaged[Cdecl]`
    /// function pointers (resolved once via GetProcAddress) and called
    /// directly — no delegate allocation, no Marshal.GetDelegateForFunctionPointer.
    /// </summary>
    internal static unsafe class JobSystemNative
    {
        // GDJS exports
        internal static delegate* unmanaged[Cdecl]<int, void> Initialize;
        internal static delegate* unmanaged[Cdecl]<void> Shutdown;
        internal static delegate* unmanaged[Cdecl]<int> GetWorkerCount;
        internal static delegate* unmanaged[Cdecl]<delegate* unmanaged[Cdecl]<IntPtr, void>, IntPtr, delegate* unmanaged[Cdecl]<IntPtr, void>, IntPtr, IntPtr> Schedule;
        internal static delegate* unmanaged[Cdecl]<delegate* unmanaged[Cdecl]<IntPtr, int, void>, IntPtr, delegate* unmanaged[Cdecl]<IntPtr, void>, int, IntPtr, IntPtr> ScheduleFor;
        internal static delegate* unmanaged[Cdecl]<delegate* unmanaged[Cdecl]<IntPtr, int, int, void>, IntPtr, delegate* unmanaged[Cdecl]<IntPtr, void>, int, int, IntPtr, IntPtr> ScheduleParallelForBatch;
        internal static delegate* unmanaged[Cdecl]<IntPtr, void> Complete;
        internal static delegate* unmanaged[Cdecl]<IntPtr, int> IsCompleted;
        internal static delegate* unmanaged[Cdecl]<IntPtr, void> Retain;
        internal static delegate* unmanaged[Cdecl]<IntPtr, void> Release;
        internal static delegate* unmanaged[Cdecl]<IntPtr*, int, IntPtr> CombineDependencies;
        internal static delegate* unmanaged[Cdecl]<int, void> SetJobCostCacheEnabled;
        internal static delegate* unmanaged[Cdecl]<int, void> SetImplicitBatchEnabled;
        internal static delegate* unmanaged[Cdecl]<void> FlushPendingSubmits;

        internal static bool IsLoaded { get; private set; }

        internal static void Load(IntPtr module)
        {
            Initialize = (delegate* unmanaged[Cdecl]<int, void>)GetExport(module, "GDJS_Initialize");
            Shutdown = (delegate* unmanaged[Cdecl]<void>)GetExport(module, "GDJS_Shutdown");
            GetWorkerCount = (delegate* unmanaged[Cdecl]<int>)GetExport(module, "GDJS_GetWorkerCount");
            Schedule = (delegate* unmanaged[Cdecl]<delegate* unmanaged[Cdecl]<IntPtr, void>, IntPtr, delegate* unmanaged[Cdecl]<IntPtr, void>, IntPtr, IntPtr>)GetExport(module, "GDJS_Schedule");
            ScheduleFor = (delegate* unmanaged[Cdecl]<delegate* unmanaged[Cdecl]<IntPtr, int, void>, IntPtr, delegate* unmanaged[Cdecl]<IntPtr, void>, int, IntPtr, IntPtr>)GetExport(module, "GDJS_ScheduleFor");
            ScheduleParallelForBatch = (delegate* unmanaged[Cdecl]<delegate* unmanaged[Cdecl]<IntPtr, int, int, void>, IntPtr, delegate* unmanaged[Cdecl]<IntPtr, void>, int, int, IntPtr, IntPtr>)GetExport(module, "GDJS_ScheduleParallelForBatch");
            Complete = (delegate* unmanaged[Cdecl]<IntPtr, void>)GetExport(module, "GDJS_Complete");
            IsCompleted = (delegate* unmanaged[Cdecl]<IntPtr, int>)GetExport(module, "GDJS_IsCompleted");
            Retain = (delegate* unmanaged[Cdecl]<IntPtr, void>)GetExport(module, "GDJS_Retain");
            Release = (delegate* unmanaged[Cdecl]<IntPtr, void>)GetExport(module, "GDJS_Release");
            CombineDependencies = (delegate* unmanaged[Cdecl]<IntPtr*, int, IntPtr>)GetExport(module, "GDJS_CombineDependencies");
            SetJobCostCacheEnabled = (delegate* unmanaged[Cdecl]<int, void>)GetExport(module, "GDJS_SetJobCostCacheEnabled");
            SetImplicitBatchEnabled = (delegate* unmanaged[Cdecl]<int, void>)GetExport(module, "GDJS_SetImplicitBatchEnabled");
            FlushPendingSubmits = (delegate* unmanaged[Cdecl]<void>)GetExport(module, "GDJS_FlushPendingSubmits");
            IsLoaded = true;
        }

        private static IntPtr GetExport(IntPtr module, string name)
        {
            IntPtr addr = NativeLoader.GetProcAddress(module, name);
            if (addr == IntPtr.Zero)
            {
                throw new EntryPointNotFoundException($"GDJS export not found: {name}");
            }
            return addr;
        }
    }
}
