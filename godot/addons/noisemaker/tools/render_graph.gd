# render_graph.gd — offline candidate renderer (the analog of Unity's NMParityRunner).
# Runs a normalized render-graph through the RenderingDevice executor and writes a PNG. MUST run
# non-headless (RenderingDevice is null under --headless); position the window offscreen.
#
# Graph source (one of):
#   --dsl <abs.dsl>     build the graph IN-ENGINE via the GDScript compiler (self-contained; no
#                       reference / export-graph.mjs). This is the production path.
#   --graph <abs.json>  read a pre-normalized graph JSON (e.g. a reference golden, for parity diffing).
#
#   Godot --path godot --script res://addons/noisemaker/tools/render_graph.gd \
#         --position 5000,5000 -- (--dsl <abs.dsl> | --graph <abs.json>) --out <abs.png> --size 256
extends SceneTree

const Orchestrator := preload("res://addons/noisemaker/compiler/graph/orchestrator.gd")
const EffectRegistry := preload("res://addons/noisemaker/compiler/lang/effect_registry.gd")

func _init() -> void:
	var a := OS.get_cmdline_user_args()
	var graph_path := ""
	var dsl_path := ""
	var out_path := ""
	var size := 256
	var run_seconds := 0       # >0 => timed-sampling mode for stateful sims
	var sample_every_sec := 5
	var i := 0
	while i < a.size():
		match a[i]:
			"--graph":
				graph_path = a[i + 1]; i += 2
			"--dsl":
				dsl_path = a[i + 1]; i += 2
			"--out":
				out_path = a[i + 1]; i += 2
			"--size":
				size = int(a[i + 1]); i += 2
			"--run-seconds":
				run_seconds = int(a[i + 1]); i += 2
			"--sample-every":
				sample_every_sec = int(a[i + 1]); i += 2
			_:
				i += 1
	if (graph_path == "" and dsl_path == "") or out_path == "":
		printerr("usage: -- (--dsl <dsl> | --graph <json>) --out <png> [--size 256] [--run-seconds N --sample-every S]")
		quit(1); return

	var rd := RenderingServer.create_local_rendering_device()
	if rd == null:
		printerr("RD_NULL: RenderingDevice unavailable (run non-headless, with a window)")
		quit(1); return

	var graph
	if dsl_path != "":
		# Self-contained path: compile the DSL to a render graph in-engine.
		var src := FileAccess.get_file_as_string(dsl_path)
		if src == "":
			printerr("cannot read dsl: ", dsl_path)
			quit(1); return
		var reg := EffectRegistry.new()
		reg.load_all()
		graph = Orchestrator.new(reg).build_graph(src)
	else:
		var f := FileAccess.open(graph_path, FileAccess.READ)
		if f == null:
			printerr("cannot read graph: ", graph_path)
			quit(1); return
		graph = JSON.parse_string(f.get_as_text())
		f.close()
	if typeof(graph) != TYPE_DICTIONARY:
		printerr("bad graph: ", graph_path if graph_path != "" else dsl_path)
		quit(1); return

	var Backend = preload("res://addons/noisemaker/runtime/nm_backend.gd")
	var backend = Backend.new()
	backend.setup(rd, "res://addons/noisemaker", Vector2i(size, size))
	if run_seconds > 0:
		# Timed-sampling mode (stateful sims): run run_seconds of sim-time at 60fps, capturing
		# every sample_every_sec into <out-basename>.t<sec>.png (e.g. navierStokes.candidate.t5.png).
		var total_frames := run_seconds * 60
		var every := max(1, sample_every_sec * 60)
		var imgs = backend.render_samples(graph, total_frames, every)
		var base := out_path.get_basename()
		var all_ok := imgs.size() > 0
		for idx in imgs.size():
			var sec := (idx + 1) * sample_every_sec
			var sp := "%s.t%d.png" % [base, sec]
			var simg = imgs[idx]
			var sok: bool = simg != null and simg.save_png(sp) == OK
			all_ok = all_ok and sok
			print("NM_SAMPLE t=", sec, " out=", sp, " ok=", sok)
		print("NM_RENDERED_SAMPLES n=", imgs.size(), " surface=", backend.render_surface_tex)
		quit(0 if all_ok else 1); return
	backend.render(graph)
	var ok = backend.save_surface_png(out_path)
	print("NM_RENDERED out=", out_path, " surface=", backend.render_surface_tex, " ok=", ok)
	quit(0 if ok else 1)
