extends Node
## Bridge used by CSharpBench.cs: runs the identical per-element math through the
## GDScript JobSystem facade so it can be compared against the C# P/Invoke path
## (both share the same native kernel and scheduler).

static func _element_value(i: int) -> float:
	var v := float(i) * 0.0001 + 0.5
	return sin(v) * 1.5 + cos(v * 0.5) * 0.5 + sqrt(abs(v) + 1.0)


func ensure_initialized() -> void:
	# Idempotent: if the scheduler is already up (e.g. via C# P/Invoke), no-op.
	JobSystem.initialize()


func run_job_bench(elements: int) -> Dictionary:
	var data := PackedFloat32Array()
	data.resize(elements)
	var t0 := Time.get_ticks_usec()
	var h := JobSystem.schedule_parallel_for(elements, func(i: int):
		data[i] = _element_value(i))
	h.complete()
	var us := Time.get_ticks_usec() - t0
	var sum := 0.0
	for i in data.size():
		sum += data[i]
	return {"us": us, "sum": sum}
