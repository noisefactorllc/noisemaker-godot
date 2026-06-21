# _validate_dump.gd — CANDIDATE for the validator parity gate. Lexes + parses + validates each DSL
# path passed after `--` and prints JSON { path: {ok, out} } on a single VALIDATEDUMP: marker line.
# Pure logic -> runs --headless.
#   Godot --headless --path godot --script res://addons/noisemaker/compiler/_validate_dump.gd -- <f...>
extends SceneTree

const Lexer := preload("res://addons/noisemaker/compiler/lang/lexer.gd")
const Parser := preload("res://addons/noisemaker/compiler/lang/parser.gd")
const Validator := preload("res://addons/noisemaker/compiler/lang/validator.gd")
const EffectRegistry := preload("res://addons/noisemaker/compiler/lang/effect_registry.gd")

func _init() -> void:
	var reg := EffectRegistry.new()
	reg.load_all()
	var out := {}
	for f in OS.get_cmdline_user_args():
		var src := FileAccess.get_file_as_string(f)
		var toks := Lexer.lex(src)
		var p := Parser.new()
		var ast = p.parse_tokens(toks)
		var v := Validator.new(reg)
		var res = v.validate(ast)
		out[f] = {"ok": not p._err, "out": res}
	print("VALIDATEDUMP:", JSON.stringify(out))
	quit(0)
