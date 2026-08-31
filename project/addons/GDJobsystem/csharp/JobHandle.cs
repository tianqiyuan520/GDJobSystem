using System;
using System.Collections.Generic;

namespace GDJobsystem
{
    /// <summary>
    /// Wrapper over a native JobSystem handle (HandleState*). Ownership follows
    /// the native refcount: the handle returned by Schedule* carries one reference
    /// that this wrapper releases on Dispose. Retain() adds an extra reference
    /// (e.g. when handing the same handle to multiple owners).
    /// Complete()/IsCompleted() flush pending implicit-batch jobs first.
    /// </summary>
    public sealed unsafe class JobHandle : IDisposable
    {
        private readonly IntPtr _ptr;
        private bool _released;

        internal JobHandle(IntPtr ptr)
        {
            _ptr = ptr;
            _released = ptr == IntPtr.Zero;
        }

        public bool IsValid => _ptr != IntPtr.Zero && !_released;

        internal IntPtr Pointer => IsValid ? _ptr : IntPtr.Zero;

        public bool IsCompleted
        {
            get
            {
                if (!IsValid)
                {
                    return true;
                }
                return JobSystemNative.IsCompleted(_ptr) != 0;
            }
        }

        /// <summary>Block until the job (and its dependencies) complete.</summary>
        public void Complete()
        {
            if (!IsValid)
            {
                return;
            }
            JobSystemNative.Complete(_ptr);
        }

        /// <summary>Add one native reference (use before sharing the handle).</summary>
        public void Retain()
        {
            if (IsValid)
            {
                JobSystemNative.Retain(_ptr);
            }
        }

        /// <summary>
        /// Combine multiple handles into one that completes when all complete.
        /// The result is a NEW handle; input handles remain owned by their wrappers.
        /// </summary>
        public static unsafe JobHandle Combine(IReadOnlyList<JobHandle> handles)
        {
            if (handles == null || handles.Count == 0)
            {
                return new JobHandle(IntPtr.Zero);
            }
            IntPtr[] ptrs = new IntPtr[handles.Count];
            for (int i = 0; i < handles.Count; i++)
            {
                ptrs[i] = handles[i]._ptr;
            }
            fixed (IntPtr* p = ptrs)
            {
                return new JobHandle(JobSystemNative.CombineDependencies(p, handles.Count));
            }
        }

        public void Dispose()
        {
            if (!_released)
            {
                JobSystemNative.Release(_ptr);
                _released = true;
            }
            GC.SuppressFinalize(this);
        }

        ~JobHandle()
        {
            if (!_released)
            {
                JobSystemNative.Release(_ptr);
                _released = true;
            }
        }
    }
}
