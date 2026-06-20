# render_graph.gd — offline candidate renderer (the analog of Unity's NMParityRunner).
# Runs a normalized render-graph JSON through the RenderingDevice executor and writes
# a PNG. MUST run non-headless (RenderingDevice is null under --headless); position
# the window offscreen.
#
#   Godot --path godot --script res://addons/noisemaker/tools/render_graph.gd \
#         --position 5000,5000 -- --graph <abs.json> --out <abs.png> --size 256
extends SceneTree

func _init() -> void:
	var a := OS.get_cmdline_user_args()
	var graph_path := ""
	var out_path := ""
	var size := 256
	var i := 0
	while i < a.size():
		match a[i]:
			"--graph":
				graph_path = a[i + 1]; i += 2
			"--out":
				out_path = a[i + 1]; i += 2
			"--size":
				size = int(a[i + 1]); i += 2
			_:
				i += 1
	if graph_path == "" or out_path == "":
		printerr("usage: -- --graph <json> --out <png> [--size 256]")
		quit(1); return

	var rd := RenderingServer.create_local_rendering_device()
	if rd == null:
		printerr("RD_NULL: RenderingDevice unavailable (run non-headless, with a window)")
		quit(1); return

	var f := FileAccess.open(graph_path, FileAccess.READ)
	if f == null:
		printerr("cannot read graph: ", graph_path)
		quit(1); return
	var graph = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(graph) != TYPE_DICTIONARY:
		printerr("bad graph JSON: ", graph_path)
		quit(1); return

	var Backend = preload("res://addons/noisemaker/runtime/nm_backend.gd")
	var backend = Backend.new()
	backend.setup(rd, "res://addons/noisemaker", Vector2i(size, size))
	backend.render(graph)
	var ok = backend.save_surface_png(out_path)
	print("NM_RENDERED out=", out_path, " surface=", backend.render_surface_tex, " ok=", ok)
	quit(0 if ok else 1)
