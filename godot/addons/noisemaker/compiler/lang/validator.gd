# validator.gd — semantic validator for the Polymorphic DSL. Port of the REFERENCE
# shaders/src/lang/validator.js (cross-checked vs noisemaker-hlsl Validator.cs). Sources: upstream
# noisemaker + noisemaker-hlsl ONLY.
#
# validate(ast) -> {plans, diagnostics, render, vars, searchNamespaces, trailingComments?}. It
# flattens each chain statement into a list of steps with temp surfaces, resolves every argument
# against its op-spec (numeric/enum/vec/bool/color/surface/...), and collects diagnostics (it never
# throws except on a missing search directive — which the parser already guarantees).
#
# Instance-owned: constructed with an EffectRegistry, which supplies the ops table, the enum trees
# (project + std), the param/effect alias maps, and the starter set.
#
# GDScript adaptations vs the JS:
#   - Diagnostics are COLLECTED, not thrown. The record shape matches the reference exactly:
#     {code, message, severity, [location:{line}], [identifier]} (nodeId is always undefined in the
#     corpus and so omitted; the parser stores loc.col not loc.column, so location is line-only).
#   - `new Function(...)` (arrow-expression compilation) has no GDScript equivalent; Func args/
#     conditions produce the same JSON-serializable residue the reference does ({min,max} / {}) — the
#     live `fn` is dropped by JSON.stringify on both sides anyway, and the corpus produces no Func
#     value-args. Runtime func evaluation is a task for the live-wiring stage.
#   - `?.`/`??` -> .get()/guards; spreads -> Dictionary.duplicate(); JSON-clone -> duplicate(true).
extends RefCounted

const ALIAS_EOL_DATE := "2026-09-01"

# !! Do not expand — strict allowlist for string params (reference ALLOWED_STRING_PARAMS).
const ALLOWED_STRING_PARAMS := ["text.text", "text.font", "text.justify"]
const STATE_SURFACES := ["time", "frame", "mouse", "resolution", "seed", "a"]
const STATE_VALUES := ["time", "frame", "mouse", "resolution", "seed", "a", "u1", "u2", "u3", "u4", "s1", "s2", "b1", "b2", "a1", "a2", "deltaTime"]
const SURFACE_PASSTHROUGH_CALLS := ["read"]

const Diagnostics := preload("res://addons/noisemaker/compiler/lang/diagnostics.gd")
const EnumPaths := preload("res://addons/noisemaker/compiler/lang/enum_paths.gd")

var reg                          # EffectRegistry
var _diagnostics: Array
var _temp_index: int
var _program_search_order: Array
var _symbols: Dictionary
var _enums_project: Dictionary   # effect-choice enum tree (reg.enums.project())
var _enums_std: Dictionary       # standard enum tree (reg.enums.std())

func _init(registry) -> void:
	reg = registry

# ---------------------------------------------------------------- entry

func validate(ast: Dictionary) -> Dictionary:
	_diagnostics = []
	_temp_index = 0
	_symbols = {}
	_enums_project = reg.enums.project()
	_enums_std = reg.enums.std()

	var render = null
	if ast.get("render") != null:
		render = ast["render"].get("name")

	var ns_meta = ast.get("namespace")
	_program_search_order = ns_meta.get("searchOrder", []) if ns_meta is Dictionary else []
	if _program_search_order == null or _program_search_order.size() == 0:
		push_error("Missing required 'search' directive.")
		_program_search_order = []

	var plans: Array = []

	# var declarations populate the symbol table
	if ast.get("vars") is Array:
		for v in ast["vars"]:
			_bind_var(v)

	for stmt in (ast.get("plans", []) if ast.get("plans") is Array else []):
		var compiled = _compile_stmt(stmt)
		if compiled != null:
			plans.push_back(compiled)

	var result := {
		"plans": plans,
		"diagnostics": _diagnostics,
		"render": render,
		"vars": (ast.get("vars", []) if ast.get("vars") is Array else []),
		"searchNamespaces": _program_search_order,
	}
	if ast.has("trailingComments"):
		result["trailingComments"] = ast["trailingComments"]
	return result

# ---------------------------------------------------------------- diagnostics

func _push_diag(code: String, node, message = null) -> void:
	if message == null:
		message = Diagnostics.default_message(code)
	var ident_name = _extract_identifier_name(node)
	var enriched: String = message
	if ident_name != null and ident_name != "" and not message.contains(ident_name) and not message.contains("'"):
		enriched = "%s: '%s'" % [message, ident_name]
	var rec := {
		"code": code,
		"message": enriched,
		"severity": Diagnostics.severity(code),
	}
	if node is Dictionary and node.get("loc") is Dictionary and node["loc"].has("line"):
		rec["location"] = {"line": node["loc"]["line"]}
	if ident_name != null and ident_name != "":
		rec["identifier"] = ident_name
	_diagnostics.push_back(rec)

func _extract_identifier_name(node):
	if node == null or not (node is Dictionary):
		return null
	var t = node.get("type")
	if t == "Ident":
		return node.get("name")
	if t == "Member" and node.get("path") is Array:
		return ".".join(node["path"])
	if t == "Call":
		return node.get("name")
	if t == "Func" and node.get("src"):
		var src: String = node["src"]
		return "{%s%s}" % [src.substr(0, 30), ("..." if src.length() > 30 else "")]
	if node.get("name") != null:
		return node.get("name")
	if node.get("value") != null:
		return str(node.get("value"))
	return "[%s]" % [node.get("type") if node.get("type") != null else "unknown"]

# ---------------------------------------------------------------- helpers

func _clamp(value, mn, mx):
	if (mn is float or mn is int) and value < mn:
		return mn
	if (mx is float or mx is int) and value > mx:
		return mx
	return value

func _to_boolean(value) -> bool:
	if value is float or value is int:
		return value != 0
	return bool(value)

func _to_surface(arg):
	if arg == null or not (arg is Dictionary):
		return null
	var t = arg.get("type")
	if t == "OutputRef":
		return {"kind": "output", "name": arg.get("name")}
	if t == "SourceRef":
		return {"kind": "source", "name": arg.get("name")}
	if t == "XyzRef":
		return {"kind": "xyz", "name": arg.get("name")}
	if t == "VelRef":
		return {"kind": "vel", "name": arg.get("name")}
	if t == "RgbaRef":
		return {"kind": "rgba", "name": arg.get("name")}
	if t == "MeshRef":
		return {"kind": "mesh", "name": arg.get("name")}
	if t == "Ident" and arg.get("name") == "none":
		return {"kind": "output", "name": "none"}
	if t == "Ident" and STATE_SURFACES.has(arg.get("name")):
		return {"kind": "state", "name": arg.get("name")}
	return null

func _call_to_surface(node):
	if node == null or not (node is Dictionary):
		return null
	if node.get("type") == "Chain" and node.get("chain") is Array and node["chain"].size() == 1:
		return _call_to_surface(node["chain"][0])
	if node.get("type") != "Call" or not SURFACE_PASSTHROUGH_CALLS.has(node.get("name")):
		return null
	var target = null
	if node.get("args") is Array and node["args"].size():
		target = node["args"][0]
	if target == null and node.get("kwargs") is Dictionary:
		target = node["kwargs"].get("tex")
	if target == null:
		return null
	return _to_surface(target)

func _is_starter_op(name) -> bool:
	if not (name is String):
		return false
	if name == "particles" or name == "render.particles":
		return false
	var starters: Dictionary = reg.starter_ops()
	if starters.has(name):
		return true
	var parts = name.split(".")
	if parts.size() > 1:
		var canonical: String = parts[parts.size() - 1]
		if starters.has(canonical):
			for op in starters:
				if op.ends_with("." + canonical):
					return false
			return true
	return false

func _check_effect_alias(op_name):
	var new_name = reg.effect_aliases().get(op_name)
	if new_name == null:
		return null
	var old_name: String = op_name.split(".")[-1] if op_name.contains(".") else op_name
	return "effect '%s' is deprecated, use '%s' instead. Aliases will be removed on %s." % [old_name, new_name, ALIAS_EOL_DATE]

func _resolve_param_aliases(op_name: String, kwargs: Dictionary) -> Array:
	var warnings: Array = []
	var aliases = reg.param_aliases().get(op_name)
	if not (aliases is Dictionary):
		return warnings
	for old_name in aliases.keys():
		if not kwargs.has(old_name):
			continue
		var new_name = aliases[old_name]
		if not kwargs.has(new_name):
			kwargs[new_name] = kwargs[old_name]
		kwargs.erase(old_name)
		warnings.push_back("param '%s' is deprecated, use '%s' instead. Aliases will be removed on %s." % [old_name, new_name, ALIAS_EOL_DATE])
	return warnings

func _clone(node):
	if node is Dictionary or node is Array:
		return node.duplicate(true)
	return node

# Resolve a dotted enum path to a number/leaf (symbols, then project enums, then std enums).
func _resolve_enum(path):
	if not (path is Array) or path.size() == 0:
		return null
	var head = path[0]
	var rest = path.slice(1)
	var cur
	if _symbols.has(head):
		cur = _symbols[head]
		if cur is Dictionary and (cur.get("type") == "Number" or cur.get("type") == "Boolean"):
			cur = cur.get("value")
	elif _enums_project.has(head):
		cur = _enums_project[head]
	elif _enums_std.has(head):
		cur = _enums_std[head]
	else:
		return null
	for part in rest:
		if cur is Dictionary and cur.has(part):
			cur = cur[part]
		else:
			return null
	if cur is Dictionary and (cur.get("type") == "Number" or cur.get("type") == "Boolean"):
		return cur.get("value")
	return cur

func _can_resolve_op_name(name) -> bool:
	for ns in _program_search_order:
		if reg.get_op("%s.%s" % [ns, name]) != null:
			return true
	return false

func _resolve_call(call: Dictionary) -> Dictionary:
	var cname = call.get("name")
	if _symbols.has(cname):
		var val = _symbols[cname]
		if val is Dictionary and val.get("type") == "Ident":
			var merged := call.duplicate()
			merged["name"] = val.get("name")
			return merged
		if val is Dictionary and val.get("type") == "Call":
			var merged_args: Array = (val.get("args").duplicate() if val.get("args") is Array else [])
			var call_args: Array = (call.get("args") if call.get("args") is Array else [])
			for i in range(call_args.size()):
				merged_args.push_back(call_args[i])
			var merged_kw = null
			if val.get("kwargs") is Dictionary:
				merged_kw = val["kwargs"].duplicate()
			if call.get("kwargs") is Dictionary:
				if merged_kw == null:
					merged_kw = {}
				for k in call["kwargs"].keys():
					merged_kw[k] = call["kwargs"][k]
			var merged := {"type": "Call", "name": val.get("name"), "args": merged_args}
			if merged_kw != null:
				merged["kwargs"] = merged_kw
			if call.get("namespace") != null:
				merged["namespace"] = call["namespace"].duplicate()
			elif val.get("namespace") != null:
				merged["namespace"] = val["namespace"].duplicate()
			return merged
	return call

func _first_chain_call(node):
	if node == null or not (node is Dictionary):
		return null
	if node.get("type") == "Call":
		return node
	if node.get("type") == "Chain":
		var head = node["chain"][0] if (node.get("chain") is Array and node["chain"].size()) else null
		return head if (head is Dictionary and head.get("type") == "Call") else null
	return null

func _get_starter_info(node):
	if node == null or not (node is Dictionary):
		return null
	if node.get("type") == "Call":
		var name = node.get("name")
		if node.get("namespace") is Dictionary and node["namespace"].get("resolved"):
			name = "%s.%s" % [node["namespace"]["resolved"], node["name"]]
		return {"call": node, "index": 0} if _is_starter_op(name) else null
	if node.get("type") == "Chain" and node.get("chain") is Array:
		for i in range(node["chain"].size()):
			var entry = node["chain"][i]
			if entry is Dictionary and entry.get("type") == "Call":
				var name = entry.get("name")
				if entry.get("namespace") is Dictionary and entry["namespace"].get("resolved"):
					name = "%s.%s" % [entry["namespace"]["resolved"], entry["name"]]
				if _is_starter_op(name):
					return {"call": entry, "index": i}
	return null

func _is_starter_chain(node) -> bool:
	if node == null or not (node is Dictionary) or node.get("type") != "Chain":
		return false
	var starter = _get_starter_info(node)
	return starter != null and starter.get("index") == 0

func _substitute(node):
	if node == null:
		return node
	if not (node is Dictionary):
		return node
	var t = node.get("type")
	if t == "Ident" and _symbols.has(node.get("name")):
		var result = _substitute(_clone(_symbols[node["name"]]))
		if result is Dictionary:
			result["_varRef"] = node["name"]
		return result
	if t == "Chain":
		var mapped: Array = []
		for c in node["chain"]:
			var mapped_args: Array = []
			for a in c.get("args", []):
				mapped_args.push_back(_substitute(a))
			var mapped_call := {"type": "Call", "name": c.get("name"), "args": mapped_args}
			if c.get("kwargs") is Dictionary:
				var kw := {}
				for k in c["kwargs"].keys():
					kw[k] = _substitute(c["kwargs"][k])
				mapped_call["kwargs"] = kw
			mapped.push_back(_resolve_call(mapped_call))
		return {"type": "Chain", "chain": mapped}
	if t == "Call":
		var mapped_args: Array = []
		for a in node.get("args", []):
			mapped_args.push_back(_substitute(a))
		var mapped_call := {"type": "Call", "name": node.get("name"), "args": mapped_args}
		if node.get("kwargs") is Dictionary:
			var kw := {}
			for k in node["kwargs"].keys():
				kw[k] = _substitute(node["kwargs"][k])
			mapped_call["kwargs"] = kw
		return _resolve_call(mapped_call)
	return node

func _bind_var(v: Dictionary) -> void:
	var expr = _substitute(_clone(v.get("expr")))
	if expr is Dictionary and _is_starter_chain(expr):
		var head = _first_chain_call(expr)
		if head:
			_push_diag("S006", head)
	if expr == null or (expr is Dictionary and expr.get("type") == "Ident" and (expr.get("name") == "null" or expr.get("name") == "undefined")):
		_push_diag("S004", v)
		return
	if expr is Dictionary and expr.get("type") == "Ident" and not _symbols.has(expr.get("name")) and not STATE_VALUES.has(expr.get("name")) and reg.get_op(expr.get("name")) == null and not _can_resolve_op_name(expr.get("name")):
		_push_diag("S003", expr)
		return
	if expr is Dictionary and expr.get("type") == "Chain" and expr["chain"].size() == 1:
		_symbols[v["name"]] = expr["chain"][0]
	elif expr is Dictionary and expr.get("type") == "Member":
		var resolved = _resolve_enum(expr["path"])
		if resolved is float or resolved is int:
			_symbols[v["name"]] = {"type": "Number", "value": resolved}
		elif resolved != null:
			_symbols[v["name"]] = resolved
		else:
			_symbols[v["name"]] = expr
	else:
		_symbols[v["name"]] = expr

func _eval_expr(node):
	var expr = _substitute(_clone(node))
	if expr is Dictionary and _is_starter_chain(expr):
		var head = _first_chain_call(expr)
		if head:
			_push_diag("S006", head)
	if expr is Dictionary and expr.get("type") == "Member":
		var resolved = _resolve_enum(expr["path"])
		if resolved is float or resolved is int:
			return {"type": "Number", "value": resolved}
		if resolved != null:
			return resolved
	return expr

# Conditions compile arrow-expressions to runtime closures in the reference; here we produce the
# same serializable residue (a Func condition serializes to {} — the live fn is dropped by JSON).
func _eval_condition(node):
	var expr = _eval_expr(node)
	if expr == null:
		return false
	if not (expr is Dictionary):
		return false
	var t = expr.get("type")
	if t == "Number":
		return _to_boolean(expr.get("value"))
	if t == "Boolean":
		return bool(expr.get("value"))
	if t == "Func":
		return {}  # live fn(state) dropped by JSON.stringify; corpus has none
	if t == "Ident":
		if _symbols.has(expr.get("name")):
			return _eval_condition(_symbols[expr["name"]])
		if STATE_VALUES.has(expr.get("name")):
			return {}  # {fn:(state)=>...} -> {} after JSON
		_push_diag("S003", expr)
		return false
	if t == "Member":
		var cur = _resolve_enum(expr["path"])
		if cur is float or cur is int:
			return _to_boolean(cur)
		if cur != null:
			return _to_boolean(cur)
		_push_diag("S001", expr, "Unknown enum path: '%s'" % [".".join(expr["path"]) if expr.get("path") is Array else "unknown"])
		return false
	return false

func _build_namespace_snapshot(call_namespace):
	if call_namespace == null or not (call_namespace is Dictionary):
		return null
	var snap := {
		"call": {
			"name": call_namespace.get("name") if call_namespace.get("name") is String else null,
			"resolved": call_namespace.get("resolved") if call_namespace.get("resolved") is String else null,
			"explicit": bool(call_namespace.get("explicit")),
			"source": call_namespace.get("source") if call_namespace.get("source") is String else null,
		}
	}
	if call_namespace.get("searchOrder") is Array:
		snap["call"]["searchOrder"] = call_namespace["searchOrder"].duplicate()
	if call_namespace.get("fromOverride"):
		snap["call"]["fromOverride"] = true
	if call_namespace.get("resolved"):
		snap["resolved"] = call_namespace["resolved"]
	return snap

# ---------------------------------------------------------------- statement compilation

func _compile_stmt(stmt):
	if not (stmt is Dictionary):
		return null
	var t = stmt.get("type")
	if t == "IfStmt":
		var cond = _eval_condition(stmt.get("condition"))
		var then_branch = _compile_block(stmt.get("then"))
		var elif_list: Array = []
		for e in (stmt.get("elif", []) if stmt.get("elif") is Array else []):
			elif_list.push_back({"cond": _eval_condition(e.get("condition")), "then": _compile_block(e.get("then"))})
		var else_branch = _compile_block(stmt.get("else"))
		return {"type": "Branch", "cond": cond, "then": then_branch, "elif": elif_list, "else": else_branch}
	if t == "Break":
		return {"type": "Break"}
	if t == "Continue":
		return {"type": "Continue"}
	if t == "Return":
		var node := {"type": "Return"}
		if stmt.get("value") != null:
			node["value"] = _eval_expr(stmt["value"])
		return node
	return _compile_chain_statement(stmt)

func _compile_block(body) -> Array:
	var result: Array = []
	for s in (body if body is Array else []):
		var compiled = _compile_stmt(s)
		if compiled != null:
			result.push_back(compiled)
	return result

func _compile_chain_statement(stmt: Dictionary):
	var chain: Array = []
	var states: Array = []

	var chain_node := {"type": "Chain", "chain": stmt.get("chain")}
	var has_write = stmt.get("write") != null or stmt.get("write3d") != null
	if not has_write and _is_starter_chain(chain_node):
		_push_diag("S006", stmt["chain"][0])
	if not has_write:
		_push_diag("S001", stmt["chain"][0], "Chain must have explicit write() or write3d() target")
		return null

	var write_name = stmt["write"].get("name") if stmt.get("write") is Dictionary else null
	var write3d_target = null
	if stmt.get("write3d") is Dictionary:
		var w3 = stmt["write3d"]
		write3d_target = {
			"tex3d": {"kind": "vol", "name": (w3["tex3d"].get("name") if w3.get("tex3d") is Dictionary else w3.get("tex3d"))},
			"geo": {"kind": "geo", "name": (w3["geo"].get("name") if w3.get("geo") is Dictionary else w3.get("geo"))},
		}

	var final_index = _process_chain(stmt.get("chain"), null, chain, states, write_name, false)

	var write_surf = null
	if stmt.get("write") is Dictionary:
		write_surf = {"kind": "output", "name": stmt["write"].get("name")}
	var plan := {"chain": chain, "write": write_surf, "write3d": write3d_target, "final": final_index, "states": states}
	if stmt.has("leadingComments"):
		plan["leadingComments"] = stmt["leadingComments"]
	return plan

# The chain flattener. Returns the final temp index (or null). Appends steps to `chain`.
func _process_chain(calls, input, chain: Array, states: Array, write_name, allow_starterless: bool):
	var current = input
	for original in (calls if calls is Array else []):
		var ot = original.get("type") if original is Dictionary else null

		if ot == "Read":
			if current != null:
				_push_diag("S001", original, "read() is a starter node and cannot be chained inline. Use standalone read() to start a new chain.")
				continue
			var surface = _to_surface(original.get("surface"))
			if surface == null:
				_push_diag("S001", original, "read() requires a valid surface reference")
				continue
			var idx := _temp_index; _temp_index += 1
			var step_args := {"tex": surface}
			if original.get("_skip") == true:
				step_args["_skip"] = true
			var step := {"op": "_read", "args": step_args, "from": null, "temp": idx, "builtin": true}
			if original.has("leadingComments"):
				step["leadingComments"] = original["leadingComments"]
			chain.push_back(step)
			current = idx
			continue

		if ot == "Read3D" and original.get("geo") != null:
			if current != null:
				_push_diag("S001", original, "read3d() is a starter node and cannot be chained inline. Use standalone read3d() to start a new chain.")
				continue
			var tex3d = _ref3d(original.get("tex3d"), "vol", "tex3d")
			var geo = _ref3d(original.get("geo"), "geo", "geo")
			if tex3d == null or geo == null:
				_push_diag("S001", original, "read3d() as starter requires tex3d and geo references")
				continue
			var idx := _temp_index; _temp_index += 1
			var step_args := {"tex3d": tex3d, "geo": geo}
			if original.get("_skip") == true:
				step_args["_skip"] = true
			var step := {"op": "_read3d", "args": step_args, "from": null, "temp": idx, "builtin": true}
			if original.has("leadingComments"):
				step["leadingComments"] = original["leadingComments"]
			chain.push_back(step)
			current = idx
			continue

		if ot == "Write":
			var surface = _to_surface(original.get("surface"))
			if surface == null:
				_push_diag("S001", original, "write() requires a valid surface reference")
				continue
			if current == null:
				_push_diag("S005", original, "write() requires an input - cannot be first in chain")
				continue
			var idx := _temp_index; _temp_index += 1
			var step := {"op": "_write", "args": {"tex": surface}, "from": current, "temp": idx, "builtin": true}
			if original.has("leadingComments"):
				step["leadingComments"] = original["leadingComments"]
			chain.push_back(step)
			current = idx
			continue

		if ot == "Write3D":
			var tex3d = _ref3d(original.get("tex3d"), "vol", "tex3d")
			var geo = _ref3d(original.get("geo"), "geo", "geo")
			if tex3d == null or geo == null:
				_push_diag("S001", original, "write3d() requires tex3d and geo references")
				continue
			if current == null:
				_push_diag("S005", original, "write3d() requires an input - cannot be first in chain")
				continue
			var idx := _temp_index; _temp_index += 1
			var step := {"op": "_write3d", "args": {"tex3d": tex3d, "geo": geo}, "from": current, "temp": idx, "builtin": true}
			if original.has("leadingComments"):
				step["leadingComments"] = original["leadingComments"]
			chain.push_back(step)
			current = idx
			continue

		if ot == "Subchain":
			if current == null:
				_push_diag("S005", original, "subchain() requires an input - cannot be first in chain")
				continue
			var begin_idx := _temp_index; _temp_index += 1
			var begin_step := {"op": "_subchain_begin", "args": {"name": original.get("name"), "id": original.get("id")}, "from": current, "temp": begin_idx, "builtin": true}
			if original.has("leadingComments"):
				begin_step["leadingComments"] = original["leadingComments"]
			chain.push_back(begin_step)
			current = begin_idx
			current = _process_chain(original.get("body"), current, chain, states, write_name, false)
			var end_idx := _temp_index; _temp_index += 1
			var end_step := {"op": "_subchain_end", "args": {"name": original.get("name"), "id": original.get("id")}, "from": current, "temp": end_idx, "builtin": true}
			chain.push_back(end_step)
			current = end_idx
			continue

		# regular effect call
		var call := _resolve_call(original.duplicate())
		var effective_search = call["namespace"].get("searchOrder") if call.get("namespace") is Dictionary else _program_search_order
		var op_name = null
		var spec = null
		var candidate_names: Array = []
		if call.get("namespace") is Dictionary and call["namespace"].get("resolved"):
			candidate_names.push_back("%s.%s" % [call["namespace"]["resolved"], call["name"]])
		if effective_search is Array:
			for ns in effective_search:
				candidate_names.push_back("%s.%s" % [ns, call["name"]])
		for candidate in candidate_names:
			if candidate != null and reg.get_op(candidate) != null:
				op_name = candidate
				spec = reg.get_op(candidate)
				break
		if spec == null:
			_push_diag("S001", original, "Unknown effect: '%s'" % [call.get("name")])
			continue
		var effect_alias_warning = _check_effect_alias(op_name)
		if effect_alias_warning:
			_push_diag("S008", original, effect_alias_warning)
		if op_name == "prev":
			var idx := _temp_index; _temp_index += 1
			var prev_args := {"tex": {"kind": "output", "name": write_name}}
			var prev_step := {"op": op_name, "args": prev_args, "from": current, "temp": idx}
			var nsnap = _build_namespace_snapshot(call.get("namespace"))
			if nsnap != null:
				prev_step["namespace"] = nsnap
			if original.has("leadingComments"):
				prev_step["leadingComments"] = original["leadingComments"]
			chain.push_back(prev_step)
			current = idx
			continue
		var is_starter = _is_starter_op(op_name)
		var starterless_root = current == null
		var allow_passthrough_root = allow_starterless and SURFACE_PASSTHROUGH_CALLS.has(op_name)
		if starterless_root and not is_starter and not allow_passthrough_root:
			_push_diag("S005", original)
			continue
		var starter_has_input = is_starter and current != null
		var from_input = null if starter_has_input else current
		if starter_has_input:
			_push_diag("S005", original)

		var resolved = _resolve_args(call, original, spec, op_name, chain, states, write_name)
		var args: Dictionary = resolved["args"]
		var arg_sources = resolved["argSources"]

		var idx := _temp_index; _temp_index += 1
		var step := {"op": op_name, "args": args, "from": from_input, "temp": idx}
		var nsnap = _build_namespace_snapshot(call.get("namespace"))
		if nsnap != null:
			step["namespace"] = nsnap
		if original.has("leadingComments"):
			step["leadingComments"] = original["leadingComments"]
		if original.get("kwargs") is Dictionary and original["kwargs"].size() > 0:
			step["rawKwargs"] = original["kwargs"]
		if arg_sources != null:
			step["argSources"] = arg_sources
		chain.push_back(step)
		current = idx
	return current

func _ref3d(node, vol_or_geo_kind: String, default_kind: String):
	if node is Dictionary and node.get("name"):
		var kind := default_kind
		if vol_or_geo_kind == "vol":
			kind = "vol" if node.get("type") == "VolRef" else "tex3d"
		else:
			kind = "geo"
		return {"kind": kind, "name": node["name"]}
	return null

func _arg(arr, i):
	return arr[i] if (arr is Array and i < arr.size()) else null

# Resolve every spec arg of a call into the compiled `args` dict (+ optional argSources sidecar),
# pushing diagnostics. Mirrors the per-type dispatch in the reference processChain.
func _resolve_args(call: Dictionary, original: Dictionary, spec: Dictionary, op_name: String, chain: Array, states: Array, write_name) -> Dictionary:
	var args := {}
	var arg_sources = null
	var kw = call.get("kwargs") if call.get("kwargs") is Dictionary else null
	if kw != null:
		var alias_warnings := _resolve_param_aliases(op_name, kw)
		for w in alias_warnings:
			_push_diag("S007", call, w)
	var seen := {}
	var spec_args: Array = spec.get("args", []) if spec.get("args") is Array else []
	var call_args = call.get("args", [])
	var i := 0
	while i < spec_args.size():
		var def = spec_args[i]
		var dname = def.get("name")
		var node = kw[dname] if (kw != null and kw.has(dname)) else _arg(call_args, i)
		node = _substitute(node)
		var arg_key = dname

		# Color spread: a bare Color into consecutive r/g/b numeric params.
		if kw == null and node is Dictionary and node.get("type") == "Color" and def.get("type") != "color" and dname == "r" and _spec_name(spec_args, i + 1) == "g" and _spec_name(spec_args, i + 2) == "b":
			var cv = node.get("value")
			args[arg_key] = cv[0]
			args[spec_args[i + 1].get("name")] = cv[1]
			args[spec_args[i + 2].get("name")] = cv[2]
			i += 3
			continue

		if kw != null and kw.has(dname):
			seen[dname] = true

		# Array literal — additive numeric input form.
		if node is Dictionary and node.get("type") == "ArrayLiteral":
			var value: Array = []
			for el in node.get("elements", []):
				if el.get("type") == "Number":
					value.push_back(el.get("value"))
				else:
					_push_diag("S002", el, "Array element must be a number for '%s' in %s()" % [dname, call.get("name")])
					value.push_back(0)
			args[arg_key] = value
			if arg_sources == null:
				arg_sources = {}
			arg_sources[arg_key] = "array"
			i += 1
			continue

		var dtype = def.get("type")
		if dtype == "surface":
			_resolve_surface_arg(node, def, args, arg_key, call, chain, states, write_name)
		elif dtype == "color":
			if node is Dictionary and node.get("type") == "String":
				_push_diag("S001", node, "String literal not allowed for color parameter '%s'" % [dname])
				args[arg_key] = def.get("default")
			elif node is Dictionary and node.get("type") == "Color":
				args[arg_key] = node.get("hex") if node.has("hex") else node.get("value")
			else:
				if node is Dictionary and node.get("type") != null and node.get("type") != "Ident":
					_push_diag("S002", node, "Argument out of range for '%s' in %s()" % [dname, call.get("name")])
				args[arg_key] = def.get("default")
		elif dtype == "vec3":
			args[arg_key] = _resolve_vecn_arg(node, def, dname, call, "vec3", 3, [0, 0, 0])
		elif dtype == "vec4":
			args[arg_key] = _resolve_vecn_arg(node, def, dname, call, "vec4", 4, [0, 0, 0, 1])
		elif dtype == "boolean":
			args[arg_key] = _resolve_boolean_arg(node, def, dname)
		elif dtype == "member":
			args[arg_key] = _resolve_member_arg(node, def, call)
		elif dtype == "volume":
			args[arg_key] = _resolve_vol_geo_arg(node, def, dname, call, "vol")
		elif dtype == "geometry":
			args[arg_key] = _resolve_vol_geo_arg(node, def, dname, call, "geo")
		elif dtype == "string":
			args[arg_key] = _resolve_string_arg(node, def, op_name, original)
		else:
			args[arg_key] = _resolve_numeric_arg(node, def, dname, call, spec, args)
		i += 1

	# _skip meta-argument
	if kw != null and kw.has("_skip"):
		var skip_node = kw["_skip"]
		if skip_node is Dictionary and skip_node.get("type") == "Boolean":
			args["_skip"] = skip_node.get("value")
		else:
			args["_skip"] = false
		seen["_skip"] = true

	# unknown kwargs
	if kw != null:
		for key in kw.keys():
			if not seen.has(key):
				_push_diag("S001", kw[key], "Unknown argument '%s' for %s()" % [key, call.get("name")])

	return {"args": args, "argSources": arg_sources}

func _spec_name(spec_args: Array, i: int):
	if i < spec_args.size() and spec_args[i] is Dictionary:
		return spec_args[i].get("name")
	return null

func _resolve_surface_arg(node, def: Dictionary, args: Dictionary, arg_key, call: Dictionary, chain: Array, states: Array, write_name) -> void:
	if node is Dictionary and node.get("type") == "String":
		_push_diag("S001", node, "String literal not allowed for surface parameter '%s'" % [def.get("name")])
		args[arg_key] = (_to_surface({"type": "Ident", "name": def.get("default")}) if def.get("default") else null)
		return
	var surf = null
	var invalid_starter_chain := false
	var starter = _get_starter_info(node) if node != null else null
	if node is Dictionary and node.get("type") == "Read" and node.get("surface"):
		surf = _to_surface(node["surface"])
	var inline_surface = surf if surf != null else _call_to_surface(node)
	if inline_surface != null:
		surf = inline_surface
	elif node is Dictionary and node.get("type") == "Chain":
		var idx = _process_chain(node["chain"], null, chain, states, write_name, true)
		if idx != null:
			surf = {"kind": "temp", "index": idx}
	elif node is Dictionary and node.get("type") == "Call":
		var idx = _process_chain([node], null, chain, states, write_name, true)
		if idx != null:
			surf = {"kind": "temp", "index": idx}
	elif starter != null:
		_push_diag("S005", starter.get("call"))
		invalid_starter_chain = true
	else:
		surf = _to_surface(node)
	if surf == null:
		if invalid_starter_chain:
			args[arg_key] = surf
			return
		if not def.get("default"):
			if node == null:
				_push_diag("S001", call, "Missing required surface argument '%s' for %s()" % [def.get("name"), call.get("name")])
			elif node.get("type") == "Ident" and not _symbols.has(node.get("name")):
				_push_diag("S003", node, "Undefined variable '%s' for '%s' in %s()" % [node.get("name"), def.get("name"), call.get("name")])
			else:
				var node_name = node.get("name")
				if node_name == null and node.get("path") is Array:
					node_name = ".".join(node["path"])
				if node_name == null:
					node_name = node.get("value")
				if node_name == null:
					node_name = node.get("type") if node.get("type") != null else "invalid"
				_push_diag("S001", node, "Invalid surface reference '%s' for '%s' in %s()" % [node_name, def.get("name"), call.get("name")])
		if def.get("default"):
			surf = _to_surface({"type": "Ident", "name": def.get("default")})
			if surf == null:
				surf = {"kind": "pipeline", "name": def.get("default")}
	args[arg_key] = surf

func _resolve_vecn_arg(node, def: Dictionary, dname, call: Dictionary, ctor: String, n: int, zero: Array):
	if node is Dictionary and node.get("type") == "String":
		_push_diag("S001", node, "String literal not allowed for %s parameter '%s'" % [ctor, dname])
		return (def.get("default").duplicate() if def.get("default") is Array else zero.duplicate())
	if node is Dictionary and node.get("type") == "Call" and node.get("name") == ctor and node.get("args") is Array and node["args"].size() == n:
		var value: Array = []
		for a in node["args"]:
			if a.get("type") == "Number":
				value.push_back(a.get("value"))
			else:
				_push_diag("S002", a, "Argument out of range for '%s' in %s()" % [dname, call.get("name")])
				value.push_back(0)
		return value
	if node is Dictionary and node.get("type") == "Color":
		return node["value"].slice(0, n)
	if node is Dictionary and node.get("type") != null and node.get("type") != "Ident":
		_push_diag("S002", node, "Argument out of range for '%s' in %s()" % [dname, call.get("name")])
	return (def.get("default").duplicate() if def.get("default") is Array else zero.duplicate())

func _resolve_boolean_arg(node, def: Dictionary, dname):
	if node is Dictionary and node.get("type") == "String":
		_push_diag("S001", node, "String literal not allowed for boolean parameter '%s'" % [dname])
		return (bool(def.get("default")) if def.get("default") != null else false)
	if node is Dictionary and node.get("type") == "Boolean":
		return bool(node.get("value"))
	if node is Dictionary and node.get("type") == "Number":
		return node.get("value") != 0
	if node is Dictionary and node.get("type") == "Func":
		return {}  # {fn:(state)=>!!fn} -> {} after JSON
	if node is Dictionary and node.get("type") == "Ident" and STATE_VALUES.has(node.get("name")):
		return {}  # {fn:(state)=>!!state[key]} -> {} after JSON
	if node is Dictionary and node.get("type") == "Ident" and not STATE_VALUES.has(node.get("name")):
		_push_diag("S003", node)
	elif node is Dictionary and node.get("type") != null and node.get("type") != "Ident":
		_push_diag("S002", node, "Argument out of range for '%s' in %s()" % [dname, "?"])
	return (bool(def.get("default")) if def.get("default") != null else false)

func _resolve_member_arg(node, def: Dictionary, call: Dictionary):
	if node is Dictionary and node.get("type") == "String":
		_push_diag("S001", node, "String literal not allowed for member/enum parameter '%s'" % [def.get("name")])
		return def.get("default")
	var prefix = EnumPaths.normalize_member_path(def.get("enumPath") if def.get("enumPath") != null else def.get("enum"))
	var path = null
	if node is Dictionary and node.get("type") == "Member":
		path = EnumPaths.normalize_member_path(node.get("path"))
	elif node is Dictionary and (node.get("type") == "Number" or node.get("type") == "Boolean"):
		return (1 if node.get("value") else 0) if node.get("type") == "Boolean" else node.get("value")
	elif node is Dictionary and node.get("type") == "Ident" and STATE_VALUES.has(node.get("name")):
		return {}  # {fn:(state)=>state[key]} -> {} after JSON
	elif node is Dictionary and node.get("type") == "Ident":
		path = [node.get("name")]
	if path == null:
		path = EnumPaths.normalize_member_path(def.get("default"))
	var resolved = _resolve_enum(path) if path != null else null
	resolved = _enum_num(resolved)
	if not (resolved is float or resolved is int):
		path = EnumPaths.apply_enum_prefix(path if path != null else [], prefix)
		if prefix != null and path != null and not EnumPaths.path_starts_with(path, prefix):
			_push_diag("S001", node if node != null else call, "Invalid enum value for '%s': expected path starting with '%s'" % [def.get("name"), ".".join(prefix)])
			path = prefix.duplicate()
		resolved = _resolve_enum(path) if path != null else null
		resolved = _enum_num(resolved)
	if not (resolved is float or resolved is int):
		var fallback = EnumPaths.normalize_member_path(def.get("default"))
		var fv = _resolve_enum(fallback) if fallback != null else null
		fv = _enum_num(fv)
		resolved = fv if (fv is float or fv is int) else 0
	if node is Dictionary and node.get("type") == "Member" and path != null:
		node["path"] = path.duplicate()
	return resolved

# Collapse a leaf-or-number into a plain number (or leave as-is if neither).
func _enum_num(resolved):
	if resolved is Dictionary and resolved.get("type") == "Number":
		return resolved.get("value")
	if resolved is Dictionary and resolved.get("type") == "Boolean":
		return 1 if resolved.get("value") else 0
	return resolved

func _resolve_vol_geo_arg(node, def: Dictionary, dname, call: Dictionary, kind: String):
	var label := "volume" if kind == "vol" else "geometry"
	if node is Dictionary and node.get("type") == "String":
		_push_diag("S001", node, "String literal not allowed for %s parameter '%s'" % [label, dname])
		return ({"kind": kind, "name": def.get("default")} if def.get("default") else null)
	var rx := RegEx.new()
	rx.compile("^%s[0-7]$" % kind)
	if node is Dictionary and node.get("type") == "Read3D" and node.get("tex3d") and not node.get("geo"):
		var nm = node["tex3d"].get("name")
		if rx.search(nm) != null:
			return {"kind": kind, "name": nm}
		_push_diag("S001", node, "Invalid %s reference '%s' in read3d() for '%s' - expected %s0-%s7" % [label, nm, dname, kind, kind])
		return ({"kind": kind, "name": def.get("default")} if def.get("default") else null)
	var ref_type := "VolRef" if kind == "vol" else "GeoRef"
	if node is Dictionary and node.get("type") == ref_type:
		return {"kind": kind, "name": node.get("name")}
	if node is Dictionary and node.get("type") == "Ident":
		var nm = node.get("name")
		if nm == "none":
			return {"kind": kind, "name": "none"}
		if rx.search(nm) != null:
			return {"kind": kind, "name": nm}
		_push_diag("S001", node, "Invalid %s reference '%s' for '%s' - expected %s0-%s7 or none" % [label, nm, dname, kind, kind])
		return ({"kind": kind, "name": def.get("default")} if def.get("default") else null)
	if node == null and def.get("default"):
		return {"kind": kind, "name": def.get("default")}
	return null

func _resolve_string_arg(node, def: Dictionary, op_name: String, original):
	var func_name: String = op_name.split(".")[-1] if op_name.contains(".") else op_name
	var allowlist_key := "%s.%s" % [func_name, def.get("name")]
	if not ALLOWED_STRING_PARAMS.has(allowlist_key):
		_push_diag("S001", node if node != null else original, "String parameter '%s' on effect '%s' is NOT in the allowed string params list. String params are strictly controlled - use enums or choices instead." % [def.get("name"), func_name])
		return def.get("default")
	if node is Dictionary and node.get("type") == "String":
		return node.get("value")
	if node is Dictionary and node.get("type") == "Ident" and def.get("choices") is Dictionary:
		if def["choices"].has(node.get("name")):
			return def["choices"][node["name"]]
		_push_diag("S001", node, "Invalid choice '%s' for string parameter '%s'" % [node.get("name"), def.get("name")])
		return def.get("default")
	if node != null:
		_push_diag("S001", node, "String parameter '%s' requires a quoted string literal, got %s" % [def.get("name"), node.get("type")])
		return def.get("default")
	return def.get("default")

func _resolve_numeric_arg(node, def: Dictionary, dname, call: Dictionary, spec: Dictionary, args: Dictionary):
	if node is Dictionary and node.get("type") == "String":
		_push_diag("S001", node, "String literal not allowed for numeric parameter '%s' - strings are only valid for type: \"string\" parameters" % [dname])
		return def.get("default")
	if node is Dictionary and (node.get("type") == "Number" or node.get("type") == "Boolean"):
		var value = (1 if node.get("value") else 0) if node.get("type") == "Boolean" else node.get("value")
		var clamped = _clamp(value, def.get("min"), def.get("max"))
		if clamped != value:
			_push_diag("S002", node, "Argument out of range for '%s' in %s() (got %s, clamped to %s)" % [dname, call.get("name"), str(value), str(clamped)])
		value = clamped
		if node.has("_varRef"):
			value = {"_varRef": node["_varRef"], "value": value}
		return value
	if node is Dictionary and node.get("type") == "Func":
		var v := {}
		if def.get("min") != null:
			v["min"] = def.get("min")
		if def.get("max") != null:
			v["max"] = def.get("max")
		return v  # {fn, min, max} -> {min,max} after JSON
	if node is Dictionary and node.get("type") == "Oscillator":
		return _resolve_osc_value(node)
	if node is Dictionary and node.get("type") == "Midi":
		return _resolve_midi_value(node)
	if node is Dictionary and node.get("type") == "Audio":
		return _resolve_audio_value(node)
	if node is Dictionary and node.get("type") == "Member":
		var cur = _resolve_enum(node.get("path"))
		if cur is float or cur is int:
			var value = _clamp(cur, def.get("min"), def.get("max"))
			if value != cur:
				_push_diag("S002", node, "Argument out of range for '%s' in %s() (got %s, clamped to %s)" % [dname, call.get("name"), str(cur), str(value)])
			return value
		if cur is bool:
			var num = 1 if cur else 0
			var value = _clamp(num, def.get("min"), def.get("max"))
			if value != num:
				_push_diag("S002", node, "Argument out of range for '%s' in %s() (got %s, clamped to %s)" % [dname, call.get("name"), str(num), str(value)])
			return value
		_push_diag("S001", node, "Cannot resolve enum value for '%s': '%s'" % [dname, (".".join(node["path"]) if node.get("path") is Array else (node.get("name") if node.get("name") else "unknown"))])
		return def.get("default")
	if node is Dictionary and node.get("type") == "Ident" and STATE_VALUES.has(node.get("name")):
		var v := {}
		if def.get("min") != null:
			v["min"] = def.get("min")
		if def.get("max") != null:
			v["max"] = def.get("max")
		return v  # {fn:(state)=>state[key], min, max} -> {min,max} after JSON
	if node is Dictionary and node.get("type") == "Ident" and def.get("enum"):
		var prefix = EnumPaths.normalize_member_path(def.get("enum"))
		var path = (prefix + [node.get("name")]) if prefix != null else [node.get("name")]
		var resolved = _resolve_enum(path)
		if resolved is float or resolved is int:
			return _clamp(resolved, def.get("min"), def.get("max"))
		if resolved is Dictionary and resolved.get("type") == "Number":
			return _clamp(resolved.get("value"), def.get("min"), def.get("max"))
		_push_diag("S003", node)
		return def.get("default")
	if node is Dictionary and node.get("type") == "Ident" and def.get("choices") is Dictionary:
		var choice_val = def["choices"].get(node.get("name"))
		if choice_val is float or choice_val is int:
			return _clamp(choice_val, def.get("min"), def.get("max"))
		_push_diag("S003", node)
		return def.get("default")
	# default
	if node is Dictionary and node.get("type") == "Ident" and not STATE_VALUES.has(node.get("name")):
		_push_diag("S003", node)
	elif node is Dictionary and node.get("type") != null and node.get("type") != "Ident":
		_push_diag("S002", node, "Argument out of range for '%s' in %s()" % [dname, call.get("name")])
	if def.get("defaultFrom"):
		var ref_key = def.get("defaultFrom")
		for d in spec.get("args", []):
			if d.get("name") == def.get("defaultFrom"):
				ref_key = d.get("name")
				break
		if args.has(ref_key):
			return args[ref_key]
		return def.get("default")
	return def.get("default")

# Oscillator/Midi/Audio value resolution (faithful; the corpus produces none of these value-args).
func _resolve_osc_value(node: Dictionary) -> Dictionary:
	var osc_type_value = _enum_from_member_or_ident(node.get("oscType"), "oscKind")
	var v := {
		"type": "Oscillator",
		"oscType": osc_type_value,
		"min": clampf(_osc_param(node.get("min"), 0), 0.0, 1.0),
		"max": clampf(_osc_param(node.get("max"), 1), 0.0, 1.0),
		"speed": _osc_param(node.get("speed"), 1),
		"offset": _osc_param(node.get("offset"), 0),
		"seed": _osc_param(node.get("seed"), 1),
		"_ast": node,
	}
	if node.has("_varRef"):
		v["_varRef"] = node["_varRef"]
	return v

func _resolve_midi_value(node: Dictionary) -> Dictionary:
	var mode_value = _enum_from_member_or_ident(node.get("mode"), "midiMode")
	if not (mode_value is float or mode_value is int):
		mode_value = 4
	var v := {
		"type": "Midi",
		"channel": _osc_param(node.get("channel"), 1),
		"mode": mode_value,
		"min": clampf(_osc_param(node.get("min"), 0), 0.0, 1.0),
		"max": clampf(_osc_param(node.get("max"), 1), 0.0, 1.0),
		"sensitivity": _osc_param(node.get("sensitivity"), 1),
		"_ast": node,
	}
	if node.has("_varRef"):
		v["_varRef"] = node["_varRef"]
	return v

func _resolve_audio_value(node: Dictionary) -> Dictionary:
	var band_value = _enum_from_member_or_ident(node.get("band"), "audioBand")
	if not (band_value is float or band_value is int):
		band_value = 0
	var v := {
		"type": "Audio",
		"band": band_value,
		"min": clampf(_osc_param(node.get("min"), 0), 0.0, 1.0),
		"max": clampf(_osc_param(node.get("max"), 1), 0.0, 1.0),
		"_ast": node,
	}
	if node.has("_varRef"):
		v["_varRef"] = node["_varRef"]
	return v

func _enum_from_member_or_ident(type_node, enum_head: String):
	if type_node is Dictionary and type_node.get("type") == "Member":
		var r = _resolve_enum(type_node.get("path"))
		if r is float or r is int:
			return r
		if r is Dictionary and r.get("type") == "Number":
			return r.get("value")
	elif type_node is Dictionary and type_node.get("type") == "Ident":
		var r = _resolve_enum([enum_head, type_node.get("name")])
		if r is float or r is int:
			return r
		if r is Dictionary and r.get("type") == "Number":
			return r.get("value")
	return 0

func _osc_param(param, fallback):
	if param == null or not (param is Dictionary):
		return fallback
	var t = param.get("type")
	if t == "Number":
		return param.get("value")
	if t == "Boolean":
		return 1 if param.get("value") else 0
	if t == "Member":
		var r = _resolve_enum(param.get("path"))
		if r is float or r is int:
			return r
		if r is Dictionary and r.get("type") == "Number":
			return r.get("value")
	return fallback
