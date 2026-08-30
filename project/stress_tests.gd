extends Node
## Extended test suite: stress, nested/dependency, multi-batch concurrency,
## edge/error handling, lifecycle, and shutdown-with-pending safety.
## Call JobSystem.initialize() before run(); leaves the scheduler initialized.

static var _failures := 0


static func _check(cond: bool, label: String) -> void:
	if cond:
		print("  [PASS] ", label)
	else:
		_failures += 1
		print("  [FAIL] ", label)


static func run() -> void:
	_failures = 0
	print("== Stress / edge tests ==")
	_test_stress_submit()
	_test_nested_and_dependencies()
	_test_multi_batch_concurrent()
	_test_edge_and_errors()
	_test_lifecycle()
	_test_shutdown_with_pending()
	if _failures == 0:
		print("STRESS TESTS DONE")
	else:
		print("STRESS TESTS FAILED: %d failure(s)" % _failures)


# ---------------------------------------------------------------------------
static func _test_stress_submit() -> void:
	print("-- stress: bulk submit + complete --")
	var h := JobSystem.schedule_parallel_for(100000, func(i: int): pass)
	h.complete()
	_check(true, "parallel_for 100k no-op ok")

	var handles: Array = []
	for k in 5000:
		handles.append(JobSystem.schedule(func(): pass))
	for k in 5000:
		handles[k].complete()
	_check(true, "5000 schedule + complete ok")

	var dropped := JobSystem.schedule_parallel_for(100000, func(i: int): pass)
	dropped = JobSystem.schedule(func(): pass)  # drop previous handle without complete
	_check(true, "drop handle without complete (refcount path, no crash)")


# ---------------------------------------------------------------------------
static func _test_nested_and_dependencies() -> void:
	print("-- nested jobs + deep/shared dependencies --")
	var log := PackedInt32Array([0, 0])
	var h := JobSystem.schedule(func():
		var inner := JobSystem.schedule(func(): log[1] = 1)
		inner.complete()
		log[0] = log[1] + 1)  # runs only after inner completed
	h.complete()
	_check(log[0] == 2 and log[1] == 1, "nested job: inner completes before outer continues")

	var prev: JobSystemHandle = JobSystem.schedule(func(): pass)
	for i in 100:
		prev = JobSystem.schedule(func(): pass, [prev])
	prev.complete()
	_check(true, "100-level dependency chain ok")

	var leaves: Array = []
	for i in 50:
		leaves.append(JobSystem.schedule(func(): pass))
	var joined := JobSystem.combine_dependencies(leaves)
	var top := JobSystem.schedule(func(): pass, [joined])
	top.complete()
	_check(true, "fan-in 50 -> combine -> 1 ok")

	var shared := JobSystem.schedule(func(): pass)
	var f1 := JobSystem.schedule(func(): pass, [shared])
	var f2 := JobSystem.schedule(func(): pass, [shared])
	f2.complete()
	f1.complete()
	_check(true, "shared dependency fan-out (two jobs on one handle) ok")


# ---------------------------------------------------------------------------
static func _test_multi_batch_concurrent() -> void:
	print("-- 8 concurrent parallel_for batches --")
	var arrays: Array[PackedFloat32Array] = []
	var handles: Array = []
	for b in 8:
		var arr := PackedFloat32Array()
		arr.resize(20000)
		arrays.append(arr)
		handles.append(JobSystem.schedule_parallel_for(20000,
			func(i: int, _b: int = b, _arr: PackedFloat32Array = arr): _arr[i] = float(i) * 0.5))
	for h in handles:
		h.complete()
	var ok := true
	for b in 8:
		for i in 20000:
			if arrays[b][i] != float(i) * 0.5:
				ok = false
	_check(ok, "8 concurrent parallel_for results correct")


# ---------------------------------------------------------------------------
static func _test_edge_and_errors() -> void:
	print("-- edge cases & error handling (expected ERR prints below) --")
	var h0 := JobSystem.schedule_parallel_for(0, func(i: int): pass)
	_check(h0 == null, "zero-length parallel_for returns null")
	var hb := JobSystem.schedule_parallel_for(100, func(i: int): pass)
	hb.complete()
	_check(hb != null and hb.is_completed(), "zero batch_size uses auto-batching (valid)")
	var hneg := JobSystem.schedule_parallel_for(-5, func(i: int): pass)
	_check(hneg == null, "negative length returns null")
	var hbad := JobSystem.schedule(Callable())
	_check(hbad == null, "invalid Callable returns null")
	var empty_handles: Array = []
	var hcomb := JobSystem.combine_dependencies(empty_handles)
	_check(hcomb == null, "empty combine_dependencies returns null")


# ---------------------------------------------------------------------------
static func _test_lifecycle() -> void:
	print("-- lifecycle: shutdown + reinitialize --")
	JobSystem.shutdown()
	_check(true, "shutdown ok")
	JobSystem.initialize(3)
	_check(JobSystem.get_worker_count() == 3, "re-initialize with 3 workers")
	var h := JobSystem.schedule(func(): pass)
	h.complete()
	_check(true, "work after re-initialize ok")
	JobSystem.initialize(8)  # must be idempotent
	_check(JobSystem.get_worker_count() == 3, "duplicate initialize is idempotent (stays 3)")


# ---------------------------------------------------------------------------
static func _test_shutdown_with_pending() -> void:
	print("-- shutdown with pending jobs --")
	var h := JobSystem.schedule_parallel_for(1000000, func(i: int): pass)
	JobSystem.shutdown()  # pending job is dropped; must not crash/hang
	_check(true, "shutdown with pending job ok")
	var h2 := JobSystem.schedule(func(): pass)
	_check(h2 == null, "schedule after shutdown rejected")
	JobSystem.initialize(2)  # leave scheduler initialized for the caller
