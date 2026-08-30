extends Node
## Frame-driven Job demo: submits one parallel job per tick, completes it
## at the start of the next tick (classic game-loop job pattern). Watch the
## JobSystem 监控器 tab in the Debugger while this runs.

const ELEMENTS := 8192
const BATCH := 0  # auto

var _data: PackedFloat32Array
var _pending: Array[JobSystemHandle] = []
var _frame := 0
var _sum := 0.0


func _ready() -> void:
	JobSystem.initialize()
	_data.resize(ELEMENTS)
	print("Job demo started: ", ELEMENTS, " elements, ", JobSystem.get_worker_count(), " workers")


func _process(_delta: float) -> void:
	_frame += 1

	# 1) Finish last tick's job (blocking wait is the simple pattern).
	for h in _pending:
		h.complete()
	_pending.clear()

	# 2) Submit this tick's job: update the buffer in parallel.
	#    BATCH = 0 -> scheduler picks the tile size automatically.
	var tick := _frame
	var h := JobSystem.schedule_parallel_for(ELEMENTS, func(i: int):
		_data[i] = sin(float(i) * 0.01 + float(tick) * 0.05) * 0.5 + 0.5)
	_pending.append(h)

	# 3) Feed the editor's JobSystem 监控器 tab (worker state + timeline).
	JobSystem.debugger_poll()

	# 4) End-of-frame flush (no-op unless implicit batching is enabled).
	JobSystem.flush_pending_submits()

	# Every 60 ticks, fold the buffer (on the main thread) and report.
	if _frame % 60 == 0:
		_sum = 0.0
		for i in ELEMENTS:
			_sum += _data[i]
		print("tick %d: buffer sum = %.2f" % [_frame, _sum])


func _exit_tree() -> void:
	JobSystem.shutdown()
