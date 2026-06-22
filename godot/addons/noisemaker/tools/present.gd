# present.gd — presentation harness: compiles a DSL in-engine, evolves the sim for N seconds, and
# captures a single PNG showing the DSL source alongside the rendered canvas. Demonstrates the
# self-contained in-engine compiler end to end (no reference). MUST run non-headless (RenderingDevice
# is null under --headless); position the window offscreen.
#
#   Godot --path godot --script res://addons/noisemaker/tools/present.gd --position 5000,5000 \
#         -- --dsl <abs.dsl> --out <abs.png> [--size 512] [--seconds 30]
extends SceneTree

const Orchestrator := preload("res://addons/noisemaker/compiler/graph/orchestrator.gd")
const EffectRegistry := preload("res://addons/noisemaker/compiler/lang/effect_registry.gd")
const Backend := preload("res://addons/noisemaker/runtime/nm_backend.gd")

func _init() -> void:
	_run()

func _run() -> void:
	var a := OS.get_cmdline_user_args()
	var dsl_path := ""
	var out_path := ""
	var size := 512
	var seconds := 30
	var i := 0
	while i < a.size():
		match a[i]:
			"--dsl": dsl_path = a[i + 1]; i += 2
			"--out": out_path = a[i + 1]; i += 2
			"--size": size = int(a[i + 1]); i += 2
			"--seconds": seconds = int(a[i + 1]); i += 2
			_: i += 1
	if dsl_path == "" or out_path == "":
		printerr("usage: -- --dsl <dsl> --out <png> [--size 512] [--seconds 30]")
		quit(1); return

	var src := FileAccess.get_file_as_string(dsl_path)
	if src == "":
		printerr("cannot read dsl: ", dsl_path); quit(1); return

	var rd := RenderingServer.create_local_rendering_device()
	if rd == null:
		printerr("RD_NULL: RenderingDevice unavailable (run non-headless, with a window)")
		quit(1); return

	# --- compile + render the sim in-engine (self-contained) ---
	print("[present] compiling DSL in-engine ...")
	var reg := EffectRegistry.new()
	reg.load_all()
	var graph = Orchestrator.new(reg).build_graph(src)
	var backend = Backend.new()
	backend.setup(rd, "res://addons/noisemaker", Vector2i(size, size))
	var total_frames := seconds * 60
	print("[present] evolving %d frames (%ds) ..." % [total_frames, seconds])
	var imgs: Array = backend.render_samples(graph, total_frames, total_frames)
	if imgs.is_empty() or imgs[0] == null:
		printerr("render produced no image"); quit(1); return
	var canvas_img: Image = imgs[0]
	print("[present] rendered surface=%s %dx%d" % [backend.render_surface_tex, canvas_img.get_width(), canvas_img.get_height()])

	# --- compose the presentation (DSL columns + canvas) into a SubViewport, then capture ---
	var disp := 760                         # canvas display size
	var col_w := 430                        # DSL column width
	var pad := 36
	var title_h := 56
	var W := pad + col_w + 18 + col_w + pad + disp + pad
	var H := title_h + disp + pad + 40

	var bg_col := Color(0.043, 0.047, 0.063)
	var panel_col := Color(0.082, 0.090, 0.121)
	var accent := Color(0.40, 0.78, 0.92)
	var text_col := Color(0.86, 0.89, 0.94)
	var dim_col := Color(0.52, 0.57, 0.64)

	var mono := SystemFont.new()
	mono.font_names = PackedStringArray(["Menlo", "SF Mono", "Cascadia Mono", "Courier New", "monospace"])

	var vp := SubViewport.new()
	vp.size = Vector2i(W, H)
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vp.transparent_bg = false
	root.add_child(vp)

	var bg := ColorRect.new()
	bg.color = bg_col
	bg.position = Vector2.ZERO
	bg.size = Vector2(W, H)
	vp.add_child(bg)

	var title := Label.new()
	title.text = "Noisemaker · Godot — in-engine DSL → render graph → GPU   ·   %s   ·   %s @ %ds" % [dsl_path.get_file(), backend.render_surface_tex.trim_prefix("global_"), seconds]
	title.add_theme_font_size_override("font_size", 20)
	title.add_theme_color_override("font_color", text_col)
	title.position = Vector2(pad, 16)
	vp.add_child(title)

	var accent_bar := ColorRect.new()
	accent_bar.color = accent
	accent_bar.position = Vector2(pad, title_h - 6)
	accent_bar.size = Vector2(W - pad * 2, 2)
	vp.add_child(accent_bar)

	# DSL split into two columns at the navierStokes block for a balanced layout.
	var split_idx := src.find("\nnavierStokes(")
	var col_a := src
	var col_b := ""
	if split_idx > 0:
		col_a = src.substr(0, split_idx)
		col_b = src.substr(split_idx + 1)

	_add_code_panel(vp, mono, panel_col, text_col, accent, pad, title_h + 6, col_w, disp + pad + 40 - 6, col_a)
	_add_code_panel(vp, mono, panel_col, text_col, accent, pad + col_w + 18, title_h + 6, col_w, disp + pad + 40 - 6, col_b)

	# Canvas (rendered o1) with a thin accent frame + caption.
	var canvas_x := pad + col_w + 18 + col_w + pad
	var canvas_y := title_h + 6
	var frame := ColorRect.new()
	frame.color = accent
	frame.position = Vector2(canvas_x - 2, canvas_y - 2)
	frame.size = Vector2(disp + 4, disp + 4)
	vp.add_child(frame)
	var tr := TextureRect.new()
	tr.texture = ImageTexture.create_from_image(canvas_img)
	tr.position = Vector2(canvas_x, canvas_y)
	tr.size = Vector2(disp, disp)
	tr.stretch_mode = TextureRect.STRETCH_SCALE
	tr.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	vp.add_child(tr)
	var cap := Label.new()
	cap.text = "render(o1) — flow-field particles → navierStokes → palette · lighting · bloom · lens · vignette   (%dx%d, 30s evolved)" % [size, size]
	cap.add_theme_font_size_override("font_size", 13)
	cap.add_theme_color_override("font_color", dim_col)
	cap.position = Vector2(canvas_x, canvas_y + disp + 10)
	vp.add_child(cap)

	# let it lay out + draw, then capture
	await process_frame
	await process_frame
	await process_frame
	var shot := vp.get_texture().get_image()
	var ok := shot != null and shot.save_png(out_path) == OK
	print("[present] wrote %s ok=%s (%dx%d)" % [out_path, ok, W, H])
	quit(0 if ok else 1)

func _add_code_panel(vp: SubViewport, mono: SystemFont, panel_col: Color, text_col: Color, accent: Color, x: int, y: int, w: int, h: int, code: String) -> void:
	var panel := ColorRect.new()
	panel.color = panel_col
	panel.position = Vector2(x, y)
	panel.size = Vector2(w, h)
	vp.add_child(panel)
	var stripe := ColorRect.new()
	stripe.color = accent
	stripe.position = Vector2(x, y)
	stripe.size = Vector2(3, h)
	vp.add_child(stripe)
	var lbl := Label.new()
	lbl.text = code
	lbl.add_theme_font_override("font", mono)
	lbl.add_theme_font_size_override("font_size", 13)
	lbl.add_theme_color_override("font_color", text_col)
	lbl.autowrap_mode = TextServer.AUTOWRAP_OFF
	lbl.position = Vector2(x + 16, y + 12)
	lbl.size = Vector2(w - 24, h - 20)
	vp.add_child(lbl)
