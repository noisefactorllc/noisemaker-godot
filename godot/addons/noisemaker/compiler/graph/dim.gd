# dim.gd — texture dimension parse / scope. Port of TD compiler/graph/dim.py
# (hlsl Dim/GraphLoader.cs + Expander.ScopeDimSpec, reference/03 §2.4, §6).
#
# A dimension is kept as its native JSON value (the compiler only parses, scopes, and re-emits
# it — never resolves to pixels):
#     number | "screen"/"auto"/<literal> | "N%" | {param,...} | {screenDivide,...} | {scale,...}
# This matches the reference's parse+re-emit identity for canonical forms; the only transform the
# expander applies is param/screenDivide name-scoping.
extends RefCounted

# Identity for the compiler (null stays null). The texture-spec default 'screen' for an absent
# width/height is applied by the caller (mirrors compiler.js extractTextureSpecs).
static func parse_dim(v):
	return v

# reference/03 §6.3 — a {param} or {screenDivide} dim carries a scopable param name.
static func dim_references_param(d) -> bool:
	return d is Dictionary and (d.has("param") or d.has("screenDivide"))

# Rewrite a {param}/{screenDivide} dim to a scoped param name and record old->new in scoped_map
# (reference/03 §6.3 ScopeDimSpec). Other dims pass through unchanged.
static func scope_dim(d, scope_suffix: String, scoped_map: Dictionary):
	if not (d is Dictionary):
		return d
	if d.has("param"):
		var scoped: String = str(d["param"]) + "_" + scope_suffix
		scoped_map[d["param"]] = scoped
		var nd: Dictionary = (d as Dictionary).duplicate()
		nd["param"] = scoped
		return nd
	if d.has("screenDivide"):
		var scoped2: String = str(d["screenDivide"]) + "_" + scope_suffix
		scoped_map[d["screenDivide"]] = scoped2
		var nd2: Dictionary = (d as Dictionary).duplicate()
		nd2["screenDivide"] = scoped2
		return nd2
	return d
