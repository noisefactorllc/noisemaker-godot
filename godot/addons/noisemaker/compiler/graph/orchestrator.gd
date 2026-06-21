# orchestrator.gd — ties the compiler pipeline into a normalized render graph. Port of the REFERENCE
# shaders/src/runtime/compiler.js compileGraph() + tools/export-graph.mjs normalizeGraph() (the shape
# the backend loader consumes, docs/GRAPH-JSON-SCHEMA.md). Sources: upstream noisemaker +
# noisemaker-hlsl ONLY.
#
# build_graph(source, options) runs lex -> parse -> validate -> expand -> allocate_resources, wraps
# the result (id=hashSource, source, passes, programs, allocations, textures, renderSurface), then
# normalizes each pass to {passType, namespace, func, progName, defines, ...} and promotes
# compile-time-define globals out of uniforms into defines (by their DEFINE name).
#
# Instance-owned, constructed with an EffectRegistry (threaded to validator/expander + provides the
# define map). The whole pipeline is in-engine — no reference dependency at runtime.
extends RefCounted

const Lexer := preload("res://addons/noisemaker/compiler/lang/lexer.gd")
const Parser := preload("res://addons/noisemaker/compiler/lang/parser.gd")
const Validator := preload("res://addons/noisemaker/compiler/lang/validator.gd")
const Expander := preload("res://addons/noisemaker/compiler/graph/expander.gd")
const Resources := preload("res://addons/noisemaker/compiler/graph/resources.gd")

var reg

func _init(registry) -> void:
	reg = registry

# Compile DSL source into the normalized render graph.
func build_graph(source: String, options: Dictionary = {}) -> Dictionary:
	var tokens := Lexer.lex(source)
	var ast = Parser.new().parse_tokens(tokens)
	var validated = Validator.new(reg).validate(ast)
	var expanded = Expander.new(reg).expand(validated, options)
	var passes: Array = expanded["passes"]
	var programs: Dictionary = expanded["programs"]
	var allocations := Resources.allocate_resources(passes)
	var textures := _extract_texture_specs(passes, expanded["textureSpecs"])
	var graph := {
		"id": _hash_source(source),
		"source": source,
		"passes": passes,
		"programs": programs,
		"allocations": allocations,
		"textures": textures,
		"renderSurface": expanded["renderSurface"],
	}
	return _normalize_graph(graph)

# ---------------------------------------------------------------- texture specs (compiler.js)

func _extract_texture_specs(passes: Array, texture_specs: Dictionary) -> Dictionary:
	var textures := {}
	for tex_id in texture_specs:
		var effect_spec = texture_specs[tex_id]
		var spec := {
			"width": effect_spec.get("width") if effect_spec.get("width") != null else "screen",
			"height": effect_spec.get("height") if effect_spec.get("height") != null else "screen",
			"format": effect_spec.get("format") if effect_spec.get("format") != null else "rgba16f",
			"usage": ["render", "sample", "copySrc", "copyDst"],
		}
		if effect_spec.get("is3D"):
			var depth = effect_spec.get("depth")
			if depth == null:
				depth = effect_spec.get("width") if effect_spec.get("width") != null else 64
			spec["depth"] = depth
			spec["is3D"] = true
			spec["usage"] = ["storage", "sample", "copySrc", "copyDst"]
		textures[tex_id] = spec
	for p in passes:
		var outputs = p.get("outputs")
		if outputs is Dictionary:
			for tex_id in outputs.values():
				if tex_id is String and tex_id.begins_with("global_"):
					continue
				if textures.has(tex_id):
					continue
				textures[tex_id] = {"width": "screen", "height": "screen", "format": "rgba16f", "usage": ["render", "sample", "copySrc", "copyDst"]}
	return textures

# ---------------------------------------------------------------- source hash (compiler.js)

# 32-bit signed hash -> base36 string, matching JS ((h<<5)-h)+c with `& h` ToInt32 each step.
func _hash_source(source: String) -> String:
	var hash := 0
	for i in range(source.length()):
		var ch := source.unicode_at(i)
		var shifted := _to_int32(hash << 5)
		hash = (shifted - hash) + ch
		hash = _to_int32(hash)
	return _to_base36(hash)

func _to_int32(x: int) -> int:
	x = x & 0xFFFFFFFF
	if x >= 0x80000000:
		x -= 0x100000000
	return x

func _to_base36(n: int) -> String:
	if n == 0:
		return "0"
	var neg := n < 0
	var x := abs(n)
	const DIGITS := "0123456789abcdefghijklmnopqrstuvwxyz"
	var s := ""
	while x > 0:
		s = DIGITS[x % 36] + s
		x = x / 36
	return ("-" + s) if neg else s

# ---------------------------------------------------------------- normalization (export-graph.mjs)

func _normalize_graph(graph: Dictionary) -> Dictionary:
	var programs: Dictionary = graph.get("programs", {})
	var define_map: Dictionary = reg.define_map()
	var norm_passes: Array = []
	for p in graph.get("passes", []):
		norm_passes.push_back(_normalize_pass(p, programs, define_map))
	return {
		"id": graph["id"],
		"source": graph["source"],
		"renderSurface": graph.get("renderSurface"),
		"passes": norm_passes,
		"allocations": graph.get("allocations", {}),
		"textures": graph.get("textures", {}),
		"programs": _normalize_programs(programs),
	}

func _derive_prog_name(p: Dictionary) -> String:
	var raw = p.get("program")
	var s: String = raw if raw is String else ""
	if p.get("nodeId"):
		var node_prefix := "%s_" % p["nodeId"]
		if s.begins_with(node_prefix):
			s = s.substr(node_prefix.length())
	var suffix_idx := s.find("__")
	if suffix_idx > 0:
		s = s.substr(0, suffix_idx)
	if s == "":
		s = p.get("effectFunc") if p.get("effectFunc") else "main"
	return s

func _defines_for_pass(p: Dictionary, programs: Dictionary) -> Dictionary:
	var prog = programs.get(p.get("program"))
	var d = prog.get("defines") if prog is Dictionary else null
	if not (d is Dictionary):
		return {}
	return d.duplicate(true)

func _normalize_pass(p: Dictionary, programs: Dictionary, define_map: Dictionary) -> Dictionary:
	var is_blit = p.get("type") == "blit" or p.get("program") == "blit" or p.get("effectFunc") == "blit"
	var out := {
		"id": p.get("id"),
		"passType": "blit" if is_blit else "effect",
		"namespace": null if is_blit else p.get("effectNamespace"),
		"func": "blit" if is_blit else p.get("effectFunc"),
		"progName": "blit" if is_blit else _derive_prog_name(p),
		"program": p.get("program"),
		"defines": {} if is_blit else _defines_for_pass(p, programs),
		"inputs": p.get("inputs", {}),
		"outputs": p.get("outputs", {}),
		"uniforms": (p.get("uniforms", {}) as Dictionary).duplicate(true),
		"uniformSpecs": p.get("uniformSpecs", {}),
	}

	# promote compile-time-define globals from uniforms into defines (by DEFINE name)
	if not is_blit:
		var dm = define_map.get("%s.%s" % [p.get("effectNamespace"), p.get("effectFunc")])
		if dm is Dictionary:
			for global_key in dm:
				var define_name = dm[global_key]
				if out["uniforms"].has(global_key):
					var v = out["uniforms"][global_key]
					out["defines"][define_name] = (1 if v else 0) if v is bool else int(v)
					out["uniforms"].erase(global_key)

	# optional execution modifiers (only when present)
	for opt_key in ["drawMode", "count", "countUniform", "drawBuffers", "blend", "repeat", "clear"]:
		if p.has(opt_key):
			out[opt_key] = p[opt_key]

	# metadata
	out["effectKey"] = p.get("effectKey")
	out["nodeId"] = p.get("nodeId")
	if p.has("stepIndex"):
		out["stepIndex"] = p["stepIndex"]
	if p.has("inheritsVolumeSize"):
		out["inheritsVolumeSize"] = p["inheritsVolumeSize"]
	out["scopedParams"] = p.get("scopedParams")
	return out

func _normalize_programs(programs: Dictionary) -> Dictionary:
	var out := {}
	for id in programs:
		var prog = programs[id]
		out[id] = {
			"uniformLayout": prog.get("uniformLayout", {}) if prog is Dictionary else {},
			"defines": prog.get("defines", {}) if prog is Dictionary else {},
		}
	return out
