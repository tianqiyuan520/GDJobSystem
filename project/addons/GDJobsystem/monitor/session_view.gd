@tool
extends RefCounted
## 单个调试会话的监控器 UI：顶部统计 + 四个标签页
## （Timeline / Stats / Activity / JobCostCache）+ Pause 控制。
##
## 布局：
##   root (VBoxContainer)
##   ├─ _stats_label           顶部统计（workers / active）
##   ├─ TabContainer
##   │  ├─ Timeline 页        甘特图（timeline.gd）+ 选中详情（可拖拽分隔条）
##   │  ├─ Stats 页           stats_view.gd
##   │  ├─ Activity 页        activity_view.gd
##   │  └─ JobCostCache 页    jcc_view.gd
##
## Pause：set_paused(on) 同时
##   1. 发控制消息给游戏（gd_job_system_ctl:set_paused）→ 游戏停止发送数据
##   2. 冻结甘特图视图（timeline.set_paused / set_live）
##
## 详情（_show_detail）：点击甘特图段后显示，含同 batch 的整批统计
## （端到端耗时 / 总执行 / 窗口数 / 泳道数）。

const SPAN_PRESETS_MS := [500.0, 1000.0, 2000.0, 4000.0, 8000.0, 15000.0, 30000.0, 60000.0, 120000.0]
const SPAN_PRESET_LABELS := ["0.5s", "1s", "2s", "4s", "8s", "15s", "30s", "60s", "120s"]
const StatsView = preload("stats_view.gd")
const ActivityView = preload("activity_view.gd")
const JccView = preload("jcc_view.gd")

var root: VBoxContainer
var session: EditorDebuggerSession
var frozen := false

var _stats_label: Label
var _timeline: JobTimeline
var _detail: RichTextLabel
var _stats_view: StatsView
var _activity_view: ActivityView
var _jcc_view: JccView


func _init(p_session: EditorDebuggerSession) -> void:
	session = p_session
	_stats_view = preload("stats_view.gd").new()
	_activity_view = preload("activity_view.gd").new()
	_jcc_view = preload("jcc_view.gd").new()
	_build_ui()


func _build_ui() -> void:
	root = VBoxContainer.new()
	root.name = "JobSystem 监控器"
	root.add_theme_constant_override("separation", 4)

	_stats_label = Label.new()
	_stats_label.add_theme_font_size_override("font_size", 25)
	_stats_label.text = "JobSystem 监控器"
	root.add_child(_stats_label)

	var tabs := TabContainer.new()
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(tabs)
	tabs.add_child(_build_timeline_tab())
	tabs.add_child(_stats_view.build())
	tabs.add_child(_activity_view.build())
	tabs.add_child(_jcc_view.build())


func _build_timeline_tab() -> Control:
	var page := VBoxContainer.new()
	page.name = "Timeline"

	var toolbar := HBoxContainer.new()
	var btn_pause := Button.new()
	btn_pause.text = "Pause (hold)"
	btn_pause.toggle_mode = true
	btn_pause.toggled.connect(func(on: bool): set_paused(on))
	toolbar.add_child(btn_pause)
	var btn_live := Button.new()
	btn_live.text = "Live"
	btn_live.pressed.connect(func(): set_paused(false))
	toolbar.add_child(btn_live)
	var preset := OptionButton.new()
	for label in SPAN_PRESET_LABELS:
		preset.add_item(label)
	preset.selected = 4
	preset.item_selected.connect(func(idx: int): _timeline.set_span(SPAN_PRESETS_MS[idx]))
	toolbar.add_child(preset)
	var hint := Label.new()
	hint.text = "   Ctrl+wheel=zoom  drag=pan  click=inspect"
	hint.add_theme_font_size_override("font_size", 20)
	toolbar.add_child(hint)
	page.add_child(toolbar)

	var vsplit := VSplitContainer.new()
	vsplit.size_flags_vertical = Control.SIZE_EXPAND_FILL
	page.add_child(vsplit)

	_timeline = preload("timeline.gd").new()
	_timeline.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vsplit.add_child(_timeline)
	_timeline.selected.connect(func(seg: Dictionary): _show_detail(seg))

	var detail_scroll := ScrollContainer.new()
	detail_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vsplit.add_child(detail_scroll)
	_detail = RichTextLabel.new()
	_detail.bbcode_enabled = true
	_detail.scroll_active = true
	_detail.fit_content = true
	_detail.selection_enabled = true
	_detail.context_menu_enabled = true
	_detail.add_theme_font_size_override("normal_font_size", 23)
	_detail.text = "Click a segment to inspect"
	detail_scroll.add_child(_detail)
	_detail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vsplit.split_offset = 300

	return page


func set_paused(on: bool) -> void:
	frozen = on
	# Tell the running game to stop streaming entirely.
	session.send_message("gd_job_system_ctl:set_paused", [on])
	if on:
		_timeline.set_paused()
	else:
		_timeline.set_live()


func on_snapshot(data: Array) -> void:
	var active := 0
	for w in data:
		if w["active"]:
			active += 1
	_stats_label.text = "JobSystem 监控器    workers: %d    active: %d" % [data.size(), active]
	# W rows = workers - 1, plus the M lane -> total rows == thread count.
	_timeline.lane_count = clampi(data.size() - 1, 1, 64)


func on_timeline(data: Array) -> void:
	_timeline.add_segments(data)
	_activity_view.append(data)


func on_stats(data: Array) -> void:
	if data.size() > 0:
		_stats_view.update(data[0])


func on_jcc(data: Array) -> void:
	_jcc_view.update(data)


func _show_detail(seg: Dictionary) -> void:
	var lane: int = seg["lane"]
	var where := "M (main thread)" if lane >= _timeline.lane_count else "W%d (worker)" % lane
	var dur := float(seg["end_ms"]) - float(seg["start_ms"])
	var lines := PackedStringArray()
	lines.append("[color=#59c8ff]Selected Job #%d[/color]" % int(seg["batch_id"]))
	lines.append("Where    : %s" % where)
	lines.append("Duration : %.3f ms" % dur)
	lines.append("Tiles    : %d (this worker)" % int(seg["tiles"]))
	lines.append("Workers  : %d" % int(seg["workers"]))
	# Whole-batch summary: scan all windows of the same batch.
	var batch_start := INF
	var batch_end := -INF
	var total_exec := 0.0
	var win_count := 0
	var lane_set := {}
	for s in _timeline.segments:
		if int(s["batch_id"]) != int(seg["batch_id"]):
			continue
		var st := float(s["start_ms"])
		var en := float(s["end_ms"])
		batch_start = minf(batch_start, st)
		batch_end = maxf(batch_end, en)
		total_exec += en - st
		win_count += 1
		lane_set[int(s["lane"])] = true
	if win_count > 0:
		lines.append("")
		lines.append("[color=#e6b84c]Batch total  : %.3f ms (end-to-end)[/color]" % (batch_end - batch_start))
		lines.append("Total exec   : %.3f ms (%d windows, %d lanes)" % [total_exec, win_count, lane_set.size()])
	_detail.text = "\n".join(lines)
