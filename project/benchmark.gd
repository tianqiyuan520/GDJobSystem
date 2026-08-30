extends Node
## Performance benchmark: Godot single-thread vs WorkerThreadPool vs GDJobSystem.
## All paths execute identical per-element GDScript math; results checksum-validated.
## Call JobSystem.initialize() before run(); leaves the scheduler initialized.

const ROUNDS := 5


static func _element_value(i: int) -> float:
	var v := float(i) * 0.0001 + 0.5
	return sin(v) * 1.5 + cos(v * 0.5) * 0.5 + sqrt(abs(v) + 1.0)


static func _compute_range(data: PackedFloat32Array, start: int, end: int) -> void:
	for i in range(start, end):
		data[i] = _element_value(i)


static func _checksum(data: PackedFloat32Array) -> float:
	var sum := 0.0
	for i in data.size():
		sum += data[i]
	return sum


static func _bench_single(data: PackedFloat32Array) -> int:
	var t0 := Time.get_ticks_usec()
	_compute_range(data, 0, data.size())
	return Time.get_ticks_usec() - t0


static func _bench_worker_pool(data: PackedFloat32Array, chunks: int) -> int:
	var t0 := Time.get_ticks_usec()
	var size := data.size()
	var per := ceili(float(size) / float(chunks))
	var task_ids: Array[int] = []
	for c in chunks:
		var s := c * per
		var e := mini(s + per, size)
		if s >= e:
			break
		task_ids.append(WorkerThreadPool.add_task(_compute_range.bind(data, s, e)))
	for tid in task_ids:
		WorkerThreadPool.wait_for_task_completion(tid)
	return Time.get_ticks_usec() - t0


static func _bench_job_system(data: PackedFloat32Array) -> int:
	# batch_size omitted -> 0 -> scheduler picks it automatically
	var t0 := Time.get_ticks_usec()
	var h := JobSystem.schedule_parallel_for(data.size(), func(i: int):
		data[i] = _element_value(i))
	h.complete()
	return Time.get_ticks_usec() - t0


# Case 1: three-way compare at one element count (rounded avg over N rounds)
static func _case_math_compare(elements: int, rounds: int) -> void:
	var workers := JobSystem.get_worker_count()
	var single_us := 0
	var pool_us := 0
	var job_us := 0
	var sum_single := 0.0
	var sum_pool := 0.0
	var sum_job := 0.0
	for r in rounds:
		var d1 := PackedFloat32Array()
		d1.resize(elements)
		var d2 := PackedFloat32Array()
		d2.resize(elements)
		var d3 := PackedFloat32Array()
		d3.resize(elements)
		single_us += _bench_single(d1)
		pool_us += _bench_worker_pool(d2, workers)
		job_us += _bench_job_system(d3)
		sum_single += _checksum(d1)
		sum_pool += _checksum(d2)
		sum_job += _checksum(d3)
	var same := absf(sum_single - sum_pool) < 1.0 and absf(sum_single - sum_job) < 1.0
	print("%-9d elem: single %8.2f ms | pool %8.2f ms (%5.2fx) | job %8.2f ms (%5.2fx) | checksum ok=%s" \
		% [elements, single_us / rounds / 1000.0, pool_us / rounds / 1000.0,
			single_us / float(pool_us), job_us / rounds / 1000.0, single_us / float(job_us), same])


# Case 2: scaling sweep (elements grow; same math)
static func _case_scaling() -> void:
	print("-- scaling sweep (auto batch) --")
	for elements in [100_000, 1_000_000, 4_000_000]:
		_case_math_compare(elements, 3)


# Case 3: scheduling throughput (5000 no-op tasks, no completion batching)
static func _case_throughput() -> void:
	print("-- throughput: 5000 no-op tasks --")
	var t0 := Time.get_ticks_usec()
	var handles: Array = []
	for k in 5000:
		handles.append(JobSystem.schedule(func(): pass))
	for k in 5000:
		handles[k].complete()
	var job_us := Time.get_ticks_usec() - t0
	t0 = Time.get_ticks_usec()
	var ids: Array[int] = []
	for k in 5000:
		ids.append(WorkerThreadPool.add_task(func(): pass))
	for id_ in ids:
		WorkerThreadPool.wait_for_task_completion(id_)
	var pool_us := Time.get_ticks_usec() - t0
	t0 = Time.get_ticks_usec()
	for k in 5000:
		pass
	var single_us := Time.get_ticks_usec() - t0
	print("  submit+wait x5000 : job %8.2f ms | pool %8.2f ms | single %6.2f ms" \
		% [job_us / 1000.0, pool_us / 1000.0, single_us / 1000.0])


# Case 4: sequential vs parallel for (JobSystem only)
static func _case_seq_vs_par() -> void:
	print("-- JobSystem schedule_for vs schedule_parallel_for (1M elements) --")
	var data := PackedFloat32Array()
	data.resize(1_000_000)
	var t0 := Time.get_ticks_usec()
	var h := JobSystem.schedule_for(data.size(), func(i: int): data[i] = _element_value(i))
	h.complete()
	var seq_us := Time.get_ticks_usec() - t0
	t0 = Time.get_ticks_usec()
	h = JobSystem.schedule_parallel_for(data.size(), func(i: int): data[i] = _element_value(i))
	h.complete()
	var par_us := Time.get_ticks_usec() - t0
	print("  schedule_for %.2f ms vs schedule_parallel_for %.2f ms (%.1fx)" \
		% [seq_us / 1000.0, par_us / 1000.0, seq_us / float(par_us)])


# Case 5: implicit batch on/off (200 bulk parallel_for jobs, EndFrame-style flush)
static func _case_implicit_batch() -> void:
	print("-- implicit batch on/off: 200 x parallel_for(20000 no-op) --")
	JobSystem.set_implicit_batch_enabled(false)
	var t0 := Time.get_ticks_usec()
	var handles: Array = []
	for k in 200:
		handles.append(JobSystem.schedule_parallel_for(20000, func(i: int): pass))
	for h in handles:
		h.complete()
	var off_us := Time.get_ticks_usec() - t0
	JobSystem.set_implicit_batch_enabled(true)
	t0 = Time.get_ticks_usec()
	handles.clear()
	for k in 200:
		handles.append(JobSystem.schedule_parallel_for(20000, func(i: int): pass))
	JobSystem.flush_pending_submits()  # end-of-frame flush
	for h in handles:
		h.complete()
	var on_us := Time.get_ticks_usec() - t0
	JobSystem.set_implicit_batch_enabled(false)
	print("  implicit off: %8.2f ms | on: %8.2f ms (%.2fx)" \
		% [off_us / 1000.0, on_us / 1000.0, off_us / float(on_us)])


static func run() -> void:
	print("== Benchmark: %d job workers / pool chunks, JobCostCache=%s ==" \
		% [JobSystem.get_worker_count(), JobSystem.is_job_cost_cache_enabled()])
	_case_math_compare(1_000_000, ROUNDS)
	_case_scaling()
	_case_throughput()
	_case_seq_vs_par()
	_case_implicit_batch()
	print("BENCHMARK DONE")
