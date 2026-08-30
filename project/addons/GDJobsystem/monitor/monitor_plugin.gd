@tool
extends EditorDebuggerPlugin
## 调试器插件：管理每个调试会话的监控器视图，并把运行时的消息分发给对应视图。
##
## ── 消息协议（运行时 → 编辑器）──
## 运行时（游戏进程）通过 EngineDebugger 发送，前缀统一为 "gd_job_system"：
##   gd_job_system:worker_snap  Array[Dictionary]  每个 worker 的 {index, active, batch_id, tile, tile_count}
##   gd_job_system:timeline     Array[Dictionary]  新增执行窗口 {lane, batch_id, start_ms, end_ms, tiles, workers, direct}
##   gd_job_system:stats        [Dictionary]       调度器统计快照（JobSystem.get_stats_snapshot）
##   gd_job_system:jcc          Array[Dictionary]  JobCostCache 学习槽位
## 发送方：C++ 绑定层 src/job_system.cpp 的 JobSystem::debugger_poll()
##
## ── 控制消息（编辑器 → 运行时）──
##   gd_job_system_ctl:set_paused [bool]  暂停/恢复（暂停时运行时停止一切发送）
## 接收方：C++ 绑定层的 EngineDebugger::register_message_capture
##
## 每个调试会话（session_id）对应一个 SessionView（session_view.gd），
## 暂停（frozen）时丢弃所有消息。

const MESSAGE_PREFIX := "gd_job_system"
const SessionView = preload("session_view.gd")

var _views := {}  # session_id -> SessionView


func _setup_session(session_id: int) -> void:
	var view := preload("session_view.gd").new(get_session(session_id))
	get_session(session_id).add_session_tab(view.root)
	_views[session_id] = view


func _has_capture(capture: String) -> bool:
	return capture == MESSAGE_PREFIX


func _capture(message: String, data: Array, session_id: int) -> bool:
	var view: SessionView = _views.get(session_id)
	if view == null:
		return false
	if view.frozen:
		return true  # paused: drop everything (incl. timeline data)
	match message:
		"gd_job_system:worker_snap":
			view.on_snapshot(data)
		"gd_job_system:timeline":
			view.on_timeline(data)
		"gd_job_system:stats":
			view.on_stats(data)
		"gd_job_system:jcc":
			view.on_jcc(data)
	return true
