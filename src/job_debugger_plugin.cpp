#include "job_debugger_plugin.h"

#include "godot_cpp/classes/tree_item.hpp"
#include "godot_cpp/core/class_db.hpp"
#include "godot_cpp/variant/dictionary.hpp"
#include "godot_cpp/variant/utility_functions.hpp"

namespace godot {

// ---------------------------------------------------------------------------
// JobSystemDebuggerPlugin
// ---------------------------------------------------------------------------

void JobSystemDebuggerPlugin::_bind_methods() {
}

void JobSystemDebuggerPlugin::_setup_session(int32_t p_session_id) {
	Ref<EditorDebuggerSession> session = get_session(p_session_id);
	if (session.is_null()) {
		return;
	}
	auto *tree = memnew(Tree);
	tree->set_columns(4);
	tree->set_column_titles_visible(true);
	tree->set_column_title(0, "Worker");
	tree->set_column_title(1, "State");
	tree->set_column_title(2, "Batch ID");
	tree->set_column_title(3, "Tile / Total");
	session->add_session_tab(tree);
	_views[p_session_id] = SessionView{ session, tree };
	// Initial idle snapshot so the tab is not empty before the first message.
	_update_snapshot(p_session_id, Array());
}

bool JobSystemDebuggerPlugin::_has_capture(const String &p_capture) const {
	// Godot passes only the prefix before ':' here (e.g. "gd_job_system").
	return p_capture == "gd_job_system";
}

bool JobSystemDebuggerPlugin::_capture(const String &p_message, const Array &p_data, int32_t p_session_id) {
	if (p_message == "gd_job_system:worker_snap") {
		_update_snapshot(p_session_id, p_data);
		return true;
	}
	return false;
}

void JobSystemDebuggerPlugin::_update_snapshot(int32_t p_session_id, const Array &p_data) {
	auto it = _views.find(p_session_id);
	if (it == _views.end()) {
		return;
	}
	Tree *tree = it->second.tree;
	if (tree == nullptr) {
		return;
	}
	tree->clear();
	TreeItem *root = tree->create_item();
	root->set_text(0, "JobSystem workers");
	for (int i = 0; i < p_data.size(); i++) {
		const Dictionary w = p_data[i];
		const bool active = (bool)w["active"];
		TreeItem *item = tree->create_item(root);
		item->set_text(0, vformat("Worker %d", (int)w["index"]));
		item->set_text(1, active ? "busy" : "idle");
		if (active) {
			item->set_text(2, String::num_uint64((uint64_t)w["batch_id"]));
			item->set_text(3, vformat("%d / %d", (int)w["tile"], (int)w["tile_count"]));
		}
	}
}

// ---------------------------------------------------------------------------
// JobSystemEditorPlugin
// ---------------------------------------------------------------------------

void JobSystemEditorPlugin::_bind_methods() {
}

void JobSystemEditorPlugin::_enter_tree() {
	if (_debugger_plugin.is_null()) {
		_debugger_plugin.instantiate();
	}
	add_debugger_plugin(_debugger_plugin);
}

void JobSystemEditorPlugin::_exit_tree() {
	if (!_debugger_plugin.is_null()) {
		remove_debugger_plugin(_debugger_plugin);
		_debugger_plugin.unref();
	}
}

} // namespace godot
