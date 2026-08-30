@tool
extends RefCounted
## JobCostCache 标签页：自适应 tile 学习策略的观测面板。
## 数据来源：运行时推送的 gd_job_system:jcc（JobSystem.get_job_cost_cache_slots）。
## 列：Slot / FuncHash / Mode（learn|parallel|MEM-BOUND）/ perElem ns / perTile ns。
## perElem = 每元素执行成本 EWMA；perTile = 每 tile 固定开销 C_fixed（两因子模型）。
## Toggle 按钮：编辑器进程内切换开关（JobSystem.set_job_cost_cache_enabled）。

var tree: Tree
var _state_label: Label


func build() -> Control:
	var page := VBoxContainer.new()
	page.name = "JobCostCache"
	var bar := HBoxContainer.new()
	var btn := Button.new()
	btn.text = "Toggle"
	btn.pressed.connect(func():
		JobSystem.set_job_cost_cache_enabled(not JobSystem.is_job_cost_cache_enabled())
		update(JobSystem.get_job_cost_cache_slots()))
	bar.add_child(btn)
	_state_label = Label.new()
	bar.add_child(_state_label)
	page.add_child(bar)
	tree = Tree.new()
	tree.set_columns(5)
	tree.set_column_titles_visible(true)
	var cols := ["Slot", "FuncHash", "Mode", "perElem ns", "perTile ns"]
	for idx in cols.size():
		tree.set_column_title(idx, cols[idx])
	tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	page.add_child(tree)
	return page


func update(slots: Array) -> void:
	_state_label.text = "ON" if JobSystem.is_job_cost_cache_enabled() else "OFF"
	tree.clear()
	var root := tree.create_item()
	root.set_text(0, "JobCostCache slots")
	for s in slots:
		var item := tree.create_item(root)
		item.set_text(0, str(s["slot"]))
		item.set_text(1, "0x%08X" % int(s["hash"]))
		var mode: int = s["mode"]
		var mode_str := "learn"
		if mode == 1:
			mode_str = "parallel"
		elif mode == 2:
			mode_str = "MEM-BOUND"
		item.set_text(2, mode_str)
		item.set_text(3, "%.3f" % float(s["per_elem_ns"]))
		item.set_text(4, "%.3f" % float(s["per_tile_ns"]))
