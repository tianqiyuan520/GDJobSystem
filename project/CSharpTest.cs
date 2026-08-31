using GDJobsystem;
using Godot;
using System;
using System.Runtime.InteropServices;

/// <summary>
/// C# P/Invoke binding test scene (res://csharp_test.tscn).
/// Exercises Schedule / ScheduleFor / ParallelFor / dependencies / implicit batch
/// through the GDJS C export layer, then verifies results on the main thread.
/// </summary>
public partial class CSharpTest : Node
{
	private static int _failures;

	public override void _Ready()
	{
		_failures = 0;
		GD.Print("=== C# P/Invoke binding test ===");

		if (!LoadNative())
		{
			GD.PrintErr("Aborting: failed to load native module.");
			GetTree().Quit(1);
			return;
		}

		JobScheduler.Initialize(2);
		GD.Print($"workers: {JobScheduler.WorkerCount}, JobCostCache on");

		TestSchedule();
		TestScheduleFor();
		TestParallelFor();
		TestDependencies();
		TestImplicitBatch();

		JobScheduler.Shutdown();
		GD.Print(_failures == 0 ? "C# TESTS DONE" : $"C# TESTS FAILED: {_failures}");
		GetTree().Quit(_failures == 0 ? 0 : 1);
	}

	private static bool LoadNative()
	{
		string dllPath = FindDll();
		if (string.IsNullOrEmpty(dllPath) || !System.IO.File.Exists(dllPath))
		{
			GD.PrintErr("DLL not found (searched debug/release under addons/GDJobsystem/bin/windows): " + dllPath);
			return false;
		}
		IntPtr module = NativeLoader.LoadLibrary(dllPath);
		if (module == IntPtr.Zero)
		{
			GD.PrintErr("LoadLibrary failed (Win32 error " + Marshal.GetLastWin32Error() + "): " + dllPath);
			return false;
		}
		JobScheduler.Load(module);
		return true;
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

	// ------------------------------------------------------------------
	private static void TestSchedule()
	{
		bool ran = false;
		using var h = JobScheduler.Schedule(() => ran = true);
		h.Complete();
		Check(ran, "schedule: callback executed");
	}

	private static void TestScheduleFor()
	{
		int n = 1000;
		int[] data = new int[n];
		using var h = JobScheduler.ScheduleFor(n, i => data[i] = i);
		h.Complete();
		bool ok = true;
		for (int i = 0; i < n; i++)
		{
			if (data[i] != i)
			{
				ok = false;
				break;
			}
		}
		Check(ok, "schedule_for: data[i] == i");
	}

	private static void TestParallelFor()
	{
		int n = 100_000;
		int[] data = new int[n];
		using var h = JobScheduler.ParallelFor(n, 256, i => data[i] = i);
		h.Complete();
		bool ok = true;
		for (int i = 0; i < n; i++)
		{
			if (data[i] != i)
			{
				ok = false;
				break;
			}
		}
		Check(ok, "parallel_for: 100k elements correct");
	}

	private static void TestDependencies()
	{
		// h2 depends on h1: h2 runs only after h1 completed.
		int[] log = { 0, 0 };
		using var h1 = JobScheduler.Schedule(() => log[0] = 1);
		using var h2 = JobScheduler.Schedule(() => log[1] = log[0] + 1, h1);
		h2.Complete();
		Check(log[0] == 1 && log[1] == 2, "dependency: h2 runs after h1");

		// Combine: one handle that completes when all inputs complete.
		int[] log2 = { 0, 0, 0 };
		using var a = JobScheduler.Schedule(() => log2[0] = 1);
		using var b = JobScheduler.Schedule(() => log2[1] = 2);
		using var combined = JobHandle.Combine(new[] { a, b });
		using var c = JobScheduler.Schedule(() => log2[2] = log2[0] + log2[1], combined);
		c.Complete();
		Check(log2[0] == 1 && log2[1] == 2 && log2[2] == 3, "combine_dependencies: fan-in works");
	}

	private static void TestImplicitBatch()
	{
		JobScheduler.SetImplicitBatchEnabled(true);
		int n = 20_000;
		int[] data = new int[n];
		// Submit several jobs without completing: collected as pending.
		using var h1 = JobScheduler.ParallelFor(n, 256, i => data[i] = i);
		using var h2 = JobScheduler.ParallelFor(n, 256, i => data[i] = i);
		JobScheduler.EndFrame(); // force point: submit all pending
		h1.Complete();
		h2.Complete();
		bool ok = true;
		for (int i = 0; i < n; i++)
		{
			if (data[i] != i)
			{
				ok = false;
				break;
			}
		}
		Check(ok, "implicit batch: EndFrame + complete correct");
		JobScheduler.SetImplicitBatchEnabled(false);
	}

	private static void Check(bool cond, string label)
	{
		if (cond)
		{
			GD.Print("  [PASS] " + label);
		}
		else
		{
			_failures++;
			GD.Print("  [FAIL] " + label);
		}
	}
}
