@tool
extends RefCounted
## Activity 标签页：执行窗口滚动列表（可选中/右键复制）。
## 数据来源：运行时推送的 gd_job_system:timeline（每段一条文本）。
## 缓冲上限 MAX_LINES，超出丢弃最旧的（防长期运行卡顿）。
## 行格式：Wxx:[D] #batchId  耗时 ms | tiles=N workers=M

const MAX_LINES := 2000

var _list: RichTextLabel
var _buffer: Array = []


func build() -> Control:
	var page := VBoxContainer.new()
	page.name = "Activity"
	_list = RichTextLabel.new()
	_list.scroll_following = true
	_list.selection_enabled = true
	_list.context_menu_enabled = true
	_list.add_theme_font_size_override("normal_font_size", 20)
	_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	page.add_child(_list)
	return page


func append(segs: Array) -> void:
	for s in segs:
		var lane: int = s["lane"]
		var where := "W%02d" % lane if lane >= 0 else "?"
		var prefix := "[D] " if s.get("direct", false) else ""
		_buffer.append("%s:%s #%d  %.2f ms  |  tiles=%d  workers=%d" % [
			where, prefix, int(s["batch_id"]),
			float(s["end_ms"]) - float(s["start_ms"]),
			int(s["tiles"]), int(s["workers"])])
	if _buffer.size() > MAX_LINES:
		_buffer = _buffer.slice(_buffer.size() - MAX_LINES)
	_list.text = "\n".join(_buffer)
