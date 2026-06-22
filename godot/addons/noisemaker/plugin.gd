@tool
extends EditorPlugin

# Editor plugin entry point. Integration is scripting-only today: the in-engine compiler
# (compiler/graph/orchestrator.gd) and the executor (runtime/nm_backend.gd) are used directly
# from GDScript — see addons/noisemaker/README.md. This plugin registers NO editor nodes; it
# exists so the addon is a well-formed, enableable Godot plugin. A drop-in NMRenderer node is
# not yet shipped.

func _enter_tree() -> void:
	pass

func _exit_tree() -> void:
	pass
