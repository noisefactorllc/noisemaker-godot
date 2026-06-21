# effect_registry.gd — effect + op registry. Port of the REFERENCE load-time registration in
# renderer/canvas.js registerEffectWithRuntime() (with runtime/registry.js, lang/ops.js,
# lang/paramAliases.js, lang/effectAliases.js, lang/enums.js). Sources: upstream noisemaker +
# noisemaker-hlsl ONLY.
#
# For every effect definition JSON under res://addons/noisemaker/effects/<ns>/<func>.json this
# builds the same structures the reference canvas builds when it registers effects at load:
#
#   _effects  : lookup map. Each def registered under the reference's four keys —
#                   func | <ns>.<func> | <ns>/<func> | <ns>.<func>
#               (key 4 duplicates key 2; "<ns>/<func>" uses the effect dir name, which == func for
#               every effect in the catalog). Consumed by the expander via get_effect().
#   _ops      : op-spec map  "<ns>.<func>" -> {"name", "args":[...]}.  args is derived from `globals`
#               exactly as canvas.js does (vec4->color, choices->derived enumPath, enum passthrough,
#               undefined fields omitted). Consumed by the validator.
#   _param_aliases  : "<ns>.<func>" -> {oldParam:newParam}  (validator resolveParamAliases). Empty
#               alias maps are inert (the JS for-loop no-ops) and GDScript's empty Dictionary is
#               falsy, so — matching that behavior — only NON-EMPTY maps are recorded.
#   _effect_aliases : "<ns>.<func>" -> replacementName  for hidden+deprecatedBy effects
#               (validator checkEffectAlias deprecation warnings).
#   enums (owned Enums instance): effect `choices` registered as nested leaves
#               <ns>.<func>.<key>.<choice>, mirroring canvas's choicesToRegister + mergeIntoEnums.
#
# Instance-owned, no static state (the reference uses module globals; the live runtime builds ONE
# registry and threads it to the validator + expander). load_all() is idempotent per instance.
#
# PARITY NOTES:
#   - Bare op names (e.g. `noise()`) resolve in the validator via the program's namespace search
#     order against the OPS table (ops["<ns>.<func>"]), NOT via the bare-`func` effect key. So the
#     two bare-func collisions in the catalog (noise, noise3d) are cosmetic for the compile path;
#     the parity-critical surfaces are _ops and the enums choice tree, both keyed by <ns>.<func>.
#   - sanitizeEnumName never produces an alias on the current catalog (all 1750 non-colon choice
#     names are already valid identifiers); it is ported faithfully for completeness.
extends RefCounted

const Enums := preload("res://addons/noisemaker/compiler/lang/enums.gd")

const EFFECTS_DIR := "res://addons/noisemaker/effects"

var enums: Enums
var _effects: Dictionary        # lookup key -> effect def (Dictionary)
var _ops: Dictionary            # "<ns>.<func>" -> {name, args}
var _param_aliases: Dictionary  # "<ns>.<func>" -> {old:new}
var _effect_aliases: Dictionary # "<ns>.<func>" -> replacement name
var _loaded := false

func _init() -> void:
	enums = Enums.new()
	_effects = {}
	_ops = {}
	_param_aliases = {}
	_effect_aliases = {}

# ---------------------------------------------------------------- public lookups

# Effect definition lookup (the expander's getEffect). Returns the def Dictionary or null.
func get_effect(name: String):
	return _effects.get(name)

# Op-spec lookup (the validator's ops[name]). Returns {name, args} or null.
func get_op(name: String):
	return _ops.get(name)

func ops_table() -> Dictionary:
	return _ops

func param_aliases() -> Dictionary:
	return _param_aliases

func effect_aliases() -> Dictionary:
	return _effect_aliases

# Map every registered lookup key to its def's "<ns>.<func>" fingerprint (for parity inspection).
func effect_key_fingerprints() -> Dictionary:
	var out := {}
	for k in _effects:
		var d: Dictionary = _effects[k]
		out[k] = "%s.%s" % [d.get("namespace", ""), d.get("func", "")]
	return out

# ---------------------------------------------------------------- loading

# Load every effect JSON and register it. Idempotent per instance.
func load_all() -> void:
	if _loaded:
		return
	_loaded = true
	for rel in _list_effect_files():
		var def := _read_json(EFFECTS_DIR + "/" + rel)
		if def.is_empty():
			continue
		_register_effect(def)

# Sorted ["<ns>/<file>.json", ...] — deterministic registration order (the gate's oracle sorts the
# same way, so the two cosmetic bare-func collisions resolve identically on both sides).
func _list_effect_files() -> Array:
	var out: Array = []
	var nd := DirAccess.open(EFFECTS_DIR)
	if nd == null:
		push_error("EffectRegistry: cannot open " + EFFECTS_DIR)
		return out
	for ns in nd.get_directories():
		var sd := DirAccess.open(EFFECTS_DIR + "/" + ns)
		if sd == null:
			continue
		for fn in sd.get_files():
			if fn.ends_with(".json"):
				out.append(ns + "/" + fn)
	out.sort()
	return out

func _read_json(path: String) -> Dictionary:
	var txt := FileAccess.get_file_as_string(path)
	if txt.is_empty():
		return {}
	var parsed = JSON.parse_string(txt)
	return parsed if parsed is Dictionary else {}

# Mirror of renderer/canvas.js registerEffectWithRuntime().
func _register_effect(def: Dictionary) -> void:
	var ns: String = def.get("namespace", "")
	var fn: String = def.get("func", "")
	if fn == "":
		return
	# effect dir name == func for the whole catalog, so the "<ns>/<name>" key uses func.
	var effect_name := fn

	# four lookup keys (key 4 duplicates key 2; reference registers it redundantly).
	_effects[fn] = def
	_effects[ns + "." + fn] = def
	_effects[ns + "/" + effect_name] = def
	_effects[ns + "." + effect_name] = def

	# op-spec: args derived from globals -----------------------------------
	var globals = def.get("globals", {})
	var args: Array = []
	if globals is Dictionary:
		for key in globals:
			var spec = globals[key]
			if not (spec is Dictionary):
				continue
			# enumPath = spec.enum || spec.enumPath
			var enum_path = spec.get("enum")
			if enum_path == null or enum_path == "":
				enum_path = spec.get("enumPath")
			var choices = spec.get("choices")
			# derive enumPath from choices + register the choice leaves
			if choices != null and (enum_path == null or enum_path == ""):
				enum_path = "%s.%s.%s" % [ns, fn, key]
				for cname in choices:
					if cname.ends_with(":"):
						continue
					enums.register_choice([ns, fn, key, cname], choices[cname])
					var sanitized := sanitize_enum_name(cname)
					if sanitized != "" and sanitized != cname:
						enums.register_choice([ns, fn, key, sanitized], choices[cname])
			# build the arg, omitting JS-undefined fields (so it matches the oracle's
			# JSON.stringify, which drops undefined-valued keys).
			var arg := {"name": key}
			if spec.has("type"):
				arg["type"] = "color" if spec["type"] == "vec4" else spec["type"]
			if spec.has("default"):
				arg["default"] = spec["default"]
			if enum_path != null and enum_path != "":
				arg["enum"] = enum_path
				arg["enumPath"] = enum_path
			if spec.has("min"):
				arg["min"] = spec["min"]
			if spec.has("max"):
				arg["max"] = spec["max"]
			if spec.has("uniform"):
				arg["uniform"] = spec["uniform"]
			if choices != null:
				arg["choices"] = choices
			args.append(arg)
	_ops[ns + "." + fn] = {"name": fn, "args": args}

	# param aliases (non-empty only — empty maps are inert) ----------------
	var pa = def.get("paramAliases")
	if pa is Dictionary and not pa.is_empty():
		_param_aliases[ns + "." + fn] = pa

	# effect aliases (deprecation: hidden + deprecatedBy) ------------------
	if def.get("hidden") and def.has("deprecatedBy"):
		_effect_aliases[ns + "." + fn] = def["deprecatedBy"]

# ---------------------------------------------- renderer/canvas.js sanitizeEnumName (verbatim port)

static func _is_alpha(c: String) -> bool:
	return (c >= "a" and c <= "z") or (c >= "A" and c <= "Z")

static func _is_digit(c: String) -> bool:
	return c >= "0" and c <= "9"

static func _is_ws(c: String) -> bool:
	return c == " " or c == "\t" or c == "\n" or c == "\r"

static func _is_valid_identifier(name: String) -> bool:
	# reference: /^[a-zA-Z_][a-zA-Z0-9_]*$/
	if name.is_empty():
		return false
	if not (_is_alpha(name[0]) or name[0] == "_"):
		return false
	for i in range(1, name.length()):
		var c := name[i]
		if not (_is_alpha(c) or _is_digit(c) or c == "_"):
			return false
	return true

# "Cell Scale" -> "CellScale": uppercase the char after each whitespace run, drop the spaces, strip
# remaining non-identifier chars; "" if the result is not a valid identifier (reference returns null).
static func sanitize_enum_name(name: String) -> String:
	var result := ""
	var i := 0
	var n := name.length()
	while i < n:
		if _is_ws(name[i]):
			while i < n and _is_ws(name[i]):
				i += 1
			if i < n:
				result += name[i].to_upper()
				i += 1
		else:
			result += name[i]
			i += 1
	var stripped := ""
	for k in range(result.length()):
		var ch := result[k]
		if _is_alpha(ch) or _is_digit(ch) or ch == "_":
			stripped += ch
	return stripped if _is_valid_identifier(stripped) else ""
