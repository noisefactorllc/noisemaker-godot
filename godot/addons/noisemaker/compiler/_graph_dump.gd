# _graph_dump.gd — CANDIDATE for the graph parity gate. Builds the normalized render graph for each
# DSL path passed after `--` and prints JSON { path: {ok, out} } on a single GRAPHDUMP: marker line.
# Pure logic -> runs --headless.
#   Godot --headless --path godot --script res://addons/noisemaker/compiler/_graph_dump.gd -- <f...>
extends SceneTree

const Orchestrator := preload("res://addons/noisemaker/compiler/graph/orchestrator.gd")
const EffectRegistry := preload("res://addons/noisemaker/compiler/lang/effect_registry.gd")

func _init() -> void:
	var reg := EffectRegistry.new()
	reg.load_all()
	var out := {}
	for f in OS.get_cmdline_user_args():
		var src := FileAccess.get_file_as_string(f)
		var graph = Orchestrator.new(reg).build_graph(src)
		out[f] = {"ok": true, "out": graph}
	print("GRAPHDUMP:", JSON.stringify(out))
	quit(0)
