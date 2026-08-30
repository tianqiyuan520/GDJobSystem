// ============================================================================
// GDJobsystem — GDExtension 绑定层实现
// ============================================================================
// 结构：
//   * Callable 桥接（匿名命名空间）：内核调度器只认 C 函数指针
//     void(*)(void*) / void(*)(void*,int) / void(*)(void*,int,int)。
//     我们把 GDScript Callable 拷贝进堆分配的 CallableContext，把函数指针
//     作为回调、cleanup_callable 作为释放钩子（任务全部退役后 delete）。
//     注意：回调在 worker 线程执行——GDScript 语言锁保证 Callable::call
//     跨线程安全，但 job 内禁止触碰场景树 / 节点状态。
//   * JobSystemHandle：包装内核 JobHandle（拷贝增引用，析构释放）。
//     complete()/is_completed() 先 FlushPendingSubmits（隐式批语义，
//     防止 pending 中的任务因无人提交而死等）。
//   * JobSystem 静态门面：调度 API、JobCostCache/隐式批开关、
//     以及调试器数据通道 debugger_poll()（EngineDebugger 消息）。
//   * 调试器通道协议（编辑器插件 addons/GDJobsystem/monitor 接收）：
//       gd_job_system:worker_snap / timeline / stats / jcc
//     控制通道（编辑器→游戏）：
//       gd_job_system_ctl:set_paused  [bool] —— 暂停时 debugger_poll 直接返回
// ============================================================================

#include "job_system.h"

#include "godot_cpp/core/class_db.hpp"
#include "godot_cpp/core/error_macros.hpp"
#include "godot_cpp/classes/engine_debugger.hpp"
#include "godot_cpp/variant/callable_method_pointer.hpp"
#include "godot_cpp/variant/dictionary.hpp"
#include "godot_cpp/variant/utility_functions.hpp"

#include "native/JobSystem.h"
#include "native/JobSystemInternal.h"

#include <atomic>
#include <condition_variable>
#include <mutex>
#include <thread>
#include <vector>

namespace js = ::JobSystem;

namespace godot {

// ---------------------------------------------------------------------------
// Callable bridge: the JobSystem kernel invokes plain C function pointers.
// We heap-allocate a Callable context that is freed by the kernel's cleanup
// callback once every scheduled task for that job has retired.
// NOTE: callbacks run on worker threads. Godot's GDScript language lock makes
// Callable::call() safe to invoke off the main thread, but do NOT touch the
// scene tree / node state from inside a job.
// ---------------------------------------------------------------------------
namespace {

struct CallableContext {
	Callable callable;
	explicit CallableContext(const Callable &p_callable) : callable(p_callable) {}
};

void run_callable(void *p_ctx) {
	auto *ctx = static_cast<CallableContext *>(p_ctx);
	ctx->callable.call();
}

void run_callable_index(void *p_ctx, int p_index) {
	auto *ctx = static_cast<CallableContext *>(p_ctx);
	ctx->callable.call(p_index);
}

void run_callable_batch(void *p_ctx, int p_start, int p_count) {
	auto *ctx = static_cast<CallableContext *>(p_ctx);
	// The kernel invokes the callback once per batch as (start, count);
	// expand it back into per-index calls so GDScript sees callable(index).
	for (int i = p_start; i < p_start + p_count; i++) {
		ctx->callable.call(i);
	}
}

// In-flight Callable contexts: +1 before submit, -1 in cleanup_callable.
// Lets shutdown() drain outstanding jobs (avoid leaking contexts on teardown).
std::atomic<int> s_inflight{ 0 };
std::mutex s_inflight_mtx;
std::condition_variable s_inflight_cv;
// Thread that initialized the scheduler; shutdown() must run on it (joining a
// worker thread from itself would deadlock).
std::thread::id s_main_thread_id;

void cleanup_callable(void *p_ctx) {
	delete static_cast<CallableContext *>(p_ctx);
	// Decrement the in-flight counter; shutdown() waits for it to reach zero
	// so every callback context is freed before the scheduler tears down.
	const int remaining = s_inflight.fetch_sub(1, std::memory_order_acq_rel);
	if (remaining == 1) {
		s_inflight_cv.notify_all();
	}
}

std::atomic<bool> s_scheduler_initialized{ false };

js::JobHandle resolve_dependency(const Array &p_dependencies) {
	if (p_dependencies.is_empty()) {
		return {};
	}
	std::vector<js::JobHandle> handles;
	handles.reserve(static_cast<size_t>(p_dependencies.size()));
	for (int i = 0; i < p_dependencies.size(); i++) {
		Ref<JobSystemHandle> dep = p_dependencies[i];
		if (dep.is_valid()) {
			handles.push_back(dep->get_handle());
		}
	}
	if (handles.empty()) {
		return {};
	}
	if (handles.size() == 1) {
		return handles[0];
	}
	return js::JobHandle::CombineDependencies(handles);
}

Ref<JobSystemHandle> wrap_handle(const js::JobHandle &p_handle) {
	Ref<JobSystemHandle> out;
	out.instantiate();
	out->set_handle(p_handle);
	return out;
}

} // namespace

// ---------------------------------------------------------------------------
// JobSystemHandle
// ---------------------------------------------------------------------------

void JobSystemHandle::_bind_methods() {
	ClassDB::bind_method(D_METHOD("complete"), &JobSystemHandle::complete);
	ClassDB::bind_method(D_METHOD("is_completed"), &JobSystemHandle::is_completed);
}

void JobSystemHandle::set_handle(const js::JobHandle &p_handle) {
	_handle = p_handle;
}

const js::JobHandle &JobSystemHandle::get_handle() const {
	return _handle;
}

void JobSystemHandle::complete() {
	// Implicit batching: flush any pending jobs first (Unity ScheduleBatchedJobs
	// semantics, prevents waiting forever on a job that is still collected).
	js::FlushPendingSubmits();
	if (!_handle.State()) {
		ERR_PRINT("JobSystemHandle::complete() called on an invalid/empty handle.");
		return;
	}
	try {
		_handle.Complete();
	} catch (const std::exception &e) {
		ERR_PRINT(vformat("Job callback threw: %s", e.what()));
	} catch (...) {
		ERR_PRINT("Job callback threw an unknown exception.");
	}
}

bool JobSystemHandle::is_completed() const {
	// Implicit batching: flush first so a pending job is not reported incomplete.
	js::FlushPendingSubmits();
	return _handle.State() ? _handle.IsCompleted() : false;
}

// ---------------------------------------------------------------------------
// JobSystem (static facade)
// ---------------------------------------------------------------------------

void JobSystem::_bind_methods() {
	ClassDB::bind_static_method(get_class_static(), D_METHOD("initialize", "threads"), &JobSystem::initialize, 0);
	ClassDB::bind_static_method(get_class_static(), D_METHOD("shutdown"), &JobSystem::shutdown);
	ClassDB::bind_static_method(get_class_static(), D_METHOD("get_worker_count"), &JobSystem::get_worker_count);
	ClassDB::bind_static_method(get_class_static(), D_METHOD("get_version"), &JobSystem::get_version);

	ClassDB::bind_static_method(get_class_static(), D_METHOD("set_job_cost_cache_enabled", "enabled"), &JobSystem::set_job_cost_cache_enabled);
	ClassDB::bind_static_method(get_class_static(), D_METHOD("is_job_cost_cache_enabled"), &JobSystem::is_job_cost_cache_enabled);

	ClassDB::bind_static_method(get_class_static(), D_METHOD("set_implicit_batch_enabled", "enabled"), &JobSystem::set_implicit_batch_enabled);
	ClassDB::bind_static_method(get_class_static(), D_METHOD("flush_pending_submits"), &JobSystem::flush_pending_submits);
	ClassDB::bind_static_method(get_class_static(), D_METHOD("debugger_poll"), &JobSystem::debugger_poll);

	ClassDB::bind_static_method(get_class_static(), D_METHOD("get_stats_snapshot"), &JobSystem::get_stats_snapshot);
	ClassDB::bind_static_method(get_class_static(), D_METHOD("get_job_cost_cache_slots"), &JobSystem::get_job_cost_cache_slots);

	ClassDB::bind_static_method(get_class_static(), D_METHOD("schedule", "callable", "dependencies"), &JobSystem::schedule, Array());
	ClassDB::bind_static_method(get_class_static(), D_METHOD("schedule_for", "length", "callable", "dependencies"), &JobSystem::schedule_for, Array());
	ClassDB::bind_static_method(get_class_static(), D_METHOD("schedule_parallel_for", "length", "callable", "batch_size", "dependencies"), &JobSystem::schedule_parallel_for, 0, Array());
	ClassDB::bind_static_method(get_class_static(), D_METHOD("combine_dependencies", "handles"), &JobSystem::combine_dependencies);
}

void JobSystem::initialize(int p_threads) {
	if (s_scheduler_initialized.load(std::memory_order_relaxed)) {
		return;
	}
	s_main_thread_id = std::this_thread::get_id();
	js::Scheduler::Initialize(p_threads);
	s_scheduler_initialized.store(true, std::memory_order_relaxed);
	// Adaptive tile learning (JobCostCache) on by default; disable via
	// set_job_cost_cache_enabled(false) if the static heuristic is preferred.
	js::g_jobCostCacheEnabled.store(true, std::memory_order_release);
	UtilityFunctions::print(vformat("GDJobSystem initialize(%d) -> %d worker(s), JobCostCache on", p_threads, get_worker_count()));
}

void JobSystem::shutdown() {
	if (!s_scheduler_initialized.load(std::memory_order_relaxed)) {
		return;
	}
	if (std::this_thread::get_id() != s_main_thread_id) {
		ERR_PRINT("JobSystem::shutdown() must be called from the thread that called initialize().");
		return;
	}
	// Drain in-flight jobs so their Callable contexts are freed before the
	// scheduler tears down (otherwise unfinished jobs leak their context).
	std::unique_lock<std::mutex> lock(s_inflight_mtx);
	s_inflight_cv.wait(lock, []() { return s_inflight.load(std::memory_order_acquire) == 0; });
	lock.unlock();
	js::Scheduler::Shutdown();
	s_scheduler_initialized.store(false, std::memory_order_relaxed);
	UtilityFunctions::print("GDJobSystem shut down.");
}

void JobSystem::set_job_cost_cache_enabled(bool p_enabled) {
	js::g_jobCostCacheEnabled.store(p_enabled, std::memory_order_release);
	UtilityFunctions::print(vformat("JobCostCache (adaptive tile learning) %s", p_enabled ? "enabled" : "disabled"));
}

bool JobSystem::is_job_cost_cache_enabled() {
	return js::g_jobCostCacheEnabled.load(std::memory_order_acquire);
}

void JobSystem::set_implicit_batch_enabled(bool p_enabled) {
	if (p_enabled) {
		js::g_implicitBatchEnabled.store(true, std::memory_order_relaxed);
		UtilityFunctions::print("Implicit batch (native collection) enabled.");
		return;
	}
	// Disable: drain the backlog first to avoid hanging/leaking, then clear.
	js::FlushPendingSubmits();
	js::g_implicitBatchEnabled.store(false, std::memory_order_relaxed);
	UtilityFunctions::print("Implicit batch (native collection) disabled.");
}

void JobSystem::flush_pending_submits() {
	js::FlushPendingSubmits();
}

// debugger_poll() is defined at the end of this file (worker snapshot +
// timeline segments feed).

int JobSystem::get_worker_count() {
	return js::CurrentWorkerCount();
}

String JobSystem::get_version() {
	return "0.1.0";
}

Ref<JobSystemHandle> JobSystem::schedule(const Callable &p_callable, const Array &p_dependencies) {
	if (!s_scheduler_initialized.load(std::memory_order_relaxed)) {
		ERR_PRINT("JobSystem::schedule() called before initialize().");
		return {};
	}
	if (!p_callable.is_valid()) {
		ERR_PRINT("JobSystem::schedule() requires a valid Callable.");
		return {};
	}
	auto *ctx = new CallableContext(p_callable);
	s_inflight.fetch_add(1, std::memory_order_acq_rel);
	const js::JobHandle dep = resolve_dependency(p_dependencies);
	const js::JobHandle handle = js::Scheduler::Schedule(&run_callable, ctx, &cleanup_callable, dep);
	return wrap_handle(handle);
}

Ref<JobSystemHandle> JobSystem::schedule_for(int p_length, const Callable &p_callable, const Array &p_dependencies) {
	if (!s_scheduler_initialized.load(std::memory_order_relaxed)) {
		ERR_PRINT("JobSystem::schedule_for() called before initialize().");
		return {};
	}
	if (!p_callable.is_valid()) {
		ERR_PRINT("JobSystem::schedule_for() requires a valid Callable.");
		return {};
	}
	auto *ctx = new CallableContext(p_callable);
	s_inflight.fetch_add(1, std::memory_order_acq_rel);
	const js::JobHandle dep = resolve_dependency(p_dependencies);
	const js::JobHandle handle = js::Scheduler::ScheduleFor(&run_callable_index, ctx, p_length, &cleanup_callable, dep);
	return wrap_handle(handle);
}

Ref<JobSystemHandle> JobSystem::schedule_parallel_for(int p_length, const Callable &p_callable, int p_batch_size, const Array &p_dependencies) {
	if (!s_scheduler_initialized.load(std::memory_order_relaxed)) {
		ERR_PRINT("JobSystem::schedule_parallel_for() called before initialize().");
		return {};
	}
	if (!p_callable.is_valid()) {
		ERR_PRINT("JobSystem::schedule_parallel_for() requires a valid Callable.");
		return {};
	}
	if (p_length <= 0) {
		ERR_PRINT("JobSystem::schedule_parallel_for() requires length > 0.");
		return {};
	}
	auto *ctx = new CallableContext(p_callable);
	s_inflight.fetch_add(1, std::memory_order_acq_rel);
	const js::JobHandle dep = resolve_dependency(p_dependencies);
	const js::JobHandle handle = js::Scheduler::ScheduleParallelForBatch(&run_callable_batch, ctx, p_length, p_batch_size, &cleanup_callable, dep);
	return wrap_handle(handle);
}

Ref<JobSystemHandle> JobSystem::combine_dependencies(const Array &p_handles) {
	if (p_handles.is_empty()) {
		ERR_PRINT("JobSystem::combine_dependencies() requires at least one handle.");
		return {};
	}
	return wrap_handle(resolve_dependency(p_handles));
}

// ---------------------------------------------------------------------------
// Debugger feed
// ---------------------------------------------------------------------------

namespace {
// Ring-buffer read cursor for the kernel's execution timeline segments.
std::atomic<unsigned int> s_last_seg_visible{ 0 };
// Throttle for the heavier stats / JobCostCache payloads.
std::atomic<unsigned int> s_poll_counter{ 0 };
// Editor-requested freeze: while true, debugger_poll sends nothing.
std::atomic<bool> s_debugger_paused{ false };
// One-shot guard for the message-capture registration.
std::atomic<bool> s_capture_registered{ false };

void _on_debugger_message(const String &p_message, const Array &p_data) {
	if (p_message == "set_paused" || p_message == "gd_job_system_ctl:set_paused") {
		s_debugger_paused.store(p_data.size() > 0 && (bool)p_data[0], std::memory_order_relaxed);
	}
}
} // namespace

void JobSystem::debugger_poll() {
	EngineDebugger *dbg = EngineDebugger::get_singleton();
	if (dbg == nullptr || !dbg->is_active()) {
		return; // No debugger attached (e.g. exported game) — zero cost.
	}
	if (s_debugger_paused.load(std::memory_order_relaxed)) {
		return; // Editor froze the view: stop streaming entirely.
	}
	// Enable native execution-window capture (needed for the timeline).
	js::g_nativeActivityCaptureEnabled.store(true, std::memory_order_relaxed);
	// One-shot: listen for editor control messages (gd_job_system_ctl:*).
	if (!s_capture_registered.load(std::memory_order_relaxed)) {
		dbg->register_message_capture("gd_job_system_ctl",
				godot::create_custom_callable_static_function_pointer(&_on_debugger_message));
		s_capture_registered.store(true, std::memory_order_relaxed);
	}

	// 1) Per-worker snapshot.
	Array data;
	const int worker_count = js::CurrentWorkerCount();
	for (int i = 0; i < worker_count; i++) {
		Dictionary w;
		// acquire load of the active flag synchronizes with the kernel's
		// release store in DebugBeginExec/DebugEndExec, so the other fields
		// are read after their writes are visible.
		w["index"] = i;
		w["active"] = (bool)js::g_workerIsActive[i].load(std::memory_order_acquire);
		w["batch_id"] = (uint64_t)js::g_workerCurrentBatchId[i].load(std::memory_order_relaxed);
		// The kernel never updates g_workerCurrentTile (it stays 0); only the
		// planned per-batch tile count (g_workerBatchTileCount) is meaningful.
		w["tile"] = (int)js::g_workerCurrentTile[i].load(std::memory_order_relaxed);
		w["tile_count"] = (int)js::g_workerBatchTileCount[i].load(std::memory_order_relaxed);
		data.append(w);
	}
	dbg->send_message("gd_job_system:worker_snap", data);

	// 2) New timeline segments since the last poll (execution windows).
	const unsigned int visible = js::g_debugSegVisible.load(std::memory_order_acquire);
	const unsigned int from = s_last_seg_visible.load(std::memory_order_relaxed);
	if (visible > from) {
		Array segs;
		for (unsigned int i = from; i < visible; i++) {
			const js::DebugSegment &s = js::g_debugSegments[i % js::kDebugSegmentMax];
			Dictionary d;
			d["lane"] = s.lane;
			d["batch_id"] = (uint64_t)s.batchId;
			d["start_ms"] = s.startMs;
			d["end_ms"] = s.endMs;
			d["tiles"] = (int)s.tiles;
			d["workers"] = (int)s.workers;
			d["direct"] = (bool)s.isDirect;
			segs.append(d);
		}
		s_last_seg_visible.store(visible, std::memory_order_relaxed);
		dbg->send_message("gd_job_system:timeline", segs);
	}

	// 3) Stats + JobCostCache every ~30 polls (heavier payloads).
	const unsigned int counter = s_poll_counter.fetch_add(1, std::memory_order_relaxed) + 1;
	if (counter % 30 == 0) {
		Array stats_payload;
		stats_payload.append(get_stats_snapshot());
		dbg->send_message("gd_job_system:stats", stats_payload);
		dbg->send_message("gd_job_system:jcc", get_job_cost_cache_slots());
	}
}

Dictionary JobSystem::get_stats_snapshot() {
	js::JobSystemStatsSnapshot s;
	js::GetStatsSnapshot(&s);
	Dictionary d;
	// Keep this in sync with the Stats tab in the editor debugger plugin.
	d["published_jobs"] = (uint64_t)s.publishedJobs;
	d["frame_tasks_submitted"] = (uint64_t)s.frameTasksSubmitted;
	d["frame_tasks_completed"] = (uint64_t)s.frameTasksCompleted;
	d["tiles_total"] = (uint64_t)s.totalTilesPublished;
	d["tiles_local"] = (uint64_t)s.localTiles;
	d["tiles_stolen"] = (uint64_t)s.stolenTiles;
	d["tiles_assist"] = (uint64_t)s.assistTiles;
	d["active_workers_peak"] = (uint64_t)s.activeWorkersPeak;
	d["steal_attempts"] = (uint64_t)s.stealAttempts;
	d["steal_successes"] = (uint64_t)s.stealSuccesses;
	d["park_wake"] = (uint64_t)s.parkWakeCount;
	d["wake_latency_ns"] = (uint64_t)s.wakeLatencyEwmaNs;
	d["per_range_exec_ns"] = (uint64_t)s.perRangeExecEwmaNs;
	d["assist_pct"] = (uint64_t)s.assistExecPctEwma;
	d["worker_executed_ranges"] = (uint64_t)s.workerExecutedRanges;
	d["main_executed_ranges"] = (uint64_t)s.mainExecutedRanges;
	return d;
}

Array JobSystem::get_job_cost_cache_slots() {
	Array out;
	for (int i = 0; i < js::kJobCostSlots; i++) {
		const uint32_t h = js::g_jobCostCache.slotHash[i].load(std::memory_order_relaxed);
		if (h == 0) {
			continue;
		}
		Dictionary slot;
		slot["slot"] = i;
		slot["hash"] = (uint32_t)h;
		const uint8_t mode = js::g_jobCostCache.slotMode[i].load(std::memory_order_relaxed);
		slot["mode"] = (int)mode;
		slot["per_elem_ns"] = js::g_jobCostCache.GetPerElemCost(h);
		slot["per_tile_ns"] = js::g_jobCostCache.GetPerTileCost(h);
		out.append(slot);
	}
	return out;
}

} // namespace godot
