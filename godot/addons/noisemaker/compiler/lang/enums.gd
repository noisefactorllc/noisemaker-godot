# enums.gd — stdEnums tree + dynamic enum registry. Port of TD compiler/lang/enums.py
# (hlsl Enums.cs / shaders/src/lang/std_enums.js + enums.js, reference/01 §8.1-§8.2).
#
# The enum tree maps dotted member paths (e.g. ["oscKind","sine"]) to integer leaves. A SUBTREE
# is a plain Dictionary {name: node}; a LEAF is {"type":"Number","value":int} (so a `type` key
# distinguishes them — reference deepMerge treats any object with a `type` key as a leaf). Effect
# `choices` layer on via register_choice; project (effect) enums take precedence over std
# (reference/02 §2.5).
#
# Instance-owned by EffectRegistry. The reference uses module globals; an instance is the clean
# GDScript adaptation — no cross-compile static state to reset.
#
# PARITY HAZARDS replicated:
#   - palette enum values are POSITIONAL indices into share/palettes.json key order, 0-based,
#     INCLUDING "none" at index 0 (reference/01 §8.1).
#   - oscKind.noise == oscKind.noise1d == 5 (reference/01 §8.1).
extends RefCounted

# share/palettes.json key order (verbatim, 0-based positional enum; "none" IS index 0; 56 entries).
const PALETTE_KEYS := [
	"none", "seventiesShirt", "fiveG", "afterimage", "barstow", "bloob",
	"blueSkies", "brushedMetal", "burningSky", "california", "columbia",
	"cottonCandy", "darkSatin", "dealerHat", "dreamy", "eventHorizon",
	"ghostly", "grayscale", "hazySunset", "heatmap", "hypercolor", "jester",
	"justBlue", "justCyan", "justGreen", "justPurple", "justRed", "justYellow",
	"mars", "modesto", "moss", "neptune", "netOfGems", "organic", "papaya",
	"radioactive", "royal", "santaCruz", "sherbet", "sherbetDouble", "silvermane",
	"skykissed", "solaris", "spooky", "springtime", "sproingtime", "sulphur",
	"summoning", "superhero", "toxic", "tropicalia", "tungsten", "vaporwave",
	"vibrant", "vintage", "vintagePhoto",
]

var _std: Dictionary
var _project: Dictionary

func _init() -> void:
	_std = _build_std()
	_project = {}

static func leaf(value) -> Dictionary:
	return {"type": "Number", "value": value}

static func is_leaf(node) -> bool:
	return node is Dictionary and node.get("type") == "Number"

func std() -> Dictionary:
	return _std

func project() -> Dictionary:
	return _project

# Top-level enum head, project before std (reference/02 §2.5 resolveEnum precedence).
func try_get_head(head: String):
	if _project.has(head):
		return _project[head]
	if _std.has(head):
		return _std[head]
	return null

# Install a nested enum leaf, e.g. register_choice(["filter","blur","mode","gaussian"], 0).
# Creates intermediate subtrees. Used by EffectRegistry to register effect `choices`.
func register_choice(path: Array, value) -> void:
	if path.is_empty():
		return
	var head = _project.get(path[0])
	if head == null or is_leaf(head):
		head = {}
		_project[path[0]] = head
	var cur: Dictionary = head
	for i in range(1, path.size() - 1):
		var nxt = cur.get(path[i])
		if nxt == null or is_leaf(nxt):
			nxt = {}
			cur[path[i]] = nxt
		cur = nxt
	cur[path[path.size() - 1]] = leaf(value)

func _build_std() -> Dictionary:
	var root := {}
	root["channel"] = {"r": leaf(0), "g": leaf(1), "b": leaf(2), "a": leaf(3)}
	root["color"] = {"mono": leaf(0), "rgb": leaf(1), "hsv": leaf(2)}
	root["oscType"] = {
		"sine": leaf(0), "linear": leaf(1), "sawtooth": leaf(2), "sawtoothInv": leaf(3),
		"square": leaf(4), "noise1d": leaf(5), "noise2d": leaf(6),
	}
	root["oscKind"] = {
		"sine": leaf(0), "tri": leaf(1), "saw": leaf(2), "sawInv": leaf(3), "square": leaf(4),
		"noise": leaf(5), "noise1d": leaf(5), "noise2d": leaf(6),  # noise == noise1d == 5
	}
	root["midiMode"] = {
		"noteChange": leaf(0), "gateNote": leaf(1), "gateVelocity": leaf(2),
		"triggerNote": leaf(3), "velocity": leaf(4),
	}
	root["audioBand"] = {"low": leaf(0), "mid": leaf(1), "high": leaf(2), "vol": leaf(3)}
	var palette := {}
	for idx in range(PALETTE_KEYS.size()):
		palette[PALETTE_KEYS[idx]] = leaf(idx)
	root["palette"] = palette
	return root
