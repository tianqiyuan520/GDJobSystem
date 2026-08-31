# GDJobsystem

A Godot 4 multi-threaded Job System GDExtension plugin (C++), built on the [godot-cpp template](https://github.com/godotengine/godot-cpp-template).

## Architecture

Two independent pieces, both under `project/addons/GDJobsystem/`:

| Piece | What it provides | Loaded by |
|---|---|---|
| **GDExtension** (`bin/gd_job_system.gdextension` + DLL) | `JobSystem` / `JobSystemHandle` classes, usable from GDScript at runtime | Godot scans `.gdextension` automatically |
| **Editor plugin** (`plugin.gd` + `monitor/`) | "JobSystem 监控器" debugger tab (Gantt timeline, stats, activity, JobCostCache) | `[editor_plugins]` in `project.godot` |

The kernel (Chase-Lev work-stealing scheduler, MPMC injector, tile-based parallel execution) comes **verbatim from EntJoy's `NativeDll`** via the git submodule `third_party/EntJoy` (sparse-checkout of `src/NativeDll`, pinned to commit `424e7b3`). The binding layer (`src/job_system.*`) adapts it to GDScript. C++20 and exceptions are required. Build consumes the kernel through an explicit source list (`SConstruct`), excluding the C# P/Invoke (`Exports.cpp`/`Native.cpp`) and ImGui (`JobDebuggerGUI.cpp`/`tasksys.cpp`) layers that live in the same directory.

## GDScript usage

```gdscript
JobSystem.initialize(2)                     # worker threads (0 = auto)

var h := JobSystem.schedule(func():
	print("hello from a worker thread"))
h.complete()                                 # block until done

var out := PackedInt32Array(); out.resize(1000)
var hp := JobSystem.schedule_parallel_for(1000, func(i: int):  # batch_size optional (0 = auto)
	out[i] = i)
hp.complete()                                # out[i] == i for all i

var h1 := JobSystem.schedule(func(): pass)
var h2 := JobSystem.schedule(func(): pass, [h1])   # runs after h1
var both := JobSystem.combine_dependencies([h1, h2])
var h3 := JobSystem.schedule(func(): pass, [both])
h3.complete()

JobSystem.shutdown()
```

Full API (static `JobSystem`): `initialize`, `shutdown`, `get_worker_count`, `schedule`, `schedule_for`, `schedule_parallel_for`, `combine_dependencies`, `set_job_cost_cache_enabled` / `is_job_cost_cache_enabled`, `set_implicit_batch_enabled`, `flush_pending_submits`, `debugger_poll`, `get_stats_snapshot`, `get_job_cost_cache_slots`. `JobSystemHandle`: `complete`, `is_completed`.

## Editor monitor

Run the game from the editor (F5) and open the **Debugger** panel → **JobSystem 监控器** tab:

- **Timeline**: zoomable Gantt (Ctrl+wheel zoom, drag pan, click to inspect, double-click re-live), duration-colored bars, W lanes + M (main thread), aggregation when many segments are visible. Pause/Live button freezes the whole stream (editor → game control message).
- **Stats** / **Activity** / **JobCostCache**: scheduler counters, execution-window list (selectable/copyable), learned per-job cost models.

The data flows game → editor over `EngineDebugger` messages (`gd_job_system:*`); see `monitor/monitor_plugin.gd` for the protocol.

## Constraints

- Callbacks run on worker threads: do **not** touch the scene tree or node state inside a job.
- Dependency graphs must be acyclic; the scheduler does no cycle detection (a cycle makes `complete()` hang forever).
- `shutdown()` must run on the same thread as `initialize()` (joining a worker from itself would deadlock). It drains all in-flight jobs first, so pending work completes before teardown.
- If you edit files under `third_party/EntJoy/src/NativeDll/`, expect them to be overwritten by the next EntJoy submodule update — keep your changes in the binding layer instead.

## Benchmark

[project/benchmark.gd](./project/benchmark.gd) compares identical GDScript math across three paths (main-thread loop, `WorkerThreadPool`, `JobSystem`), plus scaling and throughput sweeps. Results are checksum-validated. Sample run — **exported release build** (Godot 4.7, 15 workers):

```
1000000   elem: single   231.81 ms | pool    86.53 ms ( 2.68x) | job    69.67 ms ( 3.33x) | checksum ok=true
4000000   elem: single   934.83 ms | pool   346.67 ms ( 2.70x) | job   261.88 ms ( 3.57x)
submit+wait x5000 : job     7.96 ms | pool     8.40 ms
schedule_for 352.62 ms vs schedule_parallel_for 60.81 ms (5.8x)
```

Notes: measured end-to-end from GDScript (per-element `Callable` + GDScript language lock), so absolute speedups (~3.5x on 15 cores) are far below ideal parallel scaling; native C++ work inside jobs scales much better. Auto batch (0) performs on par with hand-tuned sizes.

## Extended tests

[project/stress_tests.gd](./project/stress_tests.gd) holds 19 correctness/edge-case checks (bulk submit, nested jobs, 100-level chains, fan-in/out, lifecycle, shutdown-with-pending). Invoke manually: `preload("res://stress_tests.gd").run()` after `JobSystem.initialize()`.

## Building

```shell
git submodule update --init --recursive
scons                # debug DLL into project/addons/GDJobsystem/bin/windows/
scons target=template_release
```

Import [project](./project) into Godot and run `job_demo.tscn` (frame-driven job demo). For an IDE, generate `compile_commands.json`:

```shell
scons compiledb=yes
```
