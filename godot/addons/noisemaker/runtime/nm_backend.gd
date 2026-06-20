# nm_backend.gd — RenderingDevice executor for the Noisemaker render graph.
# Mirrors the WebGL2 GPGPU model (reference/04 §5 backend contract): every pass is
# a fullscreen fragment draw into a color attachment; "compute" passes are render
# passes with MRT. Ported structurally from the Unity NMRenderBackend.cs.
#
# Binding convention (all Godot effect shaders follow it):
#   set 0, binding 0      : Params UBO  `uniform Params { vec4 data[N]; }`  (effect passes)
#   set 0, binding 1..k   : input sampler2D, in pass.inputs declaration order
#   blit pass is special  : sampler2D `src` at set 0, binding 0 (no UBO)
#
# Uniforms: a single packed `vec4 data[N]` UBO per pass. Effects WITH a reference
# uniformLayout (noise/cell/...) use it verbatim (engine globals + params packed by
# slot/component, so the WGSL body is unchanged). Effects WITHOUT one (solid) fall
# back to declaration-order packing from slot 0.
#
# Compile-time defines (NOISE_TYPE, LOOP_OFFSET) are injected as `#define` after the
# #version line; shaders are cached per (program, define-set).
#
# Coordinates: Godot RenderingDevice is top-left origin / Vulkan Y-down clip, same
# as WGSL — port from WGSL, NO per-effect Y-flip. texture_get_data is top-down.
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

# Engine-provided globals (reference/04 §10.1) — sourced from the runtime, not the
# pass uniforms. Used by the layout packer to fill the data[] slots they name.
const ENGINE_GLOBALS := {
	"resolution": true, "time": true, "aspectRatio": true, "tileOffset": true,
	"fullResolution": true, "renderScale": true, "deltaTime": true, "frame": true,
}

var rd: RenderingDevice
var addon_dir: String
var screen: Vector2i
var _sampler: RID
var _vfmt: int
var _varr: RID
var _shaders := {}          # cache key -> RID
var _pipelines := {}        # cache key:fbformat -> RID
var _textures := {}         # texId -> RID
var _effect_defs := {}      # "ns/fn" -> def dict
var render_surface_tex := ""
# engine globals for the current render (paused parity defaults)
var _time := 0.25
var _render_scale := 1.0

func setup(p_rd: RenderingDevice, p_addon_dir: String, p_screen: Vector2i) -> void:
	rd = p_rd
	addon_dir = p_addon_dir
	screen = p_screen
	var ss := RDSamplerState.new()
	ss.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	ss.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	ss.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	ss.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_sampler = rd.sampler_create(ss)
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

# ---------------------------------------------------------------------------
# Textures
# ---------------------------------------------------------------------------

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
	return rd.texture_create(tf, RDTextureView.new())

func _resolve_dim(d, screen_size: int) -> int:
	# Phase-2 minimal: number or "screen"/"auto". Full Dim rules land in dim.gd.
	if typeof(d) == TYPE_FLOAT or typeof(d) == TYPE_INT:
		return max(1, int(d))
	if typeof(d) == TYPE_STRING and (d == "screen" or d == "auto"):
		return screen_size
	return screen_size

func allocate_textures(graph: Dictionary) -> void:
	var texs: Dictionary = graph.get("textures", {})
	for tex_id in texs:
		var spec: Dictionary = texs[tex_id]
		var w := _resolve_dim(spec.get("width", "screen"), screen.x)
		var h := _resolve_dim(spec.get("height", "screen"), screen.y)
		_textures[tex_id] = _make_tex(w, h, _data_format(str(spec.get("format", "rgba16f"))))
	var rs = graph.get("renderSurface", null)
	if rs != null:
		render_surface_tex = "global_" + str(rs)
	for p in graph.get("passes", []):
		for k in p.get("outputs", {}):
			_ensure_tex(str(p["outputs"][k]))
		for k in p.get("inputs", {}):
			var t := str(p["inputs"][k])
			if t != "none":
				_ensure_tex(t)

func _ensure_tex(tex_id: String) -> void:
	if not _textures.has(tex_id):
		_textures[tex_id] = _make_tex(screen.x, screen.y, _data_format("rgba16f"))

# ---------------------------------------------------------------------------
# Shader assembly (include resolution + define injection)
# ---------------------------------------------------------------------------

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

# Inject `#define K V` right after the #version line (defines must precede use).
func _inject_defines(src: String, defines: Dictionary) -> String:
	if defines.is_empty():
		return src
	var lines := src.split("\n")
	var out := ""
	var injected := false
	for line in lines:
		out += line + "\n"
		if not injected and line.strip_edges().begins_with("#version"):
			for k in defines:
				out += "#define %s %s\n" % [k, str(defines[k])]
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

func _load_fragment(ns: String, fn: String) -> String:
	var path := addon_dir + "/shaders/effects/%s/%s.glsl" % [ns, fn]
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("missing shader: " + path)
		return ""
	var s := f.get_as_text()
	f.close()
	return _resolve_includes(s)

func _get_shader(cache_key: String, frag_src: String) -> RID:
	if _shaders.has(cache_key):
		return _shaders[cache_key]
	var src := RDShaderSource.new()
	src.source_vertex = FULLSCREEN_VS
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

func _get_pipeline(cache_key: String, shader: RID, fb_format: int) -> RID:
	var key := cache_key + ":" + str(fb_format)
	if _pipelines.has(key):
		return _pipelines[key]
	var blend := RDPipelineColorBlendState.new()
	blend.attachments.push_back(RDPipelineColorBlendStateAttachment.new())
	var p := rd.render_pipeline_create(shader, fb_format, _vfmt,
		RenderingDevice.RENDER_PRIMITIVE_TRIANGLES, RDPipelineRasterizationState.new(),
		RDPipelineMultisampleState.new(), RDPipelineDepthStencilState.new(), blend)
	_pipelines[key] = p
	return p

# ---------------------------------------------------------------------------
# Effect definitions + uniform packing
# ---------------------------------------------------------------------------

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

# Engine global value (array of floats) for the current paused render.
func _engine_value(name: String) -> Array:
	match name:
		"resolution":
			return [float(screen.x), float(screen.y)]
		"fullResolution":
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
			return [0.0]
		"frame":
			return [0.0]
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

# Pack per the reference uniformLayout: engine globals + pass uniforms (or effect
# defaults) into a vec4[N] array, by slot/component.
func pack_with_layout(layout: Dictionary, globals: Dictionary, p: Dictionary) -> PackedByteArray:
	var max_slot := 0
	for name in layout:
		max_slot = max(max_slot, int(layout[name]["slot"]))
	var data := PackedFloat32Array()
	data.resize((max_slot + 1) * 4)  # zero-filled
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

# Fallback for individual-uniform effects with no layout (solid): pack the pass
# uniforms in declaration order from slot 0.
func _pack_simple(p: Dictionary) -> PackedByteArray:
	var comps := PackedFloat32Array()
	for name in p.get("uniforms", {}):
		for x in _value_floats(p["uniforms"][name]):
			comps.append(x)
	while comps.size() == 0 or comps.size() % 4 != 0:
		comps.append(0.0)
	return comps.to_byte_array()

func _pack_pass(p: Dictionary) -> PackedByteArray:
	var def := _load_effect_def(str(p.get("namespace")), str(p.get("func")))
	if def.has("uniformLayout"):
		return pack_with_layout(def["uniformLayout"], def.get("globals", {}), p)
	return _pack_simple(p)

# ---------------------------------------------------------------------------
# Execution
# ---------------------------------------------------------------------------

func execute_pass(p: Dictionary) -> void:
	var ptype := str(p.get("passType", "effect"))
	var cache_key := ""
	var frag_src := ""
	if ptype == "blit":
		cache_key = "blit"
		frag_src = BLIT_FS
	else:
		var ns := str(p.get("namespace"))
		var fn := str(p.get("func"))
		var defs: Dictionary = p.get("defines", {})
		cache_key = ns + "/" + fn + _defines_key(defs)
		frag_src = _inject_defines(_load_fragment(ns, fn), defs)
	var shader := _get_shader(cache_key, frag_src)
	if not shader.is_valid():
		return

	var outputs: Dictionary = p.get("outputs", {})
	var out_tex_id := ""
	for k in outputs:
		out_tex_id = str(outputs[k])
		break
	if not _textures.has(out_tex_id):
		push_error("pass output texture missing: " + out_tex_id)
		return
	var fb := rd.framebuffer_create([_textures[out_tex_id]])
	var fb_format := rd.framebuffer_get_format(fb)
	var pipeline := _get_pipeline(cache_key, shader, fb_format)

	var set0_uniforms := []
	if ptype == "blit":
		var src_id := str(p.get("inputs", {}).get("src", "none"))
		var su := RDUniform.new()
		su.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
		su.binding = 0
		su.add_id(_sampler)
		su.add_id(_textures[src_id])
		set0_uniforms.append(su)
	else:
		var ubytes := _pack_pass(p)
		var ubo := rd.uniform_buffer_create(ubytes.size(), ubytes)
		var u0 := RDUniform.new()
		u0.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
		u0.binding = 0
		u0.add_id(ubo)
		set0_uniforms.append(u0)
		var bi := 1
		for sampler_name in p.get("inputs", {}):
			var tid := str(p["inputs"][sampler_name])
			if tid == "none":
				continue
			var u := RDUniform.new()
			u.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
			u.binding = bi
			u.add_id(_sampler)
			u.add_id(_textures[tid])
			set0_uniforms.append(u)
			bi += 1
	var set0 := rd.uniform_set_create(set0_uniforms, shader, 0)

	var dl := rd.draw_list_begin(fb, RenderingDevice.DRAW_CLEAR_COLOR_ALL,
		PackedColorArray([Color(0, 0, 0, 0)]))
	rd.draw_list_bind_render_pipeline(dl, pipeline)
	rd.draw_list_bind_uniform_set(dl, set0, 0)
	rd.draw_list_bind_vertex_array(dl, _varr)
	rd.draw_list_draw(dl, false, 1)
	rd.draw_list_end()

func render(graph: Dictionary, normalized_time: float = 0.25) -> void:
	_time = normalized_time
	allocate_textures(graph)
	for p in graph.get("passes", []):
		execute_pass(p)
	rd.submit()
	rd.sync()

func save_surface_png(path: String) -> bool:
	if not _textures.has(render_surface_tex):
		push_error("render surface missing: " + render_surface_tex)
		return false
	var bytes := rd.texture_get_data(_textures[render_surface_tex], 0)
	var src := Image.create_from_data(screen.x, screen.y, false, Image.FORMAT_RGBAH, bytes)
	# Single global Y reconciliation (the present point, analogous to the Unity NMBlit
	# flip). The reference golden is webgl2/GLSL (bottom-left origin) flipped to a
	# top-down PNG; our pipeline is uniformly top-left (Vulkan), so the composited
	# result is one vertical flip away. RenderingDevice keeps orientation consistent
	# across passes, so this depth-independent flip reconciles every effect.
	src.flip_y()
	# Godot's save_png on a half-float image clobbers alpha to opaque. Quantize the
	# linear float surface to 8-bit ourselves (round, clamp, NO sRGB), preserving the
	# alpha channel — this also matches the reference's exact round(v*255) (parity).
	var out := Image.create(screen.x, screen.y, false, Image.FORMAT_RGBA8)
	for y in screen.y:
		for x in screen.x:
			out.set_pixel(x, y, src.get_pixel(x, y))
	out.save_png(path)
	return true
