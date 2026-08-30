extends Node

var _demo_timer := 0.0
var _demo_running := false


func _ready() -> void:
	print("GDJobSystem ", JobSystem.get_version())
	JobSystem.initialize(2)
	print("worker count: ", JobSystem.get_worker_count())

	# 1) Simple job
	var h := JobSystem.schedule(func(): print("  job A executed"))
	h.complete()
	print("job A completed: ", h.is_completed())

	# 2) Sequential for: write arr[i] = i
	var seq := PackedInt32Array()
	seq.resize(100)
	var hf := JobSystem.schedule_for(100, func(i: int): seq[i] = i)
	hf.complete()
	var seq_ok := true
	for i in 100:
		if seq[i] != i:
			seq_ok = false
	print("schedule_for ok: ", seq_ok)

	# 3) Parallel for: write out[i] = i (distinct slots, no races)
	var par := PackedInt32Array()
	par.resize(1000)
	var hp := JobSystem.schedule_parallel_for(1000, func(i: int): par[i] = i)
	hp.complete()
	var par_ok := true
	for i in 1000:
		if par[i] != i:
			par_ok = false
	print("schedule_parallel_for ok: ", par_ok)

	# 4) Dependency chain: stage2 runs only after stage1
	var log := PackedInt32Array([0, 0])
	var h1 := JobSystem.schedule(func(): log[0] = 1)
	var h2 := JobSystem.schedule(func(): log[1] = log[0] + 1, [h1])
	h2.complete()
	print("dependency ok: ", log[0] == 1 and log[1] == 2)

	# 5) combine_dependencies: c runs after a and b
	var a := JobSystem.schedule(func(): pass)
	var b := JobSystem.schedule(func(): pass)
	var ab := JobSystem.combine_dependencies([a, b])
	var c := JobSystem.schedule(func(): print("  combined job c executed"), [ab])
	c.complete()
	print("combine_dependencies ok: ", true)

	JobSystem.shutdown()
	print("ALL TESTS DONE")

	# 6) Performance benchmark vs Godot single-thread / WorkerThreadPool
	JobSystem.initialize()
	preload("res://benchmark.gd").run()
	JobSystem.shutdown()

	# 7) Demo mode: keep a few workers busy periodically so the editor's
	#    JobSystem debugger tab has live activity to show.
	JobSystem.initialize(4)
	_demo_running = true


func _process(delta: float) -> void:
	# Feed the editor's JobSystem debugger tab (no-op without a debugger).
	JobSystem.debugger_poll()
	if _demo_running:
		_demo_timer -= delta
		if _demo_timer <= 0.0:
			_demo_timer = 0.25
			for k in 4:
				JobSystem.schedule_parallel_for(20000, func(i: int): pass)
			JobSystem.flush_pending_submits()
