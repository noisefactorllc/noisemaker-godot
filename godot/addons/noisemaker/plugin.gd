@tool
extends EditorPlugin

# Editor plugin entry point. The runtime executor (nm_backend.gd) and the offline
# renderer (tools/render_graph.gd) work standalone; this exists so the addon is a
# well-formed, enableable Godot plugin. Editor-side nodes (NMRenderer) land in Phase 3.

func _enter_tree() -> void:
	pass

func _exit_tree() -> void:
	pass
