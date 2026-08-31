#pragma once

#include <cstdint>

// C export layer for C# P/Invoke (see docs/CSharp-PInvoke绑定设计.md).
// Forward-only wrappers over the JobSystem kernel; the kernel is untouched.

#ifdef _WIN32
#ifdef GDJS_EXPORTS
#define GDJS_API __declspec(dllexport)
#else
#define GDJS_API __declspec(dllimport)
#endif
#else
#define GDJS_API __attribute__((visibility("default")))
#endif

extern "C" {

typedef void (*GDJS_JobFunc)(void *context);
typedef void (*GDJS_IndexJobFunc)(void *context, int index);
typedef void (*GDJS_BatchJobFunc)(void *context, int start, int count);
typedef void (*GDJS_CleanupFunc)(void *context);

GDJS_API void GDJS_Initialize(int threads);
GDJS_API void GDJS_Shutdown(void);
GDJS_API int GDJS_GetWorkerCount(void);

GDJS_API void *GDJS_Schedule(GDJS_JobFunc func, void *context, GDJS_CleanupFunc cleanup, void *dependency);
GDJS_API void *GDJS_ScheduleFor(GDJS_IndexJobFunc func, void *context, GDJS_CleanupFunc cleanup, int length, void *dependency);
GDJS_API void *GDJS_ScheduleParallelForBatch(GDJS_BatchJobFunc func, void *context, GDJS_CleanupFunc cleanup, int length, int batchSize, void *dependency);

// handle = JobSystem::HandleState*; ownership transferred to the caller
// (caller must GDJS_Release it exactly once). Complete/IsCompleted flush
// pending implicit-batch jobs first (Unity ScheduleBatchedJobs semantics).
GDJS_API void GDJS_Complete(void *handle);
GDJS_API int GDJS_IsCompleted(void *handle);
GDJS_API void GDJS_Retain(void *handle);
GDJS_API void GDJS_Release(void *handle);
GDJS_API void *GDJS_CombineDependencies(void **handles, int count);

GDJS_API void GDJS_SetJobCostCacheEnabled(int enabled);
GDJS_API void GDJS_SetImplicitBatchEnabled(int enabled);
GDJS_API void GDJS_FlushPendingSubmits(void);

}
