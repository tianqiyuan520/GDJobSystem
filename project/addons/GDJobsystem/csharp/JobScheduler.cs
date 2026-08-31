using System;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;

namespace GDJobsystem
{
    /// <summary>
    /// High-level C# facade over the GDJobSystem kernel via the GDJS P/Invoke layer.
    /// Load() must be called once with the native module handle before use.
    ///
    /// EntJoy-style function-pointer callbacks: the native callbacks are
    /// [UnmanagedCallersOnly] static methods (no delegate allocation, no GC risk)
    /// and the exported functions are called through delegate* unmanaged[Cdecl].
    ///
    /// Threading contract: callbacks run on worker threads — they may touch plain
    /// managed objects, but MUST NOT touch Godot scene tree / nodes, and any
    /// exception inside a callback must be caught (escaping to C++ is UB).
    /// </summary>
    public static unsafe class JobScheduler
    {
        private static bool _loaded;

        /// <summary>Load the native exports from an already-loaded module handle.</summary>
        public static void Load(IntPtr module)
        {
            JobSystemNative.Load(module);
            _loaded = true;
        }

        public static void Initialize(int threads = 0)
        {
            RequireLoaded();
            JobSystemNative.Initialize(threads);
        }

        public static void Shutdown()
        {
            if (!_loaded)
            {
                return;
            }
            JobSystemNative.Shutdown();
        }

        public static int WorkerCount
        {
            get
            {
                RequireLoaded();
                return JobSystemNative.GetWorkerCount();
            }
        }

        /// <summary>Frame-end force point: submit all collected implicit-batch jobs.</summary>
        public static void EndFrame()
        {
            RequireLoaded();
            JobSystemNative.FlushPendingSubmits();
        }

        public static void SetJobCostCacheEnabled(bool enabled)
        {
            RequireLoaded();
            JobSystemNative.SetJobCostCacheEnabled(enabled ? 1 : 0);
        }

        public static void SetImplicitBatchEnabled(bool enabled)
        {
            RequireLoaded();
            JobSystemNative.SetImplicitBatchEnabled(enabled ? 1 : 0);
        }

        public static JobHandle Schedule(Action callback, JobHandle? dependency = null)
        {
            RequireLoaded();
            var box = new CallbackBox(callback);
            IntPtr dep = dependency is { IsValid: true } d ? d.Pointer : IntPtr.Zero;
            return new JobHandle(JobSystemNative.Schedule(&Box.RunJob, GCHandle.ToIntPtr(box.Handle), &Box.Cleanup, dep));
        }

        public static JobHandle ScheduleFor(int length, Action<int> callback, JobHandle? dependency = null)
        {
            RequireLoaded();
            var box = new CallbackBox(callback);
            IntPtr dep = dependency is { IsValid: true } d ? d.Pointer : IntPtr.Zero;
            return new JobHandle(JobSystemNative.ScheduleFor(&Box.RunIndex, GCHandle.ToIntPtr(box.Handle), &Box.Cleanup, length, dep));
        }

        public static JobHandle ParallelFor(int length, int batchSize, Action<int> callback, JobHandle? dependency = null)
        {
            RequireLoaded();
            var box = new CallbackBox(callback);
            IntPtr dep = dependency is { IsValid: true } d ? d.Pointer : IntPtr.Zero;
            return new JobHandle(JobSystemNative.ScheduleParallelForBatch(&Box.RunBatch, GCHandle.ToIntPtr(box.Handle), &Box.Cleanup, length, batchSize, dep));
        }

        /// <summary>
        /// Batch-callback parallel for: the callback receives (start, count) once
        /// per batch and must loop over [start, start+count) itself. The last batch
        /// may have count &lt; batchSize. This removes the per-element delegate tax of
        /// ParallelFor (n calls → n/batchSize calls).
        /// </summary>
        public static JobHandle ParallelForBatch(int length, int batchSize, Action<int, int> callback, JobHandle? dependency = null)
        {
            RequireLoaded();
            var box = new CallbackBox(callback);
            IntPtr dep = dependency is { IsValid: true } d ? d.Pointer : IntPtr.Zero;
            return new JobHandle(JobSystemNative.ScheduleParallelForBatch(&Box.RunBatchDirect, GCHandle.ToIntPtr(box.Handle), &Box.Cleanup, length, batchSize, dep));
        }

        // ------------------------------------------------------------------
        // Callback bridge (EntJoy-style): [UnmanagedCallersOnly] static methods
        // are passed to native as raw function pointers; the user's Action is
        // boxed in a CallbackBox pinned by a GCHandle (ctx). No delegate ever
        // needs Marshal.GetFunctionPointerForDelegate, and the GCHandle is
        // freed by the native cleanup callback.
        // ------------------------------------------------------------------
        private sealed class CallbackBox
        {
            internal readonly GCHandle Handle;
            internal readonly Action Job;
            internal readonly Action<int> IndexJob;
            internal readonly Action<int, int> BatchJob;

            internal CallbackBox(Action job)
            {
                Job = job;
                Handle = GCHandle.Alloc(this);
            }

            internal CallbackBox(Action<int> indexJob)
            {
                IndexJob = indexJob;
                Handle = GCHandle.Alloc(this);
            }

            internal CallbackBox(Action<int, int> batchJob)
            {
                BatchJob = batchJob;
                Handle = GCHandle.Alloc(this);
            }
        }

        private static class Box
        {
            [UnmanagedCallersOnly(CallConvs = new[] { typeof(CallConvCdecl) })]
            internal static void RunJob(IntPtr ctx)
            {
                var box = (CallbackBox)GCHandle.FromIntPtr(ctx).Target!;
                box.Job();
            }

            [UnmanagedCallersOnly(CallConvs = new[] { typeof(CallConvCdecl) })]
            internal static void RunIndex(IntPtr ctx, int index)
            {
                var box = (CallbackBox)GCHandle.FromIntPtr(ctx).Target!;
                box.IndexJob(index);
            }

            // Kernel invokes batch callbacks as (start, count); expand to per-index.
            [UnmanagedCallersOnly(CallConvs = new[] { typeof(CallConvCdecl) })]
            internal static void RunBatch(IntPtr ctx, int start, int count)
            {
                var box = (CallbackBox)GCHandle.FromIntPtr(ctx).Target!;
                for (int j = start; j < start + count; j++)
                {
                    box.IndexJob(j);
                }
            }

            // Batch-callback mode: pass (start, count) straight through, no expansion.
            [UnmanagedCallersOnly(CallConvs = new[] { typeof(CallConvCdecl) })]
            internal static void RunBatchDirect(IntPtr ctx, int start, int count)
            {
                var box = (CallbackBox)GCHandle.FromIntPtr(ctx).Target!;
                box.BatchJob(start, count);
            }

            [UnmanagedCallersOnly(CallConvs = new[] { typeof(CallConvCdecl) })]
            internal static void Cleanup(IntPtr ctx)
            {
                var box = (CallbackBox)GCHandle.FromIntPtr(ctx).Target!;
                box.Handle.Free();
            }
        }

        private static void RequireLoaded()
        {
            if (!_loaded)
            {
                throw new InvalidOperationException("JobScheduler.Load() must be called first.");
            }
        }
    }
}
