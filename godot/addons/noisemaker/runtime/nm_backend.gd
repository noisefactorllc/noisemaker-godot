# nm_backend.gd — RenderingDevice executor for the Noisemaker render graph.
# Mirrors the WebGL2 GPGPU model (reference/04 §5 backend contract): every pass is
# a fullscreen fragment draw into a color attachment; "compute" passes are render
# passes with MRT. Ported structurally from the Unity NMRenderBackend.cs.
#
# Two uniform models, both a single packed `vec4 data[N]` UBO at set 0, binding 0:
#   - Effects WITH a reference uniformLayout (noise/cell/gradient/...): the shader
#     declares `data[N]` and reads `data[i].comp` verbatim from the WGSL. The backend
#     packs engine globals + params by that layout.
#   - Effects WITHOUT one (solid/osc2d/blur/...): the backend SYNTHESIZES a layout
#     (fixed engine header in slots 0-2, params from slot 3) and INJECTS the UBO decl
#     plus `#define <name> data[slot].comp` after #version, so the shader uses bare
#     reference names (ports near-verbatim from the GLSL). Same packer either way.
# Input textures bind at set 0, binding 1.. in pass.inputs order. blit is special:
# sampler `src` at binding 0, no UBO.
#
# Compile-time defines (NOISE_TYPE, LOOP_OFFSET) are injected after #version; shaders
# are cached per (program, define-set).
#
# Coordinates: Godot RenderingDevice is top-left origin / Vulkan Y-down clip, same as
# WGSL — port from WGSL, NO per-effect Y-flip. A single global flip at present (see
# save_surface_png) reconciles to the webgl2/GLSL golden.
extends RefCounted

const FULLSCREEN_VS := """#version 450
layout(location = 0) in vec2 vpos;
layout(location = 0) out vec2 v_uv;
void main() { v_uv = vpos * 0.5 + 0.5; gl_Position = vec4(vpos, 0.0, 1.0); }
"""

const BLIT_FS := """#version 450
layout(set = 0, binding = 0) uniform sampler2D src;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;
void main() { frag = texture(src, v_uv); }
"""

# Engine-provided globals (reference/04 §10.1), sourced from the runtime.
const ENGINE_GLOBALS := {
	"resolution": true, "time": true, "aspectRatio": true, "tileOffset": true,
	"fullResolution": true, "renderScale": true, "deltaTime": true, "frame": true,
}

# Fixed engine header for synthesized (no-layout) effect layouts.
const ENGINE_SYNTH := {
	"resolution": {"slot": 0, "components": "xy"},
	"time": {"slot": 0, "components": "z"},
	"aspectRatio": {"slot": 0, "components": "w"},
	"tileOffset": {"slot": 1, "components": "xy"},
	"fullResolution": {"slot": 1, "components": "zw"},
	"renderScale": {"slot": 2, "components": "x"},
	"deltaTime": {"slot": 2, "components": "y"},
	"frame": {"slot": 2, "components": "z"},
}

var rd: RenderingDevice
var addon_dir: String
var screen: Vector2i
var _sampler: RID
var _vfmt: int
var _varr: RID
var _vfmt_empty: int        # empty vertex format for procedural (gl_VertexIndex-only) point/billboard draws
var _shaders := {}
var _pipelines := {}
var _textures := {}
var _tex_dims := {}         # texId -> Vector2i(w,h); count:"input" deposit draws derive agent count = w*h
var _tex_fmt := {}          # texId -> RenderingDevice DATA_FORMAT_*; lets the snapshot read the render surface in its real format (rgba8 vs rgba16f)
var _effect_defs := {}
var _synth_cache := {}      # "ns/fn" -> synthesized layout
var render_surface_tex := ""
var _time := 0.25
var _render_scale := 1.0
# Timed-sampling mode (stateful-sim parity, reference 30s/5s): real per-frame deltaTime
# and frame index, threaded into _engine_value. Both stay 0 on the default single-frame
# path, so the 90 isolation effects render byte-identically.
var _delta_time := 0.0
var _frame_index := 0

# Double-buffered "ping-pong" surfaces (reference/04 §6/§8/§10). A `global_<name>`
# texId that is BOTH read and written by passes gets a physical read/write texture
# pair; inputs resolve to the current read buffer, outputs to the current write
# buffer, swapped within-frame after each write and at end-of-frame (state surfaces
# persist their final binding, display surfaces toggle). Write-only globals (o0, the
# present target) stay as flat single textures — see allocate_textures.
var _surfaces := {}        # bareName -> {"read": texId, "write": texId}
var _frame_read := {}      # bareName -> texId (this frame's read buffer)
var _frame_write := {}     # bareName -> texId (this frame's write target)
var _pingpong := {}        # global texId -> bareName (the double-buffered set)
var _black_tex: RID        # 1x1 zero texture bound for "none" inputs (reference BlackTex)
var _samplers := {}        # shader cache_key -> [{"name":String,"binding":int}]
var _sampler_re: RegEx
var _state_node_re: RegEx  # matches particle state-node surface names (isStateSurface)

func setup(p_rd: RenderingDevice, p_addon_dir: String, p_screen: Vector2i) -> void:
	rd = p_rd
	addon_dir = p_addon_dir
	screen = p_screen
	# NEAREST + clamp-to-edge — matches the reference WebGL2 backend's effect render
	# targets (webgl2.js:130-131/221-222 set gl.NEAREST). Effects sample at texel centers
	# or integer-texel offsets (where NEAREST == LINEAR), so this is invisible to them;
	# but coord-resampling filters (pixels, warps, polar, lens…) that sample BETWEEN texels
	# need NEAREST to fetch one texel rather than blending two. (3D volumes use LINEAR —
	# add a separate sampler when 3D lands.)
	var ss := RDSamplerState.new()
	ss.min_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	ss.mag_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	ss.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	ss.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_sampler = rd.sampler_create(ss)
	# 1x1 zero texture bound for "none" sampler inputs so binding indices stay aligned
	# with the shader's declared samplers (matches the reference backend's BlackTex).
	_black_tex = _make_tex(1, 1, _data_format("rgba16f"))
	# Parses `layout(... binding = N) uniform sampler2D NAME;` so set-0 inputs can be
	# bound BY NAME (both reference backends bind by name) — a pass may list more inputs
	# than the shader uses (e.g. cellularAutomata's render pass), and the SPIR-V compiler
	# strips unused samplers, so only declared+used names may be bound.
	_sampler_re = RegEx.new()
	_sampler_re.compile("binding\\s*=\\s*(\\d+)\\s*\\)\\s*uniform\\s+sampler2D\\s+(\\w+)")
	_state_node_re = RegEx.new()
	_state_node_re.compile("^(xyz|vel|rgba|points_trail)_node_\\d+$")
	var verts := PackedFloat32Array([-1.0, -1.0, 3.0, -1.0, -1.0, 3.0])
	var vb := verts.to_byte_array()
	var vbuf := rd.vertex_buffer_create(vb.size(), vb)
	var attr := RDVertexAttribute.new()
	attr.location = 0
	attr.format = RenderingDevice.DATA_FORMAT_R32G32_SFLOAT
	attr.stride = 8
	attr.offset = 0
	_vfmt = rd.vertex_format_create([attr])
	_varr = rd.vertex_array_create(3, _vfmt, [vbuf])
	# No-vertex-input format: agent deposit passes draw N procedural vertices (gl_VertexIndex
	# indexes the agent state textures) with NO vertex buffer. A pipeline built with
	# INVALID_FORMAT_ID does not expect a bound vertex array — see execute_pass points path.
	# (An empty vertex_format_create([]) still makes the pipeline demand a vertex array.)
	_vfmt_empty = RenderingDevice.INVALID_FORMAT_ID

# --- textures -------------------------------------------------------------

func _data_format(fmt: String) -> int:
	match fmt:
		"rgba32f", "rgba32float":
			return RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
		"rgba8", "rgba8unorm":
			return RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
		_:
			return RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT

func _make_tex(w: int, h: int, fmt: int) -> RID:
	var tf := RDTextureFormat.new()
	tf.width = w
	tf.height = h
	tf.format = fmt
	tf.usage_bits = RenderingDevice.TEXTURE_USAGE_COLOR_ATTACHMENT_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT \
		| RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	var rid := rd.texture_create(tf, RDTextureView.new())
	# Zero-init (matches the reference's null-data textures). Deterministic first-frame
	# read for feedback/state surfaces; harmless for transients (fully overwritten).
	rd.texture_clear(rid, Color(0, 0, 0, 0), 0, 1, 0, 1)
	return rid

func _resolve_dim(d, screen_size: int, uniforms: Dictionary = {}) -> int:
	# Subset of reference/04 §9 resolveDimension. number | "screen"/"auto"/"input" |
	# "N%" | {screenDivide,default} | {scale,clamp} | {param,paramDefault}. True per-pass
	# "input" sizing is staged; at top level the input is screen-sized so "input" == screen.
	# PARITY: screenDivide uses ROUND; param/scale use FLOOR (§9). Divisor/param values come
	# from the merged pass uniforms (e.g. zoom_chain_0).
	if typeof(d) == TYPE_FLOAT or typeof(d) == TYPE_INT:
		return max(1, int(d))
	if typeof(d) == TYPE_STRING:
		var s := str(d)
		if s == "screen" or s == "auto" or s == "input":
			return screen_size
		if s.ends_with("%"):
			return max(1, int(floor(screen_size * s.substr(0, s.length() - 1).to_float() / 100.0)))
	if typeof(d) == TYPE_DICTIONARY:
		if d.has("screenDivide"):
			var key := str(d["screenDivide"])
			var div = uniforms[key] if uniforms.has(key) else d.get("default", 1)
			if div == null or float(div) == 0.0:
				div = d.get("default", 1)
			return max(1, int(round(screen_size / float(div))))
		if d.has("scale"):
			var c := int(floor(screen_size * float(d["scale"])))
			if d.has("clamp"):
				var cl: Dictionary = d["clamp"]
				if cl.has("min"):
					c = max(c, int(cl["min"]))
				if cl.has("max"):
					c = min(c, int(cl["max"]))
			return max(1, c)
		if d.has("param"):
			var pk := str(d["param"])
			var val = uniforms[pk] if uniforms.has(pk) else d.get("paramDefault", 64)
			return max(1, int(floor(float(val))))
	return screen_size

func allocate_textures(graph: Dictionary) -> void:
	_surfaces.clear()
	_frame_read.clear()
	_frame_write.clear()
	_pingpong.clear()
	_tex_dims.clear()
	_tex_fmt.clear()
	var merged := _merge_uniforms(graph)
	var pp := _pingpong_surfaces(graph)
	var texs: Dictionary = graph.get("textures", {})
	for tex_id in texs:
		var spec: Dictionary = texs[tex_id]
		var w := _resolve_dim(spec.get("width", "screen"), screen.x, merged)
		var h := _resolve_dim(spec.get("height", "screen"), screen.y, merged)
		var fmt := _data_format(str(spec.get("format", "rgba16f")))
		_tex_dims[tex_id] = Vector2i(w, h)
		_tex_fmt[tex_id] = fmt
		if pp.has(tex_id):
			_alloc_pingpong(tex_id, w, h, fmt)
		else:
			_textures[tex_id] = _make_tex(w, h, fmt)
	var rs = graph.get("renderSurface", null)
	if rs != null:
		render_surface_tex = "global_" + str(rs)
	# Any output/input texId not declared in graph.textures (e.g. global_o0/o1, the user
	# surfaces) gets a screen-sized rgba16f flat texture — the reference's o0..o7 are HDR
	# (an rgba8 default clamps intermediates to [0,1] and regressed distortion/focusBlur/
	# rotate/step/thresholdMix, whose o0 carries out-of-[0,1] values the reference preserves).
	# Ping-pong surfaces are already allocated above; _ensure_tex skips them.
	for p in graph.get("passes", []):
		for k in p.get("outputs", {}):
			_ensure_tex(str(p["outputs"][k]))
		for k in p.get("inputs", {}):
			var t := str(p["inputs"][k])
			if t != "none":
				_ensure_tex(t)

# A global_<name> surface needs double-buffering ONLY when a pass reads it AT OR BEFORE
# its first write (same-pass read+write, or a prior-frame/feedback read) — i.e. there is a
# read/write hazard. A surface written THEN read in a later pass (a forward dependency, e.g.
# channelCombine reading global_o0 after its blit) is safe with a single flat texture and is
# NOT double-buffered; nor are write-only globals (o0 / the present target). Mirrors the
# _has_feedback condition, per-surface.
func _pingpong_surfaces(graph: Dictionary) -> Dictionary:
	var passes = graph.get("passes", [])
	var first_write := {}
	for i in passes.size():
		for k in passes[i].get("outputs", {}):
			var t := str(passes[i]["outputs"][k])
			if t.begins_with("global_") and not first_write.has(t):
				first_write[t] = i
	var out := {}
	for i in passes.size():
		# (a) Same-pass IN-PLACE read+write (nsPressure Jacobi, nsAdvect): a pass that
		# samples a global surface it ALSO writes is a read-after-write hazard needing a
		# read/write pair, regardless of where the surface's first write lands. Missing this
		# raced the nav pressure/velocity solves into run-to-run nondeterminism (the
		# first-write test below only catches reads AT OR BEFORE the first write).
		var in_set := {}
		for k in passes[i].get("inputs", {}):
			var t := str(passes[i]["inputs"][k])
			if t.begins_with("global_"):
				in_set[t] = true
		for k in passes[i].get("outputs", {}):
			var t := str(passes[i]["outputs"][k])
			if in_set.has(t):
				out[t] = true
		# (b) Read at-or-before the surface's first write (feedback / same-pass seed hazard).
		for k in passes[i].get("inputs", {}):
			var t := str(passes[i]["inputs"][k])
			if t != "none" and t.begins_with("global_") and first_write.has(t) and i <= first_write[t]:
				out[t] = true
	return out

func _alloc_pingpong(tex_id: String, w: int, h: int, fmt: int) -> void:
	var read_key := tex_id + "_read"
	var write_key := tex_id + "_write"
	_textures[read_key] = _make_tex(w, h, fmt)
	_textures[write_key] = _make_tex(w, h, fmt)
	var bare := tex_id.substr("global_".length())
	_surfaces[bare] = {"read": read_key, "write": write_key}
	_pingpong[tex_id] = bare

# Merge every pass.uniforms (last write wins) — the divisor/param source for sub-resolution
# texture sizing (reference collectDefaultUniforms, §9).
func _merge_uniforms(graph: Dictionary) -> Dictionary:
	var out := {}
	for p in graph.get("passes", []):
		var u: Dictionary = p.get("uniforms", {})
		for k in u:
			out[k] = u[k]
	return out

func _ensure_tex(tex_id: String) -> void:
	if _pingpong.has(tex_id):
		return
	if not _textures.has(tex_id):
		var f16 := _data_format("rgba16f")
		_textures[tex_id] = _make_tex(screen.x, screen.y, f16)
		_tex_dims[tex_id] = screen
		_tex_fmt[tex_id] = f16

# --- shader assembly ------------------------------------------------------

func _resolve_includes(src: String) -> String:
	var out := ""
	for line in src.split("\n"):
		var t := line.strip_edges()
		if t.begins_with("#include"):
			var inc := t.get_slice('"', 1)
			var ip := addon_dir + "/shaders/" + inc
			var f := FileAccess.open(ip, FileAccess.READ)
			if f:
				out += f.get_as_text() + "\n"
				f.close()
			else:
				push_error("missing include: " + ip)
		else:
			out += line + "\n"
	return out

# Insert text right after the #version line (defines/UBO decl must precede use).
func _inject_after_version(src: String, inject: String) -> String:
	if inject == "":
		return src
	var out := ""
	var injected := false
	for line in src.split("\n"):
		out += line + "\n"
		if not injected and line.strip_edges().begins_with("#version"):
			out += inject
			injected = true
	return out

func _defines_key(defines: Dictionary) -> String:
	if defines.is_empty():
		return ""
	var keys := defines.keys()
	keys.sort()
	var s := ""
	for k in keys:
		s += "__%s_%s" % [k, str(defines[k])]
	return s

func _load_fragment(ns: String, fn: String, prog: String) -> String:
	# Shaders live func-qualified at effects/<ns>/<func>/<prog>.glsl, mirroring the
	# reference <ns>/<func>/glsl/<prog> layout. This disambiguates funcs that share a
	# namespace + progName but have different shaders (pointsRender vs pointsBillboardRender:
	# both render/deposit, render/diffuse, render/blend — distinct programs).
	var path := addon_dir + "/shaders/effects/%s/%s/%s.glsl" % [ns, fn, prog]
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("missing shader: " + path)
		return ""
	var s := f.get_as_text()
	f.close()
	return _resolve_includes(s)

func _get_shader(cache_key: String, vert_src: String, frag_src: String) -> RID:
	if _shaders.has(cache_key):
		return _shaders[cache_key]
	var src := RDShaderSource.new()
	src.source_vertex = vert_src
	src.source_fragment = frag_src
	var spirv := rd.shader_compile_spirv_from_source(src)
	for stage in [RenderingDevice.SHADER_STAGE_VERTEX, RenderingDevice.SHADER_STAGE_FRAGMENT]:
		var e := spirv.get_stage_compile_error(stage)
		if e != "":
			push_error("[shader %s] %s" % [cache_key, e])
			return RID()
	var sh := rd.shader_create_from_spirv(spirv)
	_shaders[cache_key] = sh
	return sh

func _get_pipeline(cache_key: String, shader: RID, fb_format: int, n_attach: int,
		primitive: int, additive: bool, vfmt: int) -> RID:
	var key := "%s:%d:%d:%d:%s" % [cache_key, fb_format, n_attach, primitive, "add" if additive else "rep"]
	if _pipelines.has(key):
		return _pipelines[key]
	var blend := RDPipelineColorBlendState.new()
	for _i in n_attach:
		var a := RDPipelineColorBlendStateAttachment.new()
		if additive:
			# Additive ONE,ONE accumulation for agent deposit passes (HDR trail). The
			# reference notes Babylon's ALPHA_ADD (SRC_ALPHA,ONE) crushes accumulation —
			# it must be straight ONE,ONE on both color and alpha.
			a.enable_blend = true
			a.src_color_blend_factor = RenderingDevice.BLEND_FACTOR_ONE
			a.dst_color_blend_factor = RenderingDevice.BLEND_FACTOR_ONE
			a.color_blend_op = RenderingDevice.BLEND_OP_ADD
			a.src_alpha_blend_factor = RenderingDevice.BLEND_FACTOR_ONE
			a.dst_alpha_blend_factor = RenderingDevice.BLEND_FACTOR_ONE
			a.alpha_blend_op = RenderingDevice.BLEND_OP_ADD
		blend.attachments.push_back(a)
	var p := rd.render_pipeline_create(shader, fb_format, vfmt,
		primitive, RDPipelineRasterizationState.new(),
		RDPipelineMultisampleState.new(), RDPipelineDepthStencilState.new(), blend)
	_pipelines[key] = p
	return p

# Vertex shader for a custom-draw program (agent deposit): effects/<ns>/<func>/<prog>.vert.glsl.
func _load_vertex(ns: String, fn: String, prog: String) -> String:
	var path := addon_dir + "/shaders/effects/%s/%s/%s.vert.glsl" % [ns, fn, prog]
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("missing vertex shader: " + path)
		return ""
	var s := f.get_as_text()
	f.close()
	return _resolve_includes(s)

# Draw-vertex count for an agent deposit pass. count:number is literal; count:"input"/"auto"/
# "screen" derives the agent count from the state input texture (stateSize²). Billboards expand
# ×6 (two tris/quad) at the call site.
func _resolve_count(p: Dictionary) -> int:
	var c = p.get("count", 1)
	if typeof(c) == TYPE_STRING:
		var inputs: Dictionary = p.get("inputs", {})
		var src_id := str(inputs.get("xyzTex", ""))
		if src_id == "" or src_id == "none":
			for k in inputs:
				var t := str(inputs[k])
				if t != "none" and t != "":
					src_id = t
					break
		var d: Vector2i = _tex_dims.get(src_id, Vector2i(0, 0))
		return d.x * d.y
	return max(0, int(c))

# --- effect definitions + uniform packing ---------------------------------

func _load_effect_def(ns: String, fn: String) -> Dictionary:
	var key := ns + "/" + fn
	if _effect_defs.has(key):
		return _effect_defs[key]
	var path := addon_dir + "/effects/%s/%s.json" % [ns, fn]
	var def := {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f:
		var parsed = JSON.parse_string(f.get_as_text())
		f.close()
		if typeof(parsed) == TYPE_DICTIONARY:
			def = parsed
	_effect_defs[key] = def
	return def

func _type_width(t: String) -> int:
	match t:
		"vec2":
			return 2
		"vec3", "color":
			return 3
		"vec4":
			return 4
		_:
			return 1

# Synthesize a packed layout for a no-layout effect: fixed engine header (slots 0-2)
# then each `uniform` global from slot 3 in declaration order (multi-component values
# never straddle a vec4).
func _synth_layout(ns: String, fn: String, globals: Dictionary) -> Dictionary:
	var key := ns + "/" + fn
	if _synth_cache.has(key):
		return _synth_cache[key]
	var layout := {}
	for k in ENGINE_SYNTH:
		layout[k] = ENGINE_SYNTH[k]
	var letters := ["x", "y", "z", "w"]
	var slot := 3
	var cursor := 0
	for gk in globals:
		var g = globals[gk]
		if not g.has("uniform"):
			continue
		var w := _type_width(str(g.get("type", "float")))
		if cursor + w > 4:
			slot += 1
			cursor = 0
		var comps := ""
		for i in range(w):
			comps += letters[cursor + i]
		layout[str(g["uniform"])] = {"slot": slot, "components": comps}
		cursor += w
		if cursor >= 4:
			slot += 1
			cursor = 0
	_synth_cache[key] = layout
	return layout

# UBO decl + #define block injected for synthesized (no-layout) effects.
func _synth_header(layout: Dictionary) -> String:
	var max_slot := 0
	for k in layout:
		max_slot = max(max_slot, int(layout[k]["slot"]))
	var s := "layout(set=0,binding=0,std140) uniform Params { vec4 data[%d]; };\n" % (max_slot + 1)
	for k in layout:
		s += "#define %s data[%d].%s\n" % [k, int(layout[k]["slot"]), str(layout[k]["components"])]
	return s

func _engine_value(name: String) -> Array:
	match name:
		"resolution", "fullResolution":
			return [float(screen.x), float(screen.y)]
		"tileOffset":
			return [0.0, 0.0]
		"time":
			return [_time]
		"aspectRatio":
			return [float(screen.x) / float(screen.y) if screen.y != 0 else 1.0]
		"renderScale":
			return [_render_scale]
		"deltaTime":
			return [_delta_time]
		"frame":
			return [float(_frame_index)]
	return [0.0]

func _comp_offsets(components: String) -> Array:
	var m := {"x": 0, "y": 1, "z": 2, "w": 3}
	var out := []
	for c in components:
		out.append(m[c])
	return out

func _value_floats(v) -> Array:
	if typeof(v) == TYPE_BOOL:
		return [1.0 if v else 0.0]
	if typeof(v) == TYPE_ARRAY:
		var out := []
		for x in v:
			out.append(float(x))
		return out
	return [float(v)]

func pack_with_layout(layout: Dictionary, globals: Dictionary, p: Dictionary) -> PackedByteArray:
	var max_slot := 0
	for name in layout:
		max_slot = max(max_slot, int(layout[name]["slot"]))
	var data := PackedFloat32Array()
	data.resize((max_slot + 1) * 4)
	var pass_u: Dictionary = p.get("uniforms", {})
	for name in layout:
		var slot := int(layout[name]["slot"])
		var offs := _comp_offsets(str(layout[name]["components"]))
		var vals: Array
		if ENGINE_GLOBALS.has(name):
			vals = _engine_value(name)
		elif pass_u.has(name):
			vals = _value_floats(pass_u[name])
		elif globals.has(name) and globals[name].has("default"):
			vals = _value_floats(globals[name]["default"])
		else:
			vals = [0.0]
		for i in range(min(offs.size(), vals.size())):
			data[slot * 4 + offs[i]] = vals[i]
	return data.to_byte_array()

func _pack_pass(p: Dictionary) -> PackedByteArray:
	var ns := str(p.get("namespace"))
	var fn := str(p.get("func"))
	var def := _load_effect_def(ns, fn)
	var globals: Dictionary = def.get("globals", {})
	# A DECLARED layout (uniformLayout, or uniformLayouts[prog]) is used verbatim even when
	# it is empty {} — that means "the .glsl declares its own UBO with no mapped params"
	# (e.g. filter/invert). Only effects with NO layout declaration get a synthesized one.
	if _has_layout(def, p):
		return pack_with_layout(_layout_for(def, p), globals, p)
	return pack_with_layout(_synth_layout(ns, fn, globals), globals, p)

# Whether the effect DECLARES a uniform layout for this pass: a single `uniformLayout`
# (any value, including empty {}), or a per-program `uniformLayouts[progName]` (multi-
# program effects like cellularAutomata's ca/caFb). Drives both the synth-header decision
# and packing. An empty {} still counts as declared — do NOT confuse "empty" with "absent".
func _has_layout(def: Dictionary, p: Dictionary) -> bool:
	if def.has("uniformLayout"):
		return true
	if def.has("uniformLayouts"):
		return def["uniformLayouts"].has(str(p.get("progName", p.get("func"))))
	return false

# The declared layout dict for a pass (only meaningful when _has_layout is true).
func _layout_for(def: Dictionary, p: Dictionary) -> Dictionary:
	if def.has("uniformLayouts"):
		return def["uniformLayouts"].get(str(p.get("progName", p.get("func"))), {})
	return def.get("uniformLayout", {})

# --- execution ------------------------------------------------------------

# A pass is one of four draws, dispatched on outputs + drawMode:
#   fullscreen  — 1 output, fullscreen triangle (the 93 isolation effects + blit)
#   MRT         — N outputs (drawBuffers>1), fullscreen triangle into N attachments
#                 (agent state updates: pointsEmit/init, flow/agent write xyz+vel+rgba)
#   points      — drawMode "points": N procedural point primitives, one per agent, custom
#                 vertex shader fetching agent position from the state textures (deposit)
#   billboards  — drawMode "billboards": N×6 procedural triangles (agent quads)
# points/billboards use ONE,ONE additive blend (blend:true) and do NOT clear — they
# accumulate onto the trail the copy pass just produced (reference deposit semantics).
func execute_pass(p: Dictionary) -> void:
	var ptype := str(p.get("passType", "effect"))
	var draw_mode := str(p.get("drawMode", ""))
	var is_points := draw_mode == "points" or draw_mode == "billboards"
	var cache_key := ""
	var frag_src := ""
	var vert_src := FULLSCREEN_VS
	if ptype == "blit":
		cache_key = "blit"
		frag_src = BLIT_FS
	else:
		var ns := str(p.get("namespace"))
		var fn := str(p.get("func"))
		# Shaders are keyed by progName (an effect may have several programs, e.g.
		# blur -> blurH/blurV); the effect DEFINITION (globals/layout) is keyed by func.
		var prog := str(p.get("progName", fn))
		var defs: Dictionary = p.get("defines", {})
		var def := _load_effect_def(ns, fn)
		var inject := ""
		for k in defs:
			# Defines are compile-time integer enums; emit as ints (Godot JSON parses
			# them as floats, which would otherwise inject `10.0`).
			inject += "#define %s %d\n" % [k, int(defs[k])]
		# Synthesize + inject the UBO only for true no-layout effects. Effects that DECLARE
		# a layout (uniformLayout — even empty {} — or uniformLayouts[prog]) declare their
		# own Params block in the .glsl; injecting one too would duplicate it.
		if not _has_layout(def, p):
			inject += _synth_header(_synth_layout(ns, fn, def.get("globals", {})))
		cache_key = ns + "/" + fn + "/" + prog + _defines_key(defs)
		frag_src = _inject_after_version(_load_fragment(ns, fn, prog), inject)
		# Agent deposit passes carry a custom vertex stage (gl_VertexIndex scatter); the
		# same UBO/defines are injected into it so the VS can read params + sample state.
		if is_points:
			vert_src = _inject_after_version(_load_vertex(ns, fn, prog), inject)
	var shader := _get_shader(cache_key, vert_src, frag_src)
	if not shader.is_valid():
		return

	# Resolve every output to its write RID, in declaration order (= shader layout(location=i)).
	# Double-buffered surfaces render into the current WRITE buffer; everything else flat.
	var outputs: Dictionary = p.get("outputs", {})
	var out_rids := []
	for k in outputs:
		var rid := _resolve_write(str(outputs[k]))
		if not rid.is_valid():
			push_error("pass output texture missing: " + str(outputs[k]))
			return
		out_rids.append(rid)
	if out_rids.is_empty():
		return
	var fb := rd.framebuffer_create(out_rids)
	var fb_format := rd.framebuffer_get_format(fb)
	var n_attach := out_rids.size()
	var primitive := RenderingDevice.RENDER_PRIMITIVE_POINTS if draw_mode == "points" \
		else RenderingDevice.RENDER_PRIMITIVE_TRIANGLES
	var additive := bool(p.get("blend", false))
	var vfmt := _vfmt_empty if is_points else _vfmt
	var pipeline := _get_pipeline(cache_key, shader, fb_format, n_attach, primitive, additive, vfmt)

	var set0_uniforms := []
	if ptype == "blit":
		var src_id := str(p.get("inputs", {}).get("src", "none"))
		var su := RDUniform.new()
		su.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
		su.binding = 0
		su.add_id(_sampler)
		su.add_id(_resolve_read(src_id))
		set0_uniforms.append(su)
	else:
		var ubytes := _pack_pass(p)
		var ubo := rd.uniform_buffer_create(ubytes.size(), ubytes)
		var u0 := RDUniform.new()
		u0.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
		u0.binding = 0
		u0.add_id(ubo)
		set0_uniforms.append(u0)
		# Bind set-0 samplers BY NAME to the shader's declared bindings. A pass may list
		# more inputs than the shader uses (e.g. cellularAutomata's render pass lists 4,
		# uses 1); the SPIR-V compiler strips the unused ones, so we bind exactly the
		# declared+surviving samplers. "none"/missing inputs resolve to the black texture.
		# Deposit samplers (xyzTex/rgbaTex) live in the VERTEX stage, so parse BOTH sources.
		var inputs: Dictionary = p.get("inputs", {})
		for s in _samplers_for(cache_key, frag_src + "\n" + vert_src):
			var tid := str(inputs.get(s["name"], "none"))
			var u := RDUniform.new()
			u.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
			u.binding = int(s["binding"])
			u.add_id(_sampler)
			u.add_id(_resolve_read(tid))
			set0_uniforms.append(u)
	var set0 := rd.uniform_set_create(set0_uniforms, shader, 0)

	# Deposit accumulates onto the existing trail (no clear); all other passes clear their
	# N attachments to transparent black, then a full-coverage draw overwrites every texel.
	var dl: int
	if is_points:
		dl = rd.draw_list_begin(fb, 0, PackedColorArray())
	else:
		var clears := PackedColorArray()
		for _i in n_attach:
			clears.append(Color(0, 0, 0, 0))
		dl = rd.draw_list_begin(fb, RenderingDevice.DRAW_CLEAR_COLOR_ALL, clears)
	rd.draw_list_bind_render_pipeline(dl, pipeline)
	rd.draw_list_bind_uniform_set(dl, set0, 0)
	if is_points:
		# Procedural draw: N (or N×6) vertices, no vertex buffer — gl_VertexIndex indexes
		# the agent state textures in the deposit vertex shader.
		var count := _resolve_count(p)
		if draw_mode == "billboards":
			count *= 6
		rd.draw_list_draw(dl, false, 1, count)
	else:
		rd.draw_list_bind_vertex_array(dl, _varr)
		rd.draw_list_draw(dl, false, 1)
	rd.draw_list_end()

# --- ping-pong resolution -------------------------------------------------

# Texture an input texId samples FROM. Double-buffered surfaces resolve to this frame's
# read buffer; "none"/unknown resolve to the black texture (reference BlackTex).
func _resolve_read(tex_id: String) -> RID:
	if tex_id == "none" or tex_id == "":
		return _black_tex
	if _pingpong.has(tex_id):
		return _textures[_frame_read[_pingpong[tex_id]]]
	if _textures.has(tex_id):
		return _textures[tex_id]
	return _black_tex

# Texture an output texId renders INTO. Double-buffered surfaces resolve to this frame's
# write buffer. Returns an invalid RID if the target is genuinely missing.
func _resolve_write(tex_id: String) -> RID:
	if _pingpong.has(tex_id):
		return _textures[_frame_write[_pingpong[tex_id]]]
	if _textures.has(tex_id):
		return _textures[tex_id]
	return RID()

# Declared set-0 samplers for an assembled shader, parsed once and cached by cache_key.
func _samplers_for(cache_key: String, frag_src: String) -> Array:
	if _samplers.has(cache_key):
		return _samplers[cache_key]
	var out := []
	for m in _sampler_re.search_all(frag_src):
		out.append({"name": m.get_string(2), "binding": int(m.get_string(1))})
	_samplers[cache_key] = out
	return out

# True if any pass reads a texId at or before the pass that first writes it — the read
# depends on a prior frame's content (feedback/state). Such graphs need a multi-frame
# settle. (Same-surface read+write in ONE pass also trips this; those are now double-
# buffered — see _pingpong_surfaces / the frame swap hooks below. Separate read/write
# passes, e.g. feedback's selfTex, work with persistent textures + the frame loop alone.)
func _has_feedback(graph: Dictionary) -> bool:
	var passes = graph.get("passes", [])
	var first_write := {}
	for i in passes.size():
		for k in passes[i].get("outputs", {}):
			var t := str(passes[i]["outputs"][k])
			if not first_write.has(t):
				first_write[t] = i
	for i in passes.size():
		for k in passes[i].get("inputs", {}):
			var t := str(passes[i]["inputs"][k])
			if t != "none" and first_write.has(t) and i <= first_write[t]:
				return true
	return false

func render(graph: Dictionary, normalized_time: float = 0.25) -> void:
	_time = normalized_time
	allocate_textures(graph)
	# Feedback/state graphs (read-before-write, or any double-buffered surface) need the
	# reference's settle count (8 frames at the pinned time, reference/04 §10). Otherwise a
	# single deterministic pass.
	var frames := 8 if (_has_feedback(graph) or not _pingpong.is_empty()) else 1
	for _frame in frames:
		_begin_frame()
		for p in graph.get("passes", []):
			# A pass may repeat within the frame (reference §10.5, e.g. reactionDiffusion's
			# `repeat: "iterations"` solver). Each iteration ping-pongs so it reads the prior
			# iteration's output (§10.6) — distinct from the within-frame and end-of-frame swaps.
			var rc := _repeat_count(p)
			for _iter in rc:
				execute_pass(p)
				_update_frame_bindings(p)
				if rc > 1:
					_swap_iteration_buffers(p)
		_end_frame()
	rd.submit()
	rd.sync()

# Timed multi-sample render for stateful sims (reference 30s/5s sampling). Steps a real
# per-frame deltaTime (1/600 normalized = one 60fps frame in the 10s loop) so fluid/feedback
# sims actually EVOLVE — the single-frame render() pins deltaTime=0, freezing them at the seed.
# Snapshots the render surface every `sample_every` frames; returns the sampled Images in order.
func render_samples(graph: Dictionary, total_frames: int, sample_every: int) -> Array:
	allocate_textures(graph)
	var dt := 1.0 / 600.0
	var samples := []
	for frame in range(1, total_frames + 1):
		_time = fposmod(float(frame) * dt, 1.0)
		_delta_time = dt
		_frame_index = frame
		_begin_frame()
		for p in graph.get("passes", []):
			var rc := _repeat_count(p)
			for _iter in rc:
				execute_pass(p)
				_update_frame_bindings(p)
				if rc > 1:
					_swap_iteration_buffers(p)
		_end_frame()
		# Submit/sync each frame: keeps command buffers small (a 40-iteration nsPressure
		# solve over hundreds of accumulated frames would otherwise overflow one buffer) and
		# serializes frame N before N+1. Determinism comes from correct ping-pong pairs
		# (see _pingpong_surfaces), not from batching.
		rd.submit()
		rd.sync()
		if frame % sample_every == 0:
			samples.append(_snapshot_surface())
	return samples

# reference §10.5 resolveRepeatCount: no repeat -> 1; number -> max(1,floor); string ->
# look it up in the pass uniforms (the iteration count is a pass uniform, e.g. iterations=8).
func _repeat_count(p: Dictionary) -> int:
	var r = p.get("repeat", null)
	if r == null:
		return 1
	if typeof(r) == TYPE_FLOAT or typeof(r) == TYPE_INT:
		return max(1, int(floor(float(r))))
	if typeof(r) == TYPE_STRING:
		var u: Dictionary = p.get("uniforms", {})
		if u.has(r):
			var v = u[r]
			if typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT:
				return max(1, int(floor(float(v))))
	return 1

# reference §10.6 swapIterationBuffers: between iterations of a repeated pass, swap the
# surface RECORD read<->write and mirror the frame maps FROM the swapped record (so the
# next iteration reads the texel just written). Distinct from §10.2/§10.7.
func _swap_iteration_buffers(p: Dictionary) -> void:
	for k in p.get("outputs", {}):
		var t := str(p["outputs"][k])
		if not _pingpong.has(t):
			continue
		var bare: String = _pingpong[t]
		var rec: Dictionary = _surfaces[bare]
		var tmp = rec["read"]
		rec["read"] = rec["write"]
		rec["write"] = tmp
		_frame_read[bare] = rec["read"]
		_frame_write[bare] = rec["write"]

# reference/04 §10 step 4 / BeginFrame: seed each surface's read/write bindings from its
# record at the start of the frame.
func _begin_frame() -> void:
	for bare in _surfaces:
		_frame_read[bare] = _surfaces[bare]["read"]
		_frame_write[bare] = _surfaces[bare]["write"]

# Within-frame ping-pong (reference §10.2): after a pass writes a double-buffered surface,
# subsequent reads see the just-written buffer and the next write targets the old read
# buffer. Keyed on outputs only.
func _update_frame_bindings(p: Dictionary) -> void:
	for k in p.get("outputs", {}):
		var t := str(p["outputs"][k])
		if not _pingpong.has(t):
			continue
		var bare: String = _pingpong[t]
		if not _frame_write.has(bare):
			continue
		var write_id = _frame_write[bare]
		var cur_read = _frame_read.get(bare, null)
		_frame_read[bare] = write_id
		if cur_read != null:
			_frame_write[bare] = cur_read

# End-of-frame swap (reference §10.7): state surfaces persist their final frame bindings
# (the sim continues from the latest buffers — NO toggle); display surfaces toggle
# read<->write. (Per-iteration swap for repeat>1 passes is staged — no current program
# uses repeat.)
func _end_frame() -> void:
	for bare in _surfaces:
		var rec: Dictionary = _surfaces[bare]
		if _is_state_surface(bare):
			if _frame_read.has(bare) and _frame_write.has(bare):
				rec["read"] = _frame_read[bare]
				rec["write"] = _frame_write[bare]
		else:
			var tmp = rec["read"]
			rec["read"] = rec["write"]
			rec["write"] = tmp

# reference §10.7 isStateSurface (case-sensitive): exact/suffix xyz|vel|rgba|trail, the
# substring state/State, or ^(xyz|vel|rgba|points_trail)_node_\d+$. State surfaces persist
# across frames (sims/particles); display surfaces double-buffer with a per-frame toggle.
func _is_state_surface(name: String) -> bool:
	if name == "":
		return false
	if name == "xyz" or name == "vel" or name == "rgba" or name == "trail":
		return true
	if name.ends_with("_xyz") or name.ends_with("_vel") or name.ends_with("_rgba") or name.ends_with("_trail"):
		return true
	if name.find("state") >= 0 or name.find("State") >= 0:
		return true
	return _state_node_re.search(name) != null

# Snapshot the current render surface to an 8-bit Image (per-sample / per-frame capture).
func _snapshot_surface() -> Image:
	if not _textures.has(render_surface_tex):
		return null
	var bytes := rd.texture_get_data(_textures[render_surface_tex], 0)
	# Read the render surface in its ACTUAL format. User surfaces (o0/o1) are rgba8 like the
	# reference; declared HDR surfaces are rgba16f. Misreading rgba8 bytes as half-float is
	# garbage, so pick the Image format from the tracked RD format.
	var rdfmt := int(_tex_fmt.get(render_surface_tex, _data_format("rgba16f")))
	var img_fmt := Image.FORMAT_RGBAH
	if rdfmt == RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM:
		img_fmt = Image.FORMAT_RGBA8
	elif rdfmt == RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT:
		img_fmt = Image.FORMAT_RGBAF
	var src := Image.create_from_data(screen.x, screen.y, false, img_fmt, bytes)
	# Single global Y reconciliation (present point, like the Unity NMBlit flip): the
	# webgl2/GLSL golden is bottom-left flipped to a top-down PNG; our pipeline is
	# uniformly top-left, so the result is one vertical flip away.
	src.flip_y()
	# rgba8 surfaces are already 8-bit — return directly. For half/float surfaces, save_png
	# clobbers alpha to opaque, so quantize to 8-bit ourselves (round, clamp, NO sRGB),
	# preserving alpha and matching the reference's round(v*255).
	if img_fmt == Image.FORMAT_RGBA8:
		return src
	var out := Image.create(screen.x, screen.y, false, Image.FORMAT_RGBA8)
	for y in screen.y:
		for x in screen.x:
			out.set_pixel(x, y, src.get_pixel(x, y))
	return out

func save_surface_png(path: String) -> bool:
	var img := _snapshot_surface()
	if img == null:
		push_error("render surface missing: " + render_surface_tex)
		return false
	img.save_png(path)
	return true
