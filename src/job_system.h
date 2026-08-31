// ============================================================================
// GDJobsystem — GDExtension 绑定层
// ============================================================================
// 把 EntJoy JobSystem 内核（third_party/EntJoy/src/NativeDll，Chase-Lev 工作窃取调度器）暴露为
// Godot 类，供 GDScript 使用：
//
//   JobSystem        静态门面类：initialize / shutdown / schedule / schedule_for
//                    / schedule_parallel_for / combine_dependencies，以及
//                    JobCostCache、隐式批开关与调试器数据通道（debugger_poll）。
//   JobSystemHandle  任务句柄包装：complete() / is_completed()，
//                    内部持有内核 JobSystem::JobHandle（RAII 释放）。
//
// 要点：
//   * 命名冲突：GDScript 类名 JobSystem 与 C++ 命名空间 JobSystem 同名，
//     本文件内一律用全局限定 ::JobSystem:: 引用内核符号。
//   * 回调桥接（job_system.cpp）：GDScript Callable 被包进堆分配的
//     CallableContext，由内核的 C 函数指针 + cleanup 回调驱动；回调在
//     worker 线程执行（GDScript 语言锁保证安全，但勿触碰场景树）。
//   * 调试器通道：debugger_poll() 经 EngineDebugger 把 worker 快照 / 时间线 /
//     stats / JCC 数据发给编辑器插件（addons/GDJobsystem/monitor/）。
// ============================================================================

#pragma once

#include "godot_cpp/classes/ref_counted.hpp"
#include "godot_cpp/classes/wrapped.hpp"
#include "godot_cpp/variant/array.hpp"
#include "godot_cpp/variant/callable.hpp"
#include "godot_cpp/variant/dictionary.hpp"
#include "godot_cpp/variant/string.hpp"

#include "JobSystem.h"

namespace godot {

// Wraps a JobSystem::JobHandle for use from GDScript.
// RAII: the underlying handle state is released when this object is freed.
class JobSystemHandle : public RefCounted {
	GDCLASS(JobSystemHandle, RefCounted)

protected:
	static void _bind_methods();

public:
	JobSystemHandle() = default;
	~JobSystemHandle() override = default;

	// NOTE: the GDScript class name `JobSystem` collides with the C++ namespace
	// `JobSystem`; always use the global qualification `::JobSystem::` here.
	void set_handle(const ::JobSystem::JobHandle &p_handle);
	const ::JobSystem::JobHandle &get_handle() const;

	/// Blocks until this handle's job (and its dependencies) complete.
	/// If a job callback threw a C++ exception it is re-raised here and printed.
	void complete();
	bool is_completed() const;

private:
	::JobSystem::JobHandle _handle;
};

// Static JobSystem facade exposed to GDScript.
class JobSystem : public RefCounted {
	GDCLASS(JobSystem, RefCounted)

protected:
	static void _bind_methods();

public:
	JobSystem() = default;
	~JobSystem() override = default;

	/// Initialize the scheduler with `threads` worker threads (0 = auto).
	/// Idempotent; must be called before scheduling.
	/// Enables the JobCostCache adaptive tile-learning strategy by default.
	static void initialize(int p_threads = 0);
	/// Stop all workers and release scheduler resources.
	static void shutdown();
	/// Number of persistent worker threads currently running.
	static int get_worker_count();
	static String get_version();

	/// Enable/disable the per-job cost EWMA adaptive tile learning (JobCostCache).
	/// When enabled, batch sizes are solved per job from measured per-element
	/// execution cost instead of the static tiles-per-worker heuristic.
	static void set_job_cost_cache_enabled(bool p_enabled);
	static bool is_job_cost_cache_enabled();

	/// Enable/disable native implicit batching: while enabled, tile-path jobs
	/// submitted from the main thread are collected and submitted in one batch
	/// (single wake) at the next flush point, Unity ScheduleBatchedJobs-style.
	/// complete()/is_completed()/flush_pending_submits() act as flush points.
	static void set_implicit_batch_enabled(bool p_enabled);
	/// Force-flush all collected pending jobs (call once per frame, e.g. end of frame).
	static void flush_pending_submits();

	/// Send the current per-worker snapshot to the editor's JobSystem debugger
	/// tab via EngineDebugger (no-op when no debugger is attached).
	/// Call periodically (e.g. every frame or every 0.2 s).
	static void debugger_poll();

	/// Snapshot of the scheduler's statistics counters (see JobSystemStatsSnapshot).
	static Dictionary get_stats_snapshot();
	/// JobCostCache slots that have learned a cost model: array of
	/// {slot, hash, mode, per_elem_ns, per_tile_ns}.
	static Array get_job_cost_cache_slots();

	/// Schedule a callable to run once on a worker thread.
	/// `dependencies`: array of JobSystemHandle that must complete first.
	static Ref<JobSystemHandle> schedule(const Callable &p_callable, const Array &p_dependencies = {});
	/// Schedule a sequential for loop: callable(index) for index in [0, length).
	static Ref<JobSystemHandle> schedule_for(int p_length, const Callable &p_callable, const Array &p_dependencies = {});
	/// Schedule a parallel for: callable(index) for index in [0, length),
	/// split into batches of `batch_size` items executed across workers
	/// (0 = let the scheduler pick automatically).
	static Ref<JobSystemHandle> schedule_parallel_for(int p_length, const Callable &p_callable, int p_batch_size = 0, const Array &p_dependencies = {});
	/// Combine multiple handles into a single handle that completes when all complete.
	static Ref<JobSystemHandle> combine_dependencies(const Array &p_handles);
};

} // namespace godot
