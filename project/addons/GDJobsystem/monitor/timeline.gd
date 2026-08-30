class_name JobTimeline
extends Control
## 可缩放甘特图（移植自 EntJoy 的 ImGui 监控器设计）。
##
## 视图模型：最新活动位于屏幕中央，历史向左滚动（profiler 风格）
##   win_left = center - span/2,  win_right = center + span/2
##
## 交互：
##   - Ctrl+滚轮缩放（锚点时间保持，平滑动画）
##   - 左键拖拽平移（不自动 Pause；拖出控件边界仍有效）
##   - 单击选中段（selected 信号）；双击跳回最新
##   - Pause/Live 由外部（session_view.gd）控制
##
## 泳道：W0..W(n-1) + M（主线程）。lane_count = 线程数-1 时
## 总行数 = 线程数（最后一个 worker 的段与 M 行冲突被丢弃，见 _row_of）。
##
## 性能策略：
##   - 重绘节流（REDRAW_INTERVAL，交互时即时）
##   - 可视段数超 AGG_THRESHOLD 时切换聚合模式（按泳道分桶成密度条）
##   - 段数据不设上限（保留游戏开始至今全部）
##
## 时间标签相对窗口左界显示（拖拽/缩放时稳定）。

signal selected(segment: Dictionary)
signal view_state_changed(paused: bool, span_ms: float)

const LANE_H := 24.0
const TOP_PAD := 26.0
const LEFT_PAD := 54.0
const BG_COLOR := Color(0.11, 0.12, 0.13)
const LANE_ALT := Color(0.145, 0.155, 0.165)
const GRID_COLOR := Color(0.6, 0.6, 0.7, 0.32)
const TEXT_COLOR := Color(0.82, 0.84, 0.87)
const DIRECT_COLOR := Color(0.47, 0.78, 1.0, 0.6)
const SEL_COLOR := Color(1.0, 1.0, 1.0)
const FONT_SIZE := 14
const REDRAW_INTERVAL := 3
const AGG_THRESHOLD := 800
const AGG_BUCKETS := 200

var segments: Array = []
var lane_count := 4
var paused := false
var span_ms := 8000.0
var _target_span_ms := 8000.0
var _center_ms := 0.0
var _aligned_once := false
var _dragging := false
var _drag_start_x := 0
var _drag_base_center := 0.0
var _selected_index := -1
var _redraw_tick := 0
var _lane_h := LANE_H


func add_segments(new_segs: Array) -> void:
	if new_segs.is_empty() or paused:
		return
	segments.append_array(new_segs)
	if not _aligned_once:
		_center_ms = _latest_end()
		_aligned_once = true
		queue_redraw()


func set_live() -> void:
	paused = false
	_center_ms = _latest_end()
	view_state_changed.emit(false, span_ms)
	queue_redraw()


func set_paused() -> void:
	if not paused:
		paused = true
		view_state_changed.emit(true, span_ms)
		queue_redraw()


func set_span(ms: float) -> void:
	_target_span_ms = clampf(ms, 200.0, 120000.0)


func _ready() -> void:
	clip_contents = true
	set_process(true)
	set_live()


func _process(delta: float) -> void:
	var diff := _target_span_ms - span_ms
	var animating := absf(diff) >= 1.0
	if animating:
		span_ms = lerpf(span_ms, _target_span_ms, minf(1.0, delta * 10.0))
	if _dragging:
		var plot_w := maxf(size.x - LEFT_PAD, 1.0)
		_center_ms = _drag_base_center + float(_drag_start_x - get_local_mouse_position().x) / plot_w * span_ms
	if _dragging or animating:
		queue_redraw()
	else:
		_redraw_tick += 1
		if _redraw_tick >= REDRAW_INTERVAL:
			_redraw_tick = 0
			queue_redraw()


func _latest_end() -> float:
	var t := 0.0
	for s in segments:
		t = maxf(t, float(s["end_ms"]))
	return t


func _win_left() -> float:
	return _center_ms - span_ms * 0.5


func _win_right() -> float:
	return _center_ms + span_ms * 0.5


func _lane_count_drawn() -> int:
	return lane_count + 1  # W rows + M lane


# Map a kernel lane to a drawn row. With lane_count = workers - 1 the total
# row count equals the thread count: W0..W(workers-2) + M. The last worker
# (lane == lane_count) is dropped because its row would collide with M.
func _row_of(lane: int) -> int:
	if lane < lane_count:
		return lane
	if lane == lane_count + 1:  # M lane index == worker count == lane_count + 1
		return lane_count
	return -1


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.ctrl_pressed:
			if mb.button_index == MOUSE_BUTTON_WHEEL_UP:
				_zoom_at(mb.position.x, 0.85)
			elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				_zoom_at(mb.position.x, 1.18)
		elif mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_dragging = true
				_drag_start_x = int(get_local_mouse_position().x)
				_drag_base_center = _center_ms
			else:
				if _dragging and absf(get_local_mouse_position().x - _drag_start_x) < 3.0:
					_pick_at(mb.position)
				_dragging = false
			if mb.double_click:
				set_live()


func _zoom_at(px_x: float, factor: float) -> void:
	var plot_w := maxf(size.x - LEFT_PAD, 1.0)
	var frac := (px_x - LEFT_PAD) / plot_w
	var anchor_t := _win_left() + frac * span_ms
	_target_span_ms = clampf(span_ms * factor, 200.0, 120000.0)
	_center_ms = anchor_t + (0.5 - frac) * _target_span_ms


func _pick_at(p: Vector2) -> void:
	var win_left := _win_left()
	var win_right := _win_right()
	var plot_w := maxf(size.x - LEFT_PAD, 1.0)
	for i in segments.size():
		var s: Dictionary = segments[i]
		var row := _row_of(int(s["lane"]))
		if row < 0:
			continue
		if float(s["end_ms"]) < win_left or float(s["start_ms"]) > win_right:
			continue
		var x0 := LEFT_PAD + (float(s["start_ms"]) - win_left) / span_ms * plot_w
		var x1 := LEFT_PAD + (float(s["end_ms"]) - win_left) / span_ms * plot_w
		var y0 := TOP_PAD + row * _lane_h + 2.0
		if p.x >= x0 and p.x <= x1 and p.y >= y0 and p.y <= y0 + _lane_h - 4.0:
			_selected_index = i
			queue_redraw()
			selected.emit(s)
			return
	_selected_index = -1
	queue_redraw()


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), BG_COLOR)
	if span_ms <= 0.0:
		return
	if lane_count > 0:
		var fill_h := (size.y - TOP_PAD) / _lane_count_drawn()
		_lane_h = maxf(minf(fill_h, LANE_H * 2.0), 14.0)
	var win_left := _win_left()
	var win_right := _win_right()
	var plot_w := maxf(size.x - LEFT_PAD, 1.0)

	var step := 100.0
	if span_ms > 20000.0:
		step = 2000.0
	elif span_ms > 5000.0:
		step = 500.0
	elif span_ms < 1500.0:
		step = 50.0
	var t: float = win_left - fmod(win_left, step)
	while t <= win_right:
		var px: float = LEFT_PAD + (t - win_left) / span_ms * plot_w
		draw_line(Vector2(px, TOP_PAD - 4), Vector2(px, size.y), GRID_COLOR, 1.0)
		if t >= win_left:
			draw_string(ThemeDB.fallback_font, Vector2(px + 3, TOP_PAD - 9),
					_ts(t), HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, TEXT_COLOR)
		t += step

	var lanes := _lane_count_drawn()
	for row in lanes:
		var y := TOP_PAD + row * _lane_h
		if row % 2 == 1:
			draw_rect(Rect2(0, y, size.x, _lane_h), LANE_ALT)
		draw_line(Vector2(0, y + _lane_h), Vector2(size.x, y + _lane_h), GRID_COLOR, 1.0)
		var label := "M" if row == lane_count else "W%d" % row
		draw_string(ThemeDB.fallback_font, Vector2(LEFT_PAD * 0.22, y + _lane_h * 0.7),
				label, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, TEXT_COLOR)

	var visible: Array = []
	for i in range(segments.size() - 1, -1, -1):
		var s: Dictionary = segments[i]
		var row := _row_of(int(s["lane"]))
		if row < 0:
			continue
		if float(s["end_ms"]) < win_left:
			break
		if float(s["start_ms"]) > win_right:
			continue
		visible.append(s)
	if visible.size() > AGG_THRESHOLD:
		_draw_aggregated(visible, win_left, span_ms, plot_w, lanes)
	else:
		_draw_individual(visible, win_left, span_ms, plot_w, lanes)

	if _selected_index >= 0 and _selected_index < segments.size():
		var s: Dictionary = segments[_selected_index]
		var row := _row_of(int(s["lane"]))
		if row >= 0 and float(s["end_ms"]) >= win_left and float(s["start_ms"]) <= win_right:
			var x0 := LEFT_PAD + (float(s["start_ms"]) - win_left) / span_ms * plot_w
			var x1 := LEFT_PAD + (float(s["end_ms"]) - win_left) / span_ms * plot_w
			var y := TOP_PAD + row * _lane_h + 2.0
			draw_rect(Rect2(x0, y, maxf(x1 - x0, 2.0), _lane_h - 4.0), SEL_COLOR, false, 2.0)


func _draw_individual(visible: Array, win_left: float, span: float, plot_w: float, lanes: int) -> void:
	for s in visible:
		var row := _row_of(int(s["lane"]))
		if row < 0:
			continue
		var x0 := LEFT_PAD + (float(s["start_ms"]) - win_left) / span * plot_w
		var x1 := LEFT_PAD + (float(s["end_ms"]) - win_left) / span * plot_w
		if x1 < LEFT_PAD or x0 > size.x:
			continue
		var bw := maxf(x1 - x0, 2.0)
		var y := TOP_PAD + row * _lane_h + 2.0
		var col := DIRECT_COLOR if bool(s.get("direct", false)) \
				else _duration_color(float(s["end_ms"]) - float(s["start_ms"]))
		draw_rect(Rect2(x0, y, bw, _lane_h - 4.0), col)
		draw_rect(Rect2(x0, y, bw, _lane_h - 4.0), Color(0, 0, 0, 0.45), false, 1.0)
		if bw > 64.0:
			draw_string(ThemeDB.fallback_font, Vector2(x0 + 5, y + (_lane_h - 4.0) * 0.72),
					"%.2fms" % (float(s["end_ms"]) - float(s["start_ms"])),
					HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(1, 1, 1, 0.92))


func _draw_aggregated(visible: Array, win_left: float, span: float, plot_w: float, lanes: int) -> void:
	var bucket_w := span / AGG_BUCKETS
	var agg := {}
	for lane in lanes:
		var buckets := []
		buckets.resize(AGG_BUCKETS)
		for b in AGG_BUCKETS:
			buckets[b] = {"count": 0, "sum_dur": 0.0}
		agg[lane] = buckets
	for s in visible:
		var row := _row_of(int(s["lane"]))
		if row < 0:
			continue
		var st := float(s["start_ms"])
		var en := float(s["end_ms"])
		var dur := en - st
		var b0 := clampi(int((st - win_left) / bucket_w), 0, AGG_BUCKETS - 1)
		var b1 := clampi(int((en - win_left) / bucket_w), 0, AGG_BUCKETS - 1)
		for b in range(b0, b1 + 1):
			var cell: Dictionary = agg[row][b]
			cell["count"] += 1
			cell["sum_dur"] += dur
	for row in lanes:
		for b in AGG_BUCKETS:
			var cell: Dictionary = agg[row][b]
			var count: int = cell["count"]
			if count == 0:
				continue
			var x0 := LEFT_PAD + b * bucket_w / span * plot_w
			var x1 := LEFT_PAD + (b + 1) * bucket_w / span * plot_w
			var y := TOP_PAD + row * _lane_h + 2.0
			var avg_dur: float = cell["sum_dur"] / count
			var col := _duration_color(avg_dur)
			col.a = 0.25 + 0.65 * minf(1.0, count / 12.0)
			draw_rect(Rect2(x0, y, maxf(x1 - x0, 1.0), _lane_h - 4.0), col)


func _duration_color(dur_ms: float) -> Color:
	var hh := 0.0
	if dur_ms > 0.0:
		hh = log(1.0 + dur_ms) / log(11.0)
	hh = clampf(hh, 0.0, 1.0)
	return Color.from_hsv((1.0 - hh) * 120.0 / 360.0, 0.8, 0.9, 0.86)


func _ts(t: float) -> String:
	var rel := t - _win_left()
	if absf(rel) >= 1000.0:
		return "%.2fs" % (rel / 1000.0)
	return "%.0fms" % rel
