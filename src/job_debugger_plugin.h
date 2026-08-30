// ============================================================================
// GDJobsystem — C++ 侧调试器插件（备用实现，当前未实例化）
// ============================================================================
// 说明：Godot 4.7 对 GDExtension 的 EditorPlugin 子类不自动实例化
//（GDExtensionEditorPlugins::add_extension_class 无调用点），因此实际生效的
// 调试器标签页由 GDScript 编辑器插件提供（project/addons/GDJobsystem/，
// 走 [editor_plugins] 机制）。本文件保留 C++ 实现作为参考与备用：
//   JobSystemDebuggerPlugin — EditorDebuggerPlugin 子类：会话里加 4 列表格，
//     _capture 接收 gd_job_system:worker_snap 渲染 worker 状态。
//   JobSystemEditorPlugin  — EditorPlugin 子类：_enter_tree 注册调试器插件。
// 若未来 Godot 修复自动实例化，或在 C++ 侧需要独立实现，删除
// register_types.cpp 中 EDITOR 层的 class_exists 防御并启用即可。
// ============================================================================

#pragma once

#include "godot_cpp/classes/editor_debugger_plugin.hpp"
#include "godot_cpp/classes/editor_debugger_session.hpp"
#include "godot_cpp/classes/editor_plugin.hpp"
#include "godot_cpp/classes/ref.hpp"
#include "godot_cpp/classes/tree.hpp"

#include <unordered_map>

namespace godot {

// Editor-side debugger tab that renders live per-worker JobSystem state.
// The running game sends "gd_job_system:worker_snap" messages via
// EngineDebugger (see JobSystem::debugger_poll in job_system.cpp).
class JobSystemDebuggerPlugin : public EditorDebuggerPlugin {
	GDCLASS(JobSystemDebuggerPlugin, EditorDebuggerPlugin)

protected:
	static void _bind_methods();

public:
	JobSystemDebuggerPlugin() = default;
	~JobSystemDebuggerPlugin() override = default;

	void _setup_session(int32_t p_session_id) override;
	bool _has_capture(const String &p_capture) const override;
	bool _capture(const String &p_message, const Array &p_data, int32_t p_session_id) override;

private:
	void _update_snapshot(int32_t p_session_id, const Array &p_data);

	struct SessionView {
		Ref<EditorDebuggerSession> session;
		Tree *tree = nullptr;
	};
	std::unordered_map<int32_t, SessionView> _views;
};

// Minimal EditorPlugin that registers the debugger plugin. GDExtension
// EditorPlugin subclasses are instantiated automatically by the editor.
class JobSystemEditorPlugin : public EditorPlugin {
	GDCLASS(JobSystemEditorPlugin, EditorPlugin)

protected:
	static void _bind_methods();

public:
	JobSystemEditorPlugin() = default;
	~JobSystemEditorPlugin() override = default;

	void _enter_tree() override;
	void _exit_tree() override;

private:
	Ref<JobSystemDebuggerPlugin> _debugger_plugin;
};

} // namespace godot
