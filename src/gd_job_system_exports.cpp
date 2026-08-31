#include "gd_job_system_exports.h"

#include "JobSystem.h"
#include "JobSystemInternal.h"

#include <vector>

namespace js = ::JobSystem;

namespace {

js::HandleState *from_handle(void *ptr) {
	return static_cast<js::HandleState *>(ptr);
}

// Transfer a JobHandle's state to an opaque pointer with a +1 reference for
// the caller (same convention as EntJoy's toHandle in Exports.cpp).
void *to_handle(const js::JobHandle &handle) {
	if (auto *state = handle.State()) {
		js::JobHandle::Acquire(state);
		return static_cast<void *>(state);
	}
	return nullptr;
}

} // namespace

extern "C" {

void GDJS_Initialize(int threads) {
	js::Scheduler::Initialize(threads);
}

void GDJS_Shutdown(void) {
	js::Scheduler::Shutdown();
}

int GDJS_GetWorkerCount(void) {
	return js::CurrentWorkerCount();
}

void *GDJS_Schedule(GDJS_JobFunc func, void *context, GDJS_CleanupFunc cleanup, void *dependency) {
	js::JobHandle dep;
	if (dependency) {
		dep = js::JobHandle(from_handle(dependency), true);
	}
	auto handle = js::Scheduler::Schedule(func, context, cleanup, dep);
	return to_handle(handle);
}

void *GDJS_ScheduleFor(GDJS_IndexJobFunc func, void *context, GDJS_CleanupFunc cleanup, int length, void *dependency) {
	js::JobHandle dep;
	if (dependency) {
		dep = js::JobHandle(from_handle(dependency), true);
	}
	auto handle = js::Scheduler::ScheduleFor(func, context, length, cleanup, dep);
	return to_handle(handle);
}

void *GDJS_ScheduleParallelForBatch(GDJS_BatchJobFunc func, void *context, GDJS_CleanupFunc cleanup, int length, int batchSize, void *dependency) {
	js::JobHandle dep;
	if (dependency) {
		dep = js::JobHandle(from_handle(dependency), true);
	}
	auto handle = js::Scheduler::ScheduleParallelForBatch(func, context, length, batchSize, cleanup, dep);
	return to_handle(handle);
}

void GDJS_Complete(void *handle) {
	// Implicit batching: flush pending jobs first (prevents waiting forever).
	js::FlushPendingSubmits();
	if (handle) {
		js::JobHandle(from_handle(handle), true).Complete();
	}
}

int GDJS_IsCompleted(void *handle) {
	// Implicit batching: flush first so a pending job is not reported incomplete.
	js::FlushPendingSubmits();
	if (!handle) {
		return 1;
	}
	return from_handle(handle)->completed.load(std::memory_order_acquire) ? 1 : 0;
}

void GDJS_Retain(void *handle) {
	if (handle) {
		js::JobHandle::Acquire(from_handle(handle));
	}
}

void GDJS_Release(void *handle) {
	if (handle) {
		js::JobHandle::Release(from_handle(handle));
	}
}

void *GDJS_CombineDependencies(void **handles, int count) {
	if (!handles || count <= 0) {
		return nullptr;
	}
	std::vector<js::JobHandle> vec;
	vec.reserve(static_cast<size_t>(count));
	for (int i = 0; i < count; i++) {
		vec.emplace_back(from_handle(handles[i]), true);
	}
	return to_handle(js::JobHandle::CombineDependencies(vec));
}

void GDJS_SetJobCostCacheEnabled(int enabled) {
	js::g_jobCostCacheEnabled.store(enabled != 0, std::memory_order_release);
}

void GDJS_SetImplicitBatchEnabled(int enabled) {
	if (enabled) {
		js::g_implicitBatchEnabled.store(true, std::memory_order_relaxed);
		return;
	}
	// Disable: drain the backlog first to avoid hanging/leaking, then clear.
	js::FlushPendingSubmits();
	js::g_implicitBatchEnabled.store(false, std::memory_order_relaxed);
}

void GDJS_FlushPendingSubmits(void) {
	js::FlushPendingSubmits();
}

} // extern "C"
