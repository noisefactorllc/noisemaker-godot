# _smoke.gd — TEMPORARY foundation smoke test (deleted once the lexer gate exists).
# Validates the 7 foundation modules parse + behave, locking the GDScript conventions before
# the big stages stack on top. Pure logic → runs --headless.
#   Godot --headless --path godot --script res://addons/noisemaker/compiler/_smoke.gd
extends SceneTree

const Token = preload("res://addons/noisemaker/compiler/lang/token.gd")
const Ast = preload("res://addons/noisemaker/compiler/lang/ast.gd")
const Diagnostics = preload("res://addons/noisemaker/compiler/lang/diagnostics.gd")
const EnumPaths = preload("res://addons/noisemaker/compiler/lang/enum_paths.gd")
const Enums = preload("res://addons/noisemaker/compiler/lang/enums.gd")
const Dim = preload("res://addons/noisemaker/compiler/graph/dim.gd")
const Resources = preload("res://addons/noisemaker/compiler/graph/resources.gd")

var _ok := true

func _init() -> void:
	# Token
	var t = Token.new(Token.NUMBER, "1.5", 2, 3)
	_expect(t.to_dict() == {"type": "NUMBER", "lexeme": "1.5", "line": 2, "col": 3}, "token.to_dict")

	# Ast
	_expect(Ast.number(1.5) == {"type": "Number", "value": 1.5}, "ast.number")
	_expect(Ast.member_of("oscKind", "sine") == {"type": "Member", "path": ["oscKind", "sine"]}, "ast.member_of")
	_expect(Ast.String_ == "String", "ast.String_-const")

	# Diagnostics
	var d = Diagnostics.make("S001", null, 1, 2, "foo")
	_expect(d["code"] == "S001" and d["severity"] == "error" and d["message"] == "Unknown identifier"
		and d["line"] == 1 and d["column"] == 2 and d["identifier"] == "foo", "diag.make-full")
	var d2 = Diagnostics.make("S007")
	_expect(d2["severity"] == "warning" and d2["message"] == "Deprecated parameter alias" and not d2.has("line"), "diag.make-min")

	# EnumPaths
	_expect(EnumPaths.normalize_member_path("oscKind.sine") == ["oscKind", "sine"], "enumpaths.normalize-str")
	_expect(EnumPaths.normalize_member_path(["a", "", "b"]) == ["a", "b"], "enumpaths.normalize-arr")
	_expect(EnumPaths.normalize_member_path("") == null, "enumpaths.normalize-empty")
	_expect(EnumPaths.apply_enum_prefix(["sine"], ["oscKind"]) == ["oscKind", "sine"], "enumpaths.apply-prepend")
	_expect(EnumPaths.apply_enum_prefix(["oscKind", "sine"], ["oscKind"]) == ["oscKind", "sine"], "enumpaths.apply-already")

	# Enums
	var e = Enums.new()
	var pal = e.try_get_head("palette")
	_expect(pal != null and pal["none"] == {"type": "Number", "value": 0}, "enums.palette-none")
	_expect(pal["vintagePhoto"]["value"] == 55, "enums.palette-last")
	var osc = e.try_get_head("oscKind")
	_expect(osc["noise"]["value"] == 5 and osc["noise1d"]["value"] == 5, "enums.osckind-noise-alias")
	e.register_choice(["filter", "blur", "mode", "gaussian"], 0)
	var fhead = e.try_get_head("filter")
	_expect(fhead["blur"]["mode"]["gaussian"]["value"] == 0, "enums.register-choice")

	# Dim
	var sm := {}
	var scoped = Dim.scope_dim({"param": "stateSize"}, "n0", sm)
	_expect(scoped == {"param": "stateSize_n0"} and sm == {"stateSize": "stateSize_n0"}, "dim.scope")
	_expect(Dim.dim_references_param({"screenDivide": "x"}) == true, "dim.refs-param")
	_expect(Dim.parse_dim("screen") == "screen", "dim.parse-identity")

	# Resources — outputs allocated BEFORE inputs released within a pass (parity-critical):
	# t_b can't reuse t_a's slot because t_a is released only after t_b is allocated.
	var passes := [
		{"inputs": {}, "outputs": {"out": "t_a"}},
		{"inputs": {"in": "t_a"}, "outputs": {"out": "t_b"}},
	]
	_expect(Resources.allocate_resources(passes) == {"t_a": "phys_0", "t_b": "phys_1"}, "resources.alloc-order")
	# now a 3rd pass after t_a's release CAN reuse phys_0:
	var passes3 := [
		{"inputs": {}, "outputs": {"out": "t_a"}},
		{"inputs": {"in": "t_a"}, "outputs": {"out": "t_b"}},
		{"inputs": {"in": "t_b"}, "outputs": {"out": "t_c"}},
	]
	_expect(Resources.allocate_resources(passes3) == {"t_a": "phys_0", "t_b": "phys_1", "t_c": "phys_0"}, "resources.reuse")
	# global_ excluded
	var passes2 := [
		{"inputs": {}, "outputs": {"out": "global_o0"}},
		{"inputs": {"in": "global_o0"}, "outputs": {"out": "t_c"}},
	]
	_expect(Resources.allocate_resources(passes2) == {"t_c": "phys_0"}, "resources.global-excluded")

	print("SMOKE: ", "ALL PASS" if _ok else "FAILURES ABOVE")
	quit(0 if _ok else 1)

func _expect(cond: bool, label: String) -> void:
	print(("  ok   " if cond else "  FAIL ") + label)
	if not cond:
		_ok = false
