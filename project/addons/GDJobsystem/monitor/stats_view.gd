@tool
extends RefCounted
## Stats 标签页：调度器统计计数器表。
## 数据来源：运行时推送的 gd_job_system:stats（每 30 帧），或
## 手动点 Refresh（在编辑器进程调用 JobSystem.get_stats_snapshot()）。
## 字段与 C++ JobSystemStatsSnapshot 对应（见 src/job_system.cpp）。

var tree: Tree


func build() -> Control:
	var page := VBoxContainer.new()
	page.name = "Stats"
	var refresh := Button.new()
	refresh.text = "Refresh"
	refresh.pressed.connect(func(): update(JobSystem.get_stats_snapshot()))
	page.add_child(refresh)
	tree = Tree.new()
	tree.set_columns(2)
	tree.set_column_titles_visible(true)
	tree.set_column_title(0, "Metric")
	tree.set_column_title(1, "Value")
	tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	page.add_child(tree)
	return page


func update(s: Dictionary) -> void:
	tree.clear()
	var root := tree.create_item()
	root.set_text(0, "JobSystem Statistics")
	var rows := [
		["Published Jobs", str(s.get("published_jobs", 0))],
		["Frame Tasks", "%s / %s" % [s.get("frame_tasks_submitted", 0), s.get("frame_tasks_completed", 0)]],
		["Tiles Total", str(s.get("tiles_total", 0))],
		["Tiles Local", str(s.get("tiles_local", 0))],
		["Tiles Stolen", str(s.get("tiles_stolen", 0))],
		["Tiles Assist", str(s.get("tiles_assist", 0))],
		["Active Peak", str(s.get("active_workers_peak", 0))],
		["Steal Attempts", str(s.get("steal_attempts", 0))],
		["Steal Success", str(s.get("steal_successes", 0))],
		["Park/Wake", str(s.get("park_wake", 0))],
		["Wake Latency", "%.1fus" % (float(s.get("wake_latency_ns", 0)) / 1000.0)],
		["Per-Range Exec", "%.1fus" % (float(s.get("per_range_exec_ns", 0)) / 1000.0)],
		["Assist %", str(s.get("assist_pct", 0))],
		["Exec Ranges (W/M)", "%s / %s" % [s.get("worker_executed_ranges", 0), s.get("main_executed_ranges", 0)]],
	]
	for r in rows:
		var item := tree.create_item(root)
		item.set_text(0, r[0])
		item.set_text(1, r[1])
