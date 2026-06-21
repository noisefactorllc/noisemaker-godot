# _expand_dump.gd — CANDIDATE for the expander parity gate. Lexes + parses + validates + expands each
# DSL path passed after `--` and prints JSON { path: {ok, out} } on a single EXPANDDUMP: marker line.
# Pure logic -> runs --headless.
#   Godot --headless --path godot --script res://addons/noisemaker/compiler/_expand_dump.gd -- <f...>
extends SceneTree

const Lexer := preload("res://addons/noisemaker/compiler/lang/lexer.gd")
const Parser := preload("res://addons/noisemaker/compiler/lang/parser.gd")
const Validator := preload("res://addons/noisemaker/compiler/lang/validator.gd")
const Expander := preload("res://addons/noisemaker/compiler/graph/expander.gd")
const EffectRegistry := preload("res://addons/noisemaker/compiler/lang/effect_registry.gd")

func _init() -> void:
	var reg := EffectRegistry.new()
	reg.load_all()
	var out := {}
	for f in OS.get_cmdline_user_args():
		var src := FileAccess.get_file_as_string(f)
		var ast = Parser.new().parse_tokens(Lexer.lex(src))
		var validated = Validator.new(reg).validate(ast)
		var expanded = Expander.new(reg).expand(validated)
		out[f] = {"ok": true, "out": expanded}
	print("EXPANDDUMP:", JSON.stringify(out))
	quit(0)
