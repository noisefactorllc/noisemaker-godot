# expander.gd — expands the logical graph (validator plans) into a render graph (passes). Port of
# the REFERENCE shaders/src/runtime/expander.js (cross-checked vs noisemaker-hlsl Expander.cs).
# Sources: upstream noisemaker + noisemaker-hlsl ONLY.
#
# expand(compilation_result, options) -> {passes, errors, programs, textureSpecs, renderSurface}.
# Threads the current 2D/3D/geo/agent input texture through each chain, expands each effect def's
# passes/textures/globals into concrete passes with resolved inputs/outputs/uniforms, scopes shared
# textures to the chain or particle pipeline, and expands classicNoisedeck palette indices.
#
# Instance-owned, constructed with an EffectRegistry (for get_effect + std enums). The per-plan
# scope context (_cur_particle_pipeline_id, _chain_scope_id) lives in instance vars so the scope
# helpers can read it (GDScript has no closures).
#
# NOTE: effect JSON defs carry no inline `shaders`, so the program-collection block is skipped and
# `programs` holds only the inline blit (shaders are loaded from files by the backend; passes still
# reference program names). All structural output is determined by the JSON passes/textures/globals.
extends RefCounted

const PaletteExpansion := preload("res://addons/noisemaker/compiler/graph/palette_expansion.gd")

const BLIT_FRAGMENT := """#version 300 es
            precision highp float;
            in vec2 v_texCoord;
            uniform sampler2D src;
            out vec4 fragColor;
            void main() {
                fragColor = texture(src, v_texCoord);
            }"""

const BLIT_WGSL := """
            struct FragmentInput {
                @builtin(position) position: vec4<f32>,
                @location(0) uv: vec2<f32>,
            }

            @group(0) @binding(0) var src: texture_2d<f32>;
            @group(0) @binding(1) var srcSampler: sampler;

            @fragment
            fn main(in: FragmentInput) -> @location(0) vec4<f32> {
                let uv = vec2<f32>(in.uv.x, 1.0 - in.uv.y);
                return textureSample(src, srcSampler, uv);
            }
        """

var reg
var _passes: Array
var _errors: Array
var _programs: Dictionary
var _texture_specs: Dictionary
var _texture_map: Dictionary
var _last_written_surface
var _enums_std: Dictionary
# per-plan scope context (read by the scope helpers)
var _cur_particle_pipeline_id
var _chain_scope_id: String

var _surface_ref_re: RegEx
var _particle_tex_re: RegEx

func _init(registry) -> void:
	reg = registry
	_surface_ref_re = RegEx.new()
	_surface_ref_re.compile("^(?:o|vol|geo|xyz|vel|rgba)[0-7]$")
	_particle_tex_re = RegEx.new()
	_particle_tex_re.compile("^global_(xyz|vel|rgba|points_trail|life_data)$")

# ---------------------------------------------------------------- helpers

func _register_passthrough(node_id: String, current_input, current_input3d, current_input_geo, current_input_xyz, current_input_vel, current_input_rgba) -> void:
	if current_input != null:
		_texture_map[node_id + "_out"] = current_input
	if current_input3d != null:
		_texture_map[node_id + "_out3d"] = current_input3d
	if current_input_geo != null:
		_texture_map[node_id + "_outGeo"] = current_input_geo
	if current_input_xyz != null:
		_texture_map[node_id + "_outXyz"] = current_input_xyz
	if current_input_vel != null:
		_texture_map[node_id + "_outVel"] = current_input_vel
	if current_input_rgba != null:
		_texture_map[node_id + "_outRgba"] = current_input_rgba

func _ensure_blit_program() -> void:
	if _programs.has("blit"):
		return
	_programs["blit"] = {"fragment": BLIT_FRAGMENT, "wgsl": BLIT_WGSL, "fragmentEntryPoint": "main"}

func _resolve_global_surface_ref(name: String) -> String:
	if name == "none":
		return "none"
	if name.begins_with("global_"):
		return name
	if _surface_ref_re.search(name) != null:
		return "global_" + name
	return name

# Resolve a dotted path against std enums only (reference expander resolveEnum).
func _resolve_enum(path: String):
	var parts := path.split(".")
	var node = _enums_std
	for part in parts:
		if node is Dictionary and node.has(part) and node[part] != null:
			node = node[part]
		else:
			return null
	if node is Dictionary and node.get("value") != null:
		return node["value"]
	return null

func _is_particle_tex(tex_name: String) -> bool:
	return _particle_tex_re.search(tex_name) != null

func _scope_particle_tex(tex_name: String) -> String:
	if _cur_particle_pipeline_id == null:
		return tex_name
	if _is_particle_tex(tex_name):
		return "%s_%s" % [tex_name, _cur_particle_pipeline_id]
	return tex_name

func _scope_chain_tex(tex_name: String) -> String:
	var particle_result := _scope_particle_tex(tex_name)
	if particle_result != tex_name:
		return particle_result
	if tex_name.begins_with("global_"):
		return "%s_%s" % [tex_name, _chain_scope_id]
	return tex_name

func _is_surface_arg(arg) -> bool:
	if not (arg is Dictionary):
		return false
	var k = arg.get("kind")
	return k == "temp" or k == "output" or k == "source" or k == "feedback" or k == "xyz" or k == "vel" or k == "rgba"

func _dim_references_param(dim) -> bool:
	return dim is Dictionary and (dim.has("param") or dim.has("screenDivide"))

# Format a value for a program-name suffix the way JS String() does: integer-valued floats lose the
# decimal (3.0 -> "3"), so the GDScript-float define values match the reference's program names.
func _js_num(v) -> String:
	if v is float and is_finite(v) and v == floor(v):
		return str(int(v))
	return str(v)

# ---------------------------------------------------------------- main

func expand(compilation_result: Dictionary, options: Dictionary = {}) -> Dictionary:
	var shader_overrides: Dictionary = options.get("shaderOverrides", {})
	_passes = []
	_errors = []
	_programs = {}
	_texture_specs = {}
	_texture_map = {}
	_last_written_surface = null
	_enums_std = reg.enums.std()

	var plans: Array = compilation_result.get("plans", [])
	for plan_index in range(plans.size()):
		var plan = plans[plan_index]
		var current_input = null
		var current_input3d = null
		var current_input_geo = null
		var current_input_xyz = null
		var current_input_vel = null
		var current_input_rgba = null
		var last_inline_write_target = null
		_cur_particle_pipeline_id = null
		var pipeline_uniforms := {}
		_chain_scope_id = "chain_%d" % plan_index

		for step in plan.get("chain", []):
			var step_args = step.get("args", {})
			var is_builtin = step.get("builtin") == true
			var op = step.get("op")

			if is_builtin and op == "_read":
				var tex = step_args.get("tex")
				if tex is Dictionary and tex.get("kind") == "output":
					current_input = "global_" + tex["name"]
				var node_id := "node_%s" % step["temp"]
				_texture_map[node_id + "_out"] = current_input
				continue
			if is_builtin and op == "_read3d":
				var tex3d = step_args.get("tex3d")
				var geo = step_args.get("geo")
				if tex3d != null:
					if tex3d.get("kind") == "vol" or tex3d.get("type") == "VolRef":
						current_input3d = "global_" + tex3d["name"]
					else:
						current_input3d = tex3d.get("name") if tex3d.get("name") else tex3d
				if geo != null:
					if geo.get("kind") == "geo" or geo.get("type") == "GeoRef":
						current_input_geo = "global_" + geo["name"]
					else:
						current_input_geo = geo.get("name") if geo.get("name") else geo
				var node_id := "node_%s" % step["temp"]
				if current_input3d != null:
					_texture_map[node_id + "_out3d"] = current_input3d
				if current_input_geo != null:
					_texture_map[node_id + "_outGeo"] = current_input_geo
				continue
			if is_builtin and op == "_write":
				var tex = step_args.get("tex")
				if tex is Dictionary and current_input != null:
					if tex.get("name") != "none":
						var target_surface = "global_" + tex["name"]
						if current_input != target_surface:
							var node_id := "node_%s" % step["temp"]
							_passes.push_back({
								"id": node_id + "_write_blit", "program": "blit", "type": "render",
								"inputs": {"src": current_input}, "outputs": {"color": target_surface},
								"uniforms": {}, "nodeId": node_id, "stepIndex": step["temp"],
							})
							_ensure_blit_program()
							_last_written_surface = tex["name"]
							last_inline_write_target = {"kind": tex.get("kind"), "name": tex["name"]}
					var node_id2 := "node_%s" % step["temp"]
					_texture_map[node_id2 + "_out"] = current_input
				continue
			if is_builtin and op == "_write3d":
				var tex3d = step_args.get("tex3d")
				var geo = step_args.get("geo")
				var node_id := "node_%s" % step["temp"]
				if tex3d is Dictionary and tex3d.get("name") != "none" and current_input3d != null:
					var target_vol = "global_" + tex3d["name"]
					if current_input3d != target_vol:
						_passes.push_back({
							"id": node_id + "_write3d_vol_blit", "program": "blit", "type": "render",
							"inputs": {"src": current_input3d}, "outputs": {"color": target_vol},
							"uniforms": {}, "nodeId": node_id, "stepIndex": step["temp"],
						})
						_ensure_blit_program()
				if geo is Dictionary and geo.get("name") != "none" and current_input_geo != null:
					var target_geo = "global_" + geo["name"]
					if current_input_geo != target_geo:
						_passes.push_back({
							"id": node_id + "_write3d_geo_blit", "program": "blit", "type": "render",
							"inputs": {"src": current_input_geo}, "outputs": {"color": target_geo},
							"uniforms": {}, "nodeId": node_id, "stepIndex": step["temp"],
						})
				_texture_map[node_id + "_out"] = current_input
				_texture_map[node_id + "_out3d"] = current_input3d
				_texture_map[node_id + "_outGeo"] = current_input_geo
				continue
			if is_builtin and op == "_subchain_begin":
				_register_passthrough("node_%s" % step["temp"], current_input, current_input3d, current_input_geo, current_input_xyz, current_input_vel, current_input_rgba)
				continue
			if is_builtin and op == "_subchain_end":
				_register_passthrough("node_%s" % step["temp"], current_input, current_input3d, current_input_geo, current_input_xyz, current_input_vel, current_input_rgba)
				continue

			last_inline_write_target = null

			if step_args is Dictionary and step_args.get("_skip") == true:
				_register_passthrough("node_%s" % step["temp"], current_input, current_input3d, current_input_geo, current_input_xyz, current_input_vel, current_input_rgba)
				continue

			var effect_name = op
			var effect_def = reg.get_effect(effect_name)
			if effect_def == null:
				_errors.push_back({"message": "Effect '%s' not found" % effect_name, "step": step})
				continue

			var node_id := "node_%s" % step["temp"]
			var scoped_param_map := {}
			var globals = effect_def.get("globals", {})
			var textures = effect_def.get("textures")

			var creates_particle_textures = textures is Dictionary and textures.has("global_xyz")
			if creates_particle_textures:
				_cur_particle_pipeline_id = node_id
				current_input_xyz = null
				current_input_vel = null
				current_input_rgba = null

			# compile-time defines
			var compile_time_defines := {}
			if globals is Dictionary:
				var sorted_names = globals.keys()
				sorted_names.sort()
				for gname in sorted_names:
					var gdef = globals[gname]
					if not (gdef is Dictionary) or not gdef.get("define"):
						continue
					var value = gdef.get("default")
					if step_args is Dictionary and step_args.has(gname):
						var arg_val = step_args[gname]
						value = arg_val["value"] if (arg_val is Dictionary and arg_val.has("value")) else arg_val
					if gdef.get("type") == "member" and value is String:
						var resolved = _resolve_enum(value)
						if resolved != null:
							value = resolved
					if value != null:
						compile_time_defines[gdef["define"]] = value
			var program_define_suffix := ""
			for k in compile_time_defines:
				program_define_suffix += "__%s_%s" % [k, _js_num(compile_time_defines[k])]

			# program collection (skipped for JSON defs without shaders)
			var step_overrides = shader_overrides.get(step["temp"])
			var shaders_source = step_overrides if step_overrides != null else effect_def.get("shaders")
			if shaders_source is Dictionary:
				for prog_name in shaders_source:
					var unique_prog_name := "%s_%s%s" % [node_id, prog_name, program_define_suffix]
					if not _programs.has(unique_prog_name):
						var layouts = effect_def.get("uniformLayouts")
						var program_layout = layouts.get(prog_name) if (layouts is Dictionary and layouts.has(prog_name)) else effect_def.get("uniformLayout")
						var prog = shaders_source[prog_name].duplicate(true) if shaders_source[prog_name] is Dictionary else {}
						prog["uniformLayout"] = program_layout
						prog["defines"] = compile_time_defines.duplicate(true)
						_programs[unique_prog_name] = prog

			# texture specs
			if textures is Dictionary:
				for tex_name in textures:
					var spec = textures[tex_name]
					var virtual_tex_id
					var is_particle = _is_particle_tex(tex_name)
					var should_scope_particle = is_particle and _cur_particle_pipeline_id != null
					if tex_name.begins_with("global_"):
						if should_scope_particle:
							virtual_tex_id = "%s_%s" % [tex_name, _cur_particle_pipeline_id]
						else:
							virtual_tex_id = "%s_%s" % [tex_name, _chain_scope_id]
					else:
						virtual_tex_id = "%s_%s" % [node_id, tex_name]
					var should_scope_chain = tex_name.begins_with("global_") and not is_particle
					var has_param_ref = _dim_references_param(spec.get("width")) or _dim_references_param(spec.get("height"))
					var resolved_spec = spec.duplicate(true) if spec is Dictionary else spec
					var should_scope_params = should_scope_particle or should_scope_chain or (_cur_particle_pipeline_id != null and not tex_name.begins_with("global_")) or has_param_ref
					if should_scope_params:
						var scope_suffix = _cur_particle_pipeline_id if should_scope_particle else _chain_scope_id
						resolved_spec["width"] = _scope_dim_spec(spec.get("width"), scope_suffix, scoped_param_map)
						resolved_spec["height"] = _scope_dim_spec(spec.get("height"), scope_suffix, scoped_param_map)
					_texture_specs[virtual_tex_id] = resolved_spec

			var textures3d = effect_def.get("textures3d")
			if textures3d is Dictionary:
				for tex_name in textures3d:
					var spec = textures3d[tex_name]
					var virtual_tex_id
					if tex_name.begins_with("global_"):
						virtual_tex_id = _scope_chain_tex(tex_name)
					else:
						virtual_tex_id = "%s_%s" % [node_id, tex_name]
					var s = spec.duplicate(true) if spec is Dictionary else {}
					s["is3D"] = true
					_texture_specs[virtual_tex_id] = s

			# resolve input from previous node
			if step.get("from") != null:
				var prev_node_id := "node_%s" % step["from"]
				current_input = _texture_map.get(prev_node_id + "_out")

			# process globals -> pipeline_uniforms (defaults, not overwriting upstream)
			if globals is Dictionary:
				for gname in globals:
					var gdef = globals[gname]
					if not (gdef is Dictionary):
						continue
					if gdef.get("uniform") and gdef.get("default") != null:
						if pipeline_uniforms.get(gdef["uniform"]) == null:
							var val = gdef["default"]
							if gdef.get("type") == "member" and val is String:
								var resolved = _resolve_enum(val)
								if resolved != null:
									val = resolved
							pipeline_uniforms[gdef["uniform"]] = val
					if gdef.get("type") == "surface" and gdef.get("colorModeUniform"):
						if not (step_args is Dictionary and step_args.has(gname)):
							var is_none = gdef.get("default") == "none"
							pipeline_uniforms[gdef["colorModeUniform"]] = 0 if is_none else 1

			# FIRST PASS: surface args populate colorModeControlledUniforms
			var color_mode_controlled := {}
			if step_args is Dictionary:
				for arg_name in step_args:
					var arg = step_args[arg_name]
					if _is_surface_arg(arg):
						var global_def = globals.get(arg_name) if globals is Dictionary else null
						if global_def is Dictionary and global_def.get("colorModeUniform"):
							var is_none = arg.get("name") == "none"
							pipeline_uniforms[global_def["colorModeUniform"]] = 0 if is_none else 1
							color_mode_controlled[global_def["colorModeUniform"]] = true

			# SECOND PASS: non-surface args
			if step_args is Dictionary:
				for arg_name in step_args:
					var arg = step_args[arg_name]
					if _is_surface_arg(arg):
						continue
					var uniform_name = arg_name
					if globals is Dictionary and globals.has(arg_name) and globals[arg_name] is Dictionary and globals[arg_name].get("uniform"):
						uniform_name = globals[arg_name]["uniform"]
					if color_mode_controlled.has(uniform_name):
						continue
					if uniform_name == "volumeSize" and current_input3d != null and pipeline_uniforms.get("volumeSize") != null:
						continue
					var resolved_value
					if arg is Dictionary and arg.has("value"):
						resolved_value = arg["value"]
					else:
						resolved_value = arg
					pipeline_uniforms[uniform_name] = resolved_value

			# expand passes
			var effect_passes = effect_def.get("passes", [])
			for i in range(effect_passes.size()):
				var pass_def = effect_passes[i]
				var pass_id := "%s_pass_%d" % [node_id, i]
				var program_name := "%s_%s%s" % [node_id, pass_def.get("program"), program_define_suffix]
				var pass_obj := {"id": pass_id, "program": program_name, "inputs": {}, "outputs": {}, "uniforms": {}}
				# Optional pass fields: include only when the passDef provides them (the reference's
				# object literal sets them to undefined otherwise, which JSON.stringify drops).
				for opt_key in ["entryPoint", "drawMode", "drawBuffers", "count", "countUniform", "repeat", "blend", "workgroups", "storageBuffers", "storageTextures"]:
					if pass_def is Dictionary and pass_def.has(opt_key):
						pass_obj[opt_key] = pass_def[opt_key]
				pass_obj["effectKey"] = effect_name
				pass_obj["effectFunc"] = effect_def.get("func") if effect_def.get("func") else effect_name
				pass_obj["effectNamespace"] = effect_def.get("namespace")
				pass_obj["nodeId"] = node_id
				pass_obj["stepIndex"] = step["temp"]
				if current_input3d != null and pipeline_uniforms.get("volumeSize") != null:
					pass_obj["inheritsVolumeSize"] = true

				pass_obj["uniforms"] = pipeline_uniforms.duplicate(true)

				if globals is Dictionary:
					for gdef in globals.values():
						if gdef is Dictionary and gdef.get("uniform") and gdef.get("default") != null:
							if pass_obj["uniforms"].get(gdef["uniform"]) != null:
								continue
							var val = gdef["default"]
							if gdef.get("type") == "member" and val is String:
								var resolved = _resolve_enum(val)
								if resolved != null:
									val = resolved
							pass_obj["uniforms"][gdef["uniform"]] = val
							pipeline_uniforms[gdef["uniform"]] = val

				if globals is Dictionary:
					pass_obj["uniformSpecs"] = {}
					for arg_name in globals:
						var gdef = globals[arg_name]
						if not (gdef is Dictionary):
							continue
						var uniform_name = gdef.get("uniform") if gdef.get("uniform") else arg_name
						if (gdef.get("type") == "float" or gdef.get("type") == "int") and not gdef.get("choices"):
							pass_obj["uniformSpecs"][uniform_name] = {
								"min": gdef.get("min") if gdef.get("min") != null else 0,
								"max": gdef.get("max") if gdef.get("max") != null else 100,
							}

				# map uniforms from step.args
				if step_args is Dictionary:
					for arg_name in step_args:
						var arg = step_args[arg_name]
						if _is_surface_arg(arg):
							continue
						var uniform_name = arg_name
						if globals is Dictionary and globals.has(arg_name) and globals[arg_name] is Dictionary and globals[arg_name].get("uniform"):
							uniform_name = globals[arg_name]["uniform"]
						if globals is Dictionary:
							var is_controlled := false
							for gdef in globals.values():
								if gdef is Dictionary and gdef.get("colorModeUniform") == uniform_name:
									is_controlled = true
									break
							if is_controlled:
								continue
						if uniform_name == "volumeSize" and current_input3d != null and pipeline_uniforms.get("volumeSize") != null:
							continue
						var resolved_value
						if arg is Dictionary and arg.has("value"):
							resolved_value = arg["value"]
						else:
							resolved_value = arg
						pass_obj["uniforms"][uniform_name] = resolved_value
						pipeline_uniforms[uniform_name] = resolved_value

				# pass-level uniforms from effect def
				var pdef_uniforms = pass_def.get("uniforms")
				if pdef_uniforms is Dictionary:
					for uniform_name in pdef_uniforms:
						var global_ref = pdef_uniforms[uniform_name]
						if pipeline_uniforms.get(uniform_name) != null:
							pass_obj["uniforms"][uniform_name] = pipeline_uniforms[uniform_name]
						elif pipeline_uniforms.get(global_ref) != null:
							pass_obj["uniforms"][uniform_name] = pipeline_uniforms[global_ref]
						elif globals is Dictionary and globals.has(global_ref):
							var global_def = globals[global_ref]
							if global_def is Dictionary and global_def.get("default") != null:
								var val = global_def["default"]
								if global_def.get("type") == "member" and val is String:
									var resolved = _resolve_enum(val)
									if resolved != null:
										val = resolved
								pass_obj["uniforms"][uniform_name] = val

				# palette expansion
				if globals is Dictionary:
					for arg_name in globals:
						var global_def = globals[arg_name]
						if not (global_def is Dictionary) or global_def.get("type") != "palette":
							continue
						var uniform_name = global_def.get("uniform") if global_def.get("uniform") else arg_name
						var index = pass_obj["uniforms"].get(uniform_name)
						if not (index is float or index is int):
							continue
						var expanded = PaletteExpansion.expand_palette(index)
						if expanded == null:
							continue
						for u_name in expanded:
							if pass_obj["uniforms"].has(u_name):
								var u_value = expanded[u_name]
								pass_obj["uniforms"][u_name] = u_value.duplicate() if u_value is Array else u_value
								pipeline_uniforms[u_name] = pass_obj["uniforms"][u_name]

				# map inputs
				var pdef_inputs = pass_def.get("inputs")
				if pdef_inputs is Dictionary:
					for uniform_name in pdef_inputs:
						_map_input(pass_obj, uniform_name, pdef_inputs[uniform_name], current_input, current_input3d, current_input_geo, current_input_xyz, current_input_vel, current_input_rgba, effect_def, step, step_args, node_id, plan)

				# map outputs
				var pdef_outputs = pass_def.get("outputs")
				if pdef_outputs is Dictionary:
					var is_last_step = step == plan["chain"][plan["chain"].size() - 1]
					var is_last_pass = i == effect_passes.size() - 1
					for attachment in pdef_outputs:
						_map_output(pass_obj, attachment, pdef_outputs[attachment], current_input3d, current_input_geo, current_input_xyz, current_input_vel, current_input_rgba, node_id, plan, is_last_step, is_last_pass)
						# _map_output may update _last_written_surface

				# propagate scoped param uniforms
				for original_param in scoped_param_map:
					var scoped_param = scoped_param_map[original_param]
					if pass_obj["uniforms"].get(original_param) != null:
						pass_obj["uniforms"][scoped_param] = pass_obj["uniforms"][original_param]
						pipeline_uniforms[scoped_param] = pass_obj["uniforms"][original_param]
				if scoped_param_map.size() > 0:
					pass_obj["scopedParams"] = scoped_param_map.duplicate(true)

				_passes.push_back(pass_obj)

			# update currentInput for next step
			current_input = _texture_map.get(node_id + "_out")

			# explicit outputTex passthrough
			if effect_def.get("outputTex") and current_input == null:
				var internal_tex_name = effect_def["outputTex"]
				if internal_tex_name == "inputTex":
					if step.get("from") != null:
						var prev_node_id := "node_%s" % step["from"]
						var prev_output = _texture_map.get(prev_node_id + "_out")
						if prev_output != null:
							_texture_map[node_id + "_out"] = prev_output
							current_input = prev_output
				else:
					var virtual_tex_id = _scope_chain_tex(internal_tex_name) if internal_tex_name.begins_with("global_") else "%s_%s" % [node_id, internal_tex_name]
					_texture_map[node_id + "_out"] = virtual_tex_id
					current_input = virtual_tex_id

			var out3d = _texture_map.get(node_id + "_out3d")
			if out3d != null:
				current_input3d = out3d
			var out_xyz = _texture_map.get(node_id + "_outXyz")
			if out_xyz != null:
				current_input_xyz = out_xyz
			var out_vel = _texture_map.get(node_id + "_outVel")
			if out_vel != null:
				current_input_vel = out_vel
			var out_rgba = _texture_map.get(node_id + "_outRgba")
			if out_rgba != null:
				current_input_rgba = out_rgba

			# explicit outputTex3d
			if effect_def.get("outputTex3d") and out3d == null:
				var internal_tex_name = effect_def["outputTex3d"]
				if internal_tex_name == "inputTex3d":
					if current_input3d != null:
						_texture_map[node_id + "_out3d"] = current_input3d
				else:
					var virtual_tex_id = _scope_chain_tex(internal_tex_name) if internal_tex_name.begins_with("global_") else "%s_%s" % [node_id, internal_tex_name]
					_texture_map[node_id + "_out3d"] = virtual_tex_id
					current_input3d = virtual_tex_id

			if effect_def.get("outputGeo"):
				var geo_tex_name = effect_def["outputGeo"]
				if geo_tex_name == "inputGeo":
					if current_input_geo != null:
						_texture_map[node_id + "_outGeo"] = current_input_geo
				else:
					var virtual_geo_id := "%s_%s" % [node_id, geo_tex_name]
					_texture_map[node_id + "_outGeo"] = virtual_geo_id
					current_input_geo = virtual_geo_id

			if effect_def.get("outputXyz") and out_xyz == null:
				current_input_xyz = _output_state_tex(effect_def["outputXyz"], "inputXyz", current_input_xyz, node_id, "_outXyz")
			if effect_def.get("outputVel") and out_vel == null:
				current_input_vel = _output_state_tex(effect_def["outputVel"], "inputVel", current_input_vel, node_id, "_outVel")
			if effect_def.get("outputRgba") and out_rgba == null:
				current_input_rgba = _output_state_tex(effect_def["outputRgba"], "inputRgba", current_input_rgba, node_id, "_outRgba")

		# final chain output (.write)
		if plan.get("write") != null and current_input != null:
			var pw = plan["write"]
			var out_name = pw["name"] if pw is Dictionary else pw
			_last_written_surface = out_name
			var already_written = last_inline_write_target != null and last_inline_write_target.get("kind") == "output" and last_inline_write_target.get("name") == out_name
			if not already_written:
				var target_surface = "global_" + out_name
				if current_input != target_surface:
					_passes.push_back({
						"id": "final_blit_" + out_name, "program": "blit", "type": "render",
						"inputs": {"src": current_input}, "outputs": {"color": target_surface}, "uniforms": {},
					})

	var render_surface
	if compilation_result.get("render") != null:
		render_surface = compilation_result["render"]
	elif _last_written_surface != null:
		render_surface = _last_written_surface
	else:
		_errors.push_back({"message": "No render surface specified and no write() found - add render(oN) or write(oN)"})
		render_surface = null

	return {"passes": _passes, "errors": _errors, "programs": _programs, "textureSpecs": _texture_specs, "renderSurface": render_surface}

# Scope a dimension spec's param reference to this pipeline/chain (tracks the mapping).
func _scope_dim_spec(dim_spec, scope_suffix, scoped_param_map: Dictionary):
	if dim_spec is Dictionary and dim_spec.has("param"):
		var original_param = dim_spec["param"]
		var scoped_param = "%s_%s" % [original_param, scope_suffix]
		scoped_param_map[original_param] = scoped_param
		var d = dim_spec.duplicate(true)
		d["param"] = scoped_param
		return d
	if dim_spec is Dictionary and dim_spec.has("screenDivide"):
		var original_param = dim_spec["screenDivide"]
		var scoped_param = "%s_%s" % [original_param, scope_suffix]
		scoped_param_map[original_param] = scoped_param
		var d = dim_spec.duplicate(true)
		d["screenDivide"] = scoped_param
		return d
	return dim_spec

func _output_state_tex(tex_name, input_name: String, current, node_id: String, out_key: String):
	if tex_name == input_name:
		if current != null:
			_texture_map[node_id + out_key] = current
		return current
	var virtual_id = _scope_chain_tex(tex_name) if tex_name.begins_with("global_") else "%s_%s" % [node_id, tex_name]
	_texture_map[node_id + out_key] = virtual_id
	return virtual_id

func _map_input(pass_obj: Dictionary, uniform_name, tex_ref, current_input, current_input3d, current_input_geo, current_input_xyz, current_input_vel, current_input_rgba, effect_def: Dictionary, step: Dictionary, step_args, node_id: String, plan: Dictionary) -> void:
	var is_pipeline_input = tex_ref == "inputTex" or (tex_ref is String and tex_ref.begins_with("o") and tex_ref.substr(1).is_valid_int())
	if is_pipeline_input:
		pass_obj["inputs"][uniform_name] = current_input if current_input != null else tex_ref
	elif tex_ref == "inputTex3d":
		pass_obj["inputs"][uniform_name] = current_input3d if current_input3d != null else tex_ref
	elif tex_ref == "inputGeo":
		pass_obj["inputs"][uniform_name] = current_input_geo if current_input_geo != null else tex_ref
	elif tex_ref == "inputXyz":
		pass_obj["inputs"][uniform_name] = current_input_xyz if current_input_xyz != null else tex_ref
	elif tex_ref == "inputVel":
		pass_obj["inputs"][uniform_name] = current_input_vel if current_input_vel != null else tex_ref
	elif tex_ref == "inputRgba":
		pass_obj["inputs"][uniform_name] = current_input_rgba if current_input_rgba != null else tex_ref
	elif tex_ref == "noise":
		pass_obj["inputs"][uniform_name] = "global_noise"
	elif tex_ref == "midiNoteGrid":
		pass_obj["inputs"][uniform_name] = "midiNoteGrid"
	elif tex_ref == "feedback" or tex_ref == "selfTex":
		if plan.get("write") != null:
			var pw = plan["write"]
			var out_name = pw["name"] if pw is Dictionary else pw
			var out_kind = pw.get("kind") if (pw is Dictionary and pw.get("kind")) else "output"
			var prefix = "feedback" if out_kind == "feedback" else "global"
			pass_obj["inputs"][uniform_name] = "%s_%s" % [prefix, out_name]
		else:
			pass_obj["inputs"][uniform_name] = current_input if current_input != null else "global_inputTex"
	elif effect_def.get("externalTexture") and tex_ref == effect_def.get("externalTexture"):
		pass_obj["inputs"][uniform_name] = "%s_step_%s" % [tex_ref, step["temp"]]
	elif step_args is Dictionary and step_args.has(tex_ref):
		var arg = step_args[tex_ref]
		if arg == null:
			return
		var ak = arg.get("kind") if arg is Dictionary else null
		if ak == "temp":
			pass_obj["inputs"][uniform_name] = _texture_map.get("node_%s_out" % arg["index"])
		elif ak == "output" or ak == "source" or ak == "vol" or ak == "geo" or ak == "xyz" or ak == "vel" or ak == "rgba":
			pass_obj["inputs"][uniform_name] = "none" if arg.get("name") == "none" else "global_" + arg["name"]
		elif arg is String:
			pass_obj["inputs"][uniform_name] = _resolve_global_surface_ref(arg)
	elif _global_default(effect_def, tex_ref) != null:
		var default_val = _global_default(effect_def, tex_ref)
		if default_val == "none":
			pass_obj["inputs"][uniform_name] = "none"
		elif default_val == "inputTex" or default_val == "inputColor":
			pass_obj["inputs"][uniform_name] = current_input if current_input != null else default_val
		elif default_val is String and _surface_ref_re.search(default_val) != null:
			pass_obj["inputs"][uniform_name] = "global_" + default_val
		elif default_val is String and default_val.begins_with("global_"):
			pass_obj["inputs"][uniform_name] = _scope_chain_tex(default_val)
		else:
			pass_obj["inputs"][uniform_name] = default_val
	elif tex_ref is String and tex_ref.begins_with("global_"):
		pass_obj["inputs"][uniform_name] = _scope_chain_tex(tex_ref)
	elif tex_ref == "outputTex":
		pass_obj["inputs"][uniform_name] = node_id + "_out"
	else:
		pass_obj["inputs"][uniform_name] = "%s_%s" % [node_id, tex_ref]

func _global_default(effect_def: Dictionary, name):
	var globals = effect_def.get("globals")
	if globals is Dictionary and globals.has(name) and globals[name] is Dictionary and globals[name].get("default") != null:
		return globals[name]["default"]
	return null

func _map_output(pass_obj: Dictionary, attachment, tex_ref, current_input3d, current_input_geo, current_input_xyz, current_input_vel, current_input_rgba, node_id: String, plan: Dictionary, is_last_step: bool, is_last_pass: bool) -> void:
	var virtual_tex
	if tex_ref == "outputTex":
		if is_last_step and is_last_pass and plan.get("write") != null:
			var pw = plan["write"]
			var out_name = pw["name"] if pw is Dictionary else pw
			var out_kind = pw.get("kind") if (pw is Dictionary and pw.get("kind")) else "output"
			var prefix = "feedback" if out_kind == "feedback" else "global"
			virtual_tex = "%s_%s" % [prefix, out_name]
			_last_written_surface = out_name
		else:
			virtual_tex = node_id + "_out"
		_texture_map[virtual_tex] = virtual_tex
		_texture_map[node_id + "_out"] = virtual_tex
	elif tex_ref == "outputTex3d":
		virtual_tex = node_id + "_out3d"
		_texture_map[node_id + "_out3d"] = virtual_tex
	elif tex_ref == "outputXyz":
		virtual_tex = node_id + "_outXyz"
		_texture_map[node_id + "_outXyz"] = virtual_tex
	elif tex_ref == "outputVel":
		virtual_tex = node_id + "_outVel"
		_texture_map[node_id + "_outVel"] = virtual_tex
	elif tex_ref == "outputRgba":
		virtual_tex = node_id + "_outRgba"
		_texture_map[node_id + "_outRgba"] = virtual_tex
	elif tex_ref == "inputTex3d":
		virtual_tex = current_input3d if current_input3d != null else node_id + "_inputTex3d"
	elif tex_ref == "inputGeo":
		virtual_tex = current_input_geo if current_input_geo != null else node_id + "_inputGeo"
	elif tex_ref == "inputXyz":
		virtual_tex = current_input_xyz if current_input_xyz != null else node_id + "_inputXyz"
	elif tex_ref == "inputVel":
		virtual_tex = current_input_vel if current_input_vel != null else node_id + "_inputVel"
	elif tex_ref == "inputRgba":
		virtual_tex = current_input_rgba if current_input_rgba != null else node_id + "_inputRgba"
	elif tex_ref is String and tex_ref.begins_with("global_"):
		virtual_tex = _scope_chain_tex(tex_ref)
	elif tex_ref is String and tex_ref.begins_with("feedback_"):
		virtual_tex = tex_ref
	else:
		virtual_tex = "%s_%s" % [node_id, tex_ref]
	pass_obj["outputs"][attachment] = virtual_tex
