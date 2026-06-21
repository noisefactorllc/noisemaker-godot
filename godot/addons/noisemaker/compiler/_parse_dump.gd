# _parse_dump.gd — CANDIDATE for the parser parity gate. Lexes + parses each DSL path passed after
# `--` with the GDScript lexer + parser and prints JSON { path: {ok, ast} } on a single PARSEDUMP:
# marker line (so the harness can skip Godot's boot noise). Pure logic -> runs --headless.
#   Godot --headless --path godot --script res://addons/noisemaker/compiler/_parse_dump.gd -- <f...>
extends SceneTree

const Lexer := preload("res://addons/noisemaker/compiler/lang/lexer.gd")
const Parser := preload("res://addons/noisemaker/compiler/lang/parser.gd")

func _init() -> void:
	var out := {}
	for f in OS.get_cmdline_user_args():
		var src := FileAccess.get_file_as_string(f)
		var toks := Lexer.lex(src)
		var p := Parser.new()
		var ast = p.parse_tokens(toks)
		out[f] = {"ok": not p._err, "ast": ast}
	print("PARSEDUMP:", JSON.stringify(out))
	quit(0)
