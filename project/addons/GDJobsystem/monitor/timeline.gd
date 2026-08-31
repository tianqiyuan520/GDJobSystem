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
## 性能策略（图像烘焙）：
##   - 重绘节流（REDRAW_INTERVAL，交互时即时）
##   - 窗口内段先按像素列聚合（每像素列 = 时间桶，每泳道一行），
##     写入 Image 后经 ImageTexture 一次性贴出；绘制成本与段数解耦
##     （段数只影响每次 O(n) 的桶累加，SetPixel 次数 = 像素宽 × 泳道数）。
##     平移/缩放/新数据触发重烘焙，交互期每帧即时烘焙，静止期随节流。
##   - 原始 segments 全部保留（上限 MAX_SEGMENTS），点选/详情仍用精确段数据。
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
const SEL_COLOR := Color(1.0, 1.0, 1.0)
const FONT_SIZE := 14
# Redraw throttling: the editor main thread re-bakes and redraws the Gantt at
# most this often (frames). A bake walks every segment in the time window into
# pixel-column buckets, then writes the result to a texture in one pass — on
# dense schedules the bucket walk is tens of thousands of GDScript iterations,
# so a per-frame bake stalls the editor. Interaction (drag/zoom/animating)
# still bakes immediately via its own branch in _process().
const REDRAW_INTERVAL := 10
# Hard cap on retained segments: when exceeded, drop the oldest half in one
# batch. Prevents unbounded memory growth (and O(n) _latest_end() scans) during
# long sessions. Live mode only ever shows the trailing time window, so old
# segments are never visible again.
const MAX_SEGMENTS := 60000
# 最小/最大可视时间跨度（ms）。缩放下限 1ms ≈ 能看清单个 job 窗口内部。
const MIN_SPAN_MS := 1.0
const MAX_SPAN_MS := 120000.0
# 烘焙纹理只记录有内容的像素列；密度着色阈值（同列段数 → alpha）。
const DENSITY_SCALE := 12.0

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
# 缩放动画锚点：鼠标下的时间点（anchor_t）在动画全程钉在鼠标位置（frac）。
# 动画期间 span_ms 平滑变化，_center_ms 必须随 span 重算，否则窗口漂移。
var _zoom_anchor_t := 0.0
var _zoom_frac := 0.0
var _zoom_active := false
# 时间标签锚点：固定在首个接收到的段起点。标签显示 t - _ts_anchor，
# 拖拽/缩放时 t 不变 → 标签数值稳定，只随网格线平移。
var _ts_anchor := 0.0
# 烘焙缓存：尺寸/窗口键 + 脏标记。数据、窗口、尺寸任一变化即重烘焙。
var _bake_img: Image = null
var _bake_tex: ImageTexture = null
var _bake_dirty := true
var _bake_w := 0
var _bake_h := 0
var _bake_center := 0.0
var _bake_span := 0.0


func add_segments(new_segs: Array) -> void:
	if new_segs.is_empty() or paused:
		return
	segments.append_array(new_segs)
	_bake_dirty = true
	# Cap retained segments: drop the oldest half in one batch when over the
	# limit (array head removal is O(n), so never trim per-message).
	if segments.size() > MAX_SEGMENTS:
		segments = segments.slice(segments.size() / 2)
		if _selected_index >= segments.size():
			_selected_index = -1
	if not _aligned_once:
		_center_ms = _latest_end()
		_aligned_once = true
		_ts_anchor = float(segments[0]["start_ms"])
		queue_redraw()


func set_live() -> void:
	paused = false
	_center_ms = _latest_end()
	_bake_dirty = true
	view_state_changed.emit(false, span_ms)
	queue_redraw()


func set_paused() -> void:
	if not paused:
		paused = true
		_bake_dirty = true
		view_state_changed.emit(true, span_ms)
		queue_redraw()


func set_span(ms: float) -> void:
	_target_span_ms = clampf(ms, MIN_SPAN_MS, 120000.0)


func _ready() -> void:
	clip_contents = true
	set_process(true)
	set_live()


func _process(delta: float) -> void:
	var diff := _target_span_ms - span_ms
	var animating := absf(diff) >= 1.0
	if animating:
		span_ms = lerpf(span_ms, _target_span_ms, minf(1.0, delta * 10.0))
		if _zoom_active:
			# 动画全程保持锚点时间钉在鼠标位置：center 随当前 span 重算。
			_center_ms = _zoom_anchor_t + (0.5 - _zoom_frac) * span_ms
		_bake_dirty = true
	if not animating:
		_zoom_active = false
	if _dragging:
		var plot_w := maxf(size.x - LEFT_PAD, 1.0)
		_center_ms = _drag_base_center + float(_drag_start_x - get_local_mouse_position().x) / plot_w * span_ms
		_bake_dirty = true
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
				_zoom_active = false  # 拖拽接管 center，停止缩放锚定
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
	_zoom_anchor_t = anchor_t
	_zoom_frac = frac
	_zoom_active = true
	_target_span_ms = clampf(span_ms * factor, MIN_SPAN_MS, MAX_SPAN_MS)
	# 立即按当前 span 锚定，避免动画首帧跳变；后续帧由 _process 重算。
	_center_ms = anchor_t + (0.5 - frac) * span_ms


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
	elif span_ms > 1500.0:
		step = 100.0
	elif span_ms > 300.0:
		step = 50.0
	elif span_ms > 60.0:
		step = 10.0
	elif span_ms > 15.0:
		step = 5.0
	elif span_ms > 3.0:
		step = 1.0
	else:
		step = 0.25
	var t: float = win_left - fmod(win_left, step)
	while t <= win_right:
		var px: float = LEFT_PAD + (t - win_left) / span_ms * plot_w
		draw_line(Vector2(px, TOP_PAD - 4), Vector2(px, size.y), GRID_COLOR, 1.0)
		if t >= win_left:
			draw_string(ThemeDB.fallback_font, Vector2(px + 3, TOP_PAD - 9),
					_ts(t, step), HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, TEXT_COLOR)
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

	_ensure_bake(win_left, win_right, plot_w, lanes)
	if _bake_tex != null:
		# 逐泳道绘制：每行只拉伸该泳道 1 像素行，高 _lane_h - 4（行间留 4px
		# 间隙，恢复方块感——整图拉伸会把相邻泳道的段上下连成一片）。
		# draw 次数 = 泳道数（≤ 线程数），与段数无关，性能不受影响。
		var src_w := float(_bake_img.get_width())
		for row in lanes:
			var y := TOP_PAD + 2.0 + row * _lane_h
			draw_texture_rect_region(_bake_tex,
					Rect2(LEFT_PAD, y, plot_w, _lane_h - 4.0),
					Rect2(0, row, src_w, 1), Color.WHITE, false)

	if _selected_index >= 0 and _selected_index < segments.size():
		var s: Dictionary = segments[_selected_index]
		var row := _row_of(int(s["lane"]))
		if row >= 0 and float(s["end_ms"]) >= win_left and float(s["start_ms"]) <= win_right:
			var x0 := LEFT_PAD + (float(s["start_ms"]) - win_left) / span_ms * plot_w
			var x1 := LEFT_PAD + (float(s["end_ms"]) - win_left) / span_ms * plot_w
			var y := TOP_PAD + row * _lane_h + 2.0
			draw_rect(Rect2(x0, y, maxf(x1 - x0, 2.0), _lane_h - 4.0), SEL_COLOR, false, 2.0)


func _ensure_bake(win_left: float, win_right: float, plot_w: float, lanes: int) -> void:
	# 缓存命中：数据/窗口/尺寸均未变（交互期 _bake_dirty 每帧为 true → 每帧重烘焙）
	var pw := maxi(int(plot_w), 1)
	if not _bake_dirty and _bake_tex != null \
			and _bake_w == pw and _bake_h == lanes \
			and is_equal_approx(_bake_center, _center_ms) \
			and is_equal_approx(_bake_span, span_ms):
		return
	if _bake_img == null or _bake_img.get_width() != pw or _bake_img.get_height() != lanes:
		_bake_img = Image.create(pw, lanes, false, Image.FORMAT_RGBA8)
	_bake_img.fill(Color(0, 0, 0, 0))

	# 像素列聚合：每泳道一行，每列累加段计数与总时长（SetPixel 次数 = pw × lanes，
	# 与段数无关；段数只影响下面这一次 O(n) 遍历）。
	var scale := pw / span_ms
	var counts := PackedFloat32Array()
	var sums := PackedFloat32Array()
	counts.resize(pw * lanes)
	sums.resize(pw * lanes)
	counts.fill(0.0)
	sums.fill(0.0)
	for i in range(segments.size() - 1, -1, -1):
		var s: Dictionary = segments[i]
		var row := _row_of(int(s["lane"]))
		if row < 0:
			continue
		var st := float(s["start_ms"])
		var en := float(s["end_ms"])
		if en < win_left:
			break
		if st > win_right:
			continue
		var x0 := int((st - win_left) * scale)
		var x1 := int((en - win_left) * scale)
		if x1 < 0 or x0 >= pw:
			continue
		x0 = maxi(x0, 0)
		x1 = mini(x1, pw - 1)
		var dur := en - st
		var base := row * pw
		for x in range(x0, x1 + 1):
			var idx := base + x
			counts[idx] += 1.0
			sums[idx] += dur
	for row in lanes:
		var base := row * pw
		for x in pw:
			var count := counts[base + x]
			if count <= 0.0:
				continue
			var col := _duration_color(sums[base + x] / count)
			col.a = 0.25 + 0.65 * minf(1.0, count / DENSITY_SCALE)
			_bake_img.set_pixel(x, row, col)
	if _bake_tex == null or _bake_tex.get_width() != pw or _bake_tex.get_height() != lanes:
		# 尺寸变化（窗口/泳道数变化）时必须重建纹理：update() 要求图像与
		# 原纹理尺寸一致，否则报 "new image dimensions must match"。
		_bake_tex = ImageTexture.create_from_image(_bake_img)
	else:
		_bake_tex.update(_bake_img)
	_bake_dirty = false
	_bake_w = pw
	_bake_h = lanes
	_bake_center = _center_ms
	_bake_span = span_ms


func _duration_color(dur_ms: float) -> Color:
	var hh := 0.0
	if dur_ms > 0.0:
		hh = log(1.0 + dur_ms) / log(11.0)
	hh = clampf(hh, 0.0, 1.0)
	return Color.from_hsv((1.0 - hh) * 120.0 / 360.0, 0.8, 0.9, 0.86)


func _ts(t: float, step: float) -> String:
	# 相对锚点（首个段起点）显示，拖拽/缩放时标签数值不随窗口变动。
	# 精度由网格步长决定（否则放大后相邻刻度无法区分，全部四舍五入成
	# 同一个值）：步长越小，小数位越多。
	var rel := t - _ts_anchor
	var abs_rel := absf(rel)
	if abs_rel >= 1000.0:
		# 大时间量级：显示秒，小数位由步长决定（0.25ms 步长需要 4 位小数秒）。
		if step >= 100.0:
			return "%.2fs" % (rel / 1000.0)
		if step >= 10.0:
			return "%.3fs" % (rel / 1000.0)
		return "%.4fs" % (rel / 1000.0)
	# 小时间量级：毫秒/微秒，小数位同样由步长决定。
	if abs_rel >= 1.0:
		if step >= 10.0:
			return "%.0fms" % rel
		if step >= 1.0:
			return "%.1fms" % rel
		return "%.2fms" % rel
	return "%.0fµs" % (rel * 1000.0)
