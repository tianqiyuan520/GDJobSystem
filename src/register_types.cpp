// ============================================================================
// GDJobsystem — GDExtension 入口与类注册
// ============================================================================
// entry_symbol（gd_job_system_library_init）由 .gdextension 文件指定，Godot
// 加载 DLL 后调用：
//   * SCENE 层：注册运行时类 JobSystem / JobSystemHandle（游戏与编辑器都注册）。
//   * EDITOR 层：注册编辑器类 JobSystemEditorPlugin / JobSystemDebuggerPlugin。
//     —— 必须在 EDITOR 层注册：SCENE 层初始化时 EditorPlugin 基类尚未进入
//        ClassDB（这正是之前"类已注册但编辑器侧不可用"的根因）。
//     —— 用 class_exists 防御 headless 编辑器 / 导出游戏（无 editor 模块类）。
// 卸载时确保调度器线程池关闭（JobSystem::shutdown）。
// ============================================================================

#include "register_types.h"

#include <gdextension_interface.h>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>
#include <godot_cpp/classes/engine.hpp>

#include "job_system.h"
#include "job_debugger_plugin.h"

using namespace godot;

void initialize_gdextension_types(ModuleInitializationLevel p_level)
{
	if (p_level == MODULE_INITIALIZATION_LEVEL_SCENE) {
		GDREGISTER_CLASS(godot::JobSystem);
		GDREGISTER_CLASS(godot::JobSystemHandle);
	} else if (p_level == MODULE_INITIALIZATION_LEVEL_EDITOR) {
		// Editor-only classes must be registered at the EDITOR level: the
		// EditorPlugin / EditorDebuggerPlugin base classes are not in ClassDB
		// yet when the extension's SCENE level runs. The guard keeps headless
		// editors and exported games (no editor module classes) from failing.
		if (ClassDB::class_exists("EditorPlugin") && ClassDB::class_exists("EditorDebuggerPlugin")) {
			GDREGISTER_CLASS(godot::JobSystemEditorPlugin);
			GDREGISTER_CLASS(godot::JobSystemDebuggerPlugin);
		}
	}
}

void uninitialize_gdextension_types(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}
	// Make sure the worker pool is torn down when the extension unloads.
	godot::JobSystem::shutdown();
}

extern "C"
{
	// Initialization
	GDExtensionBool GDE_EXPORT gd_job_system_library_init(GDExtensionInterfaceGetProcAddress p_get_proc_address, GDExtensionClassLibraryPtr p_library, GDExtensionInitialization *r_initialization)
	{
		GDExtensionBinding::InitObject init_obj(p_get_proc_address, p_library, r_initialization);
		init_obj.register_initializer(initialize_gdextension_types);
		init_obj.register_terminator(uninitialize_gdextension_types);
		init_obj.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);

		return init_obj.init();
	}
}
