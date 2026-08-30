@tool
extends EditorPlugin
## GDJobsystem 编辑器插件入口。
##
## 职责：把 JobSystem 监控器（调试器标签页）注册到 Godot 编辑器调试器。
## 注册流程：
##   1. 编辑器启动 → project.godot 的 [editor_plugins] 加载本插件（plugin.cfg）
##   2. _enter_tree() 创建 EditorDebuggerPlugin（monitor/monitor_plugin.gd）
##   3. add_debugger_plugin() 挂到编辑器调试器 → 运行游戏时出现"JobSystem 监控器"标签页
##
## 注意：本插件只负责编辑器侧 UI；运行时 JobSystem 类由 GDExtension
## （bin/gd_job_system.gdextension + C++ DLL）提供，二者通过 EngineDebugger
## 消息通信（见 monitor/monitor_plugin.gd 的消息协议）。

var _monitor: EditorDebuggerPlugin


func _enter_tree() -> void:
	_monitor = preload("monitor/monitor_plugin.gd").new()
	add_debugger_plugin(_monitor)


func _exit_tree() -> void:
	remove_debugger_plugin(_monitor)
	_monitor = null
