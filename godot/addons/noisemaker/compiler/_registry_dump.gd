# _registry_dump.gd — CANDIDATE for the EffectRegistry parity gate. Builds the GDScript registry
# from the effect JSONs and prints its observable surfaces as JSON on a single REGDUMP: marker line
# (so the harness can skip Godot's boot noise). Pure logic -> runs --headless.
#   Godot --headless --path godot --script res://addons/noisemaker/compiler/_registry_dump.gd
extends SceneTree

const EffectRegistry := preload("res://addons/noisemaker/compiler/lang/effect_registry.gd")

func _init() -> void:
	var reg := EffectRegistry.new()
	reg.load_all()
	var out := {
		"ops": reg.ops_table(),
		"enums": reg.enums.project(),
		"paramAliases": reg.param_aliases(),
		"effectAliases": reg.effect_aliases(),
		"effectKeys": reg.effect_key_fingerprints(),
	}
	print("REGDUMP:", JSON.stringify(out))
	quit(0)
