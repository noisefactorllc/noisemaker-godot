# _lex_dump.gd — CANDIDATE for the lexer parity gate. Lexes each DSL path passed after `--` with
# the GDScript lexer and prints JSON { path: [token-dicts] } on a single LEXDUMP: marker line
# (so the harness can skip Godot's boot noise). Pure logic → runs --headless.
#   Godot --headless --path godot --script res://addons/noisemaker/compiler/_lex_dump.gd -- <f...>
extends SceneTree

const Lexer = preload("res://addons/noisemaker/compiler/lang/lexer.gd")

func _init() -> void:
	var out := {}
	for f in OS.get_cmdline_user_args():
		var src := FileAccess.get_file_as_string(f)
		var arr: Array = []
		for t in Lexer.lex(src):
			arr.append(t.to_dict())
		out[f] = arr
	print("LEXDUMP:", JSON.stringify(out))
	quit(0)
