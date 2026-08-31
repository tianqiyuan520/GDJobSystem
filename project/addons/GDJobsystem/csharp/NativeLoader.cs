using System;
using System.Runtime.InteropServices;

namespace GDJobsystem
{
    /// <summary>
    /// Minimal dynamic loader for the GDJobSystem native DLL. LoadLibrary is used
    /// instead of static DllImport so the exact platform/target-suffixed file name
    /// and res:// path can be resolved at runtime (editor vs exported game).
    /// </summary>
    internal static class NativeLoader
    {
        private const string Kernel32 = "kernel32";

        [DllImport(Kernel32, CharSet = CharSet.Unicode, SetLastError = true)]
        internal static extern IntPtr LoadLibrary(string lpFileName);

        [DllImport(Kernel32, CharSet = CharSet.Ansi, SetLastError = true)]
        internal static extern IntPtr GetProcAddress(IntPtr hModule, string lpProcName);

        [DllImport(Kernel32, SetLastError = true)]
        internal static extern bool FreeLibrary(IntPtr hModule);

        internal static T GetDelegate<T>(IntPtr module, string name) where T : Delegate
        {
            IntPtr addr = GetProcAddress(module, name);
            if (addr == IntPtr.Zero)
            {
                throw new EntryPointNotFoundException($"GDJS export not found: {name}");
            }
            return Marshal.GetDelegateForFunctionPointer<T>(addr);
        }
    }
}
