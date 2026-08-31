using GDJobsystem;
using Godot;
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading.Tasks;

/// <summary>
/// C# performance benchmark (res://csharp_bench.tscn).
/// Compares, for the same per-element math over 1M floats:
///   1) C# single-thread loop
///   2) C# native multi-threading (System.Threading.Tasks.Parallel.For)
///   3) C# P/Invoke -> JobSystem (this binding)
///   4) GDScript facade -> same JobSystem kernel (bridge script)
/// All paths fill their own buffer; timings are best-of Rounds.
/// </summary>
public partial class CSharpBench : Node
{
    private const int Elements = 1_000_000;
    private const int Rounds = 5;

    public override void _Ready()
    {
        GD.Print("=== C# performance benchmark (1M elements x " + Rounds + " rounds) ===");

        string dllPath = FindDll();
        if (string.IsNullOrEmpty(dllPath) || !System.IO.File.Exists(dllPath))
        {
            GD.PrintErr("DLL not found (searched debug/release): " + dllPath);
            GetTree().Quit(1);
            return;
        }
        IntPtr module = NativeLoader.LoadLibrary(dllPath);
        if (module == IntPtr.Zero)
        {
            GD.PrintErr("LoadLibrary failed: " + dllPath);
            GetTree().Quit(1);
            return;
        }
        JobScheduler.Load(module);
        JobScheduler.Initialize();
        GD.Print($"workers: {JobScheduler.WorkerCount}, JobCostCache on");

        double singleMs = BenchSingle();
        double parallelMs = BenchParallel();
        double jobMs = BenchJobSystem();
        double jobBatchMs = BenchJobSystemBatch();
        double gdMs = BenchGDScriptBridge();

        GD.Print($"single-thread          : {singleMs,9:F2} ms  (1.00x)");
        GD.Print($"C# Parallel.For        : {parallelMs,9:F2} ms  ({singleMs / parallelMs:F2}x)");
        GD.Print($"C# P/Invoke JobSystem  : {jobMs,9:F2} ms  ({singleMs / jobMs:F2}x)");
        GD.Print($"C# P/Invoke JobSystem-B: {jobBatchMs,9:F2} ms  ({singleMs / jobBatchMs:F2}x)");
        GD.Print($"GDScript bridge        : {gdMs,9:F2} ms  ({singleMs / gdMs:F2}x)");

        JobScheduler.Shutdown();
        GD.Print("C# BENCH DONE");
        GetTree().Quit();
    }

    // Same formula as project/benchmark_gd_bridge.gd (_element_value).
    private static float Val(int i)
    {
        float v = i * 0.0001f + 0.5f;
        return MathF.Sin(v) * 1.5f + MathF.Cos(v * 0.5f) * 0.5f + MathF.Sqrt(MathF.Abs(v) + 1.0f);
    }

    private static string FindDll()
    {
        // Exported games: the GDExtension DLL sits next to the executable.
        string exeDir = System.IO.Path.GetDirectoryName(OS.GetExecutablePath()) ?? string.Empty;
        string[] variants = { "template_debug", "template_release" };
        foreach (string v in variants)
        {
            string exeSide = System.IO.Path.Combine(exeDir, $"GDJobSystem.windows.{v}.x86_64.dll");
            if (System.IO.File.Exists(exeSide))
            {
                return exeSide;
            }
        }
        // Editor: the plugin DLL lives under res://.
        foreach (string v in variants)
        {
            string p = ProjectSettings.GlobalizePath(
                $"res://addons/GDJobsystem/bin/windows/GDJobSystem.windows.{v}.x86_64.dll");
            if (System.IO.File.Exists(p))
            {
                return p;
            }
        }
        return string.Empty;
    }

    private static double BenchSingle()
    {
        float[] data = new float[Elements];
        return BestOf(() =>
        {
            for (int i = 0; i < data.Length; i++)
            {
                data[i] = Val(i);
            }
        });
    }

    private static double BenchParallel()
    {
        float[] data = new float[Elements];
        return BestOf(() => Parallel.For(0, Elements, i => data[i] = Val(i)));
    }

    private static double BenchJobSystem()
    {
        float[] data = new float[Elements];
        return BestOf(() =>
        {
            using var h = JobScheduler.ParallelFor(Elements, 0, i => data[i] = Val(i));
            h.Complete();
        });
    }

    private static double BenchJobSystemBatch()
    {
        float[] data = new float[Elements];
        return BestOf(() =>
        {
            using var h = JobScheduler.ParallelForBatch(Elements, 4096, (s, c) =>
            {
                for (int j = s; j < s + c; j++)
                {
                    data[j] = Val(j);
                }
            });
            h.Complete();
        });
    }

    private static double BenchGDScriptBridge()
    {
        var script = GD.Load<GDScript>("res://benchmark_gd_bridge.gd");
        var node = new Node();
        node.SetScript(script);
        node.Call("ensure_initialized");

        var sw = Stopwatch.StartNew();
        double bestMs = double.MaxValue;
        for (int r = 0; r < Rounds; r++)
        {
            sw.Restart();
            var result = (Godot.Collections.Dictionary)node.Call("run_job_bench", Elements);
            long us = (long)(double)result["us"];
            bestMs = Math.Min(bestMs, us / 1000.0);
        }
        node.QueueFree();
        return bestMs;
    }

    private static double BestOf(Action run)
    {
        var sw = Stopwatch.StartNew();
        double bestMs = double.MaxValue;
        for (int r = 0; r < Rounds; r++)
        {
            sw.Restart();
            run();
            bestMs = Math.Min(bestMs, sw.Elapsed.TotalMilliseconds);
        }
        return bestMs;
    }
}
