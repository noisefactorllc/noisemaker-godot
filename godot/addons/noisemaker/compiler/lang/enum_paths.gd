# enum_paths.gd — member-path utilities. Port of TD compiler/lang/enum_paths.py
# (hlsl EnumPaths.cs / shaders/src/lang/enumPaths.js, reference/01 §8.3). Used by the validator's
# member / numeric-enum resolution. Pure static helpers over Array/String paths.
extends RefCounted

# List -> non-empty string segments; string -> split on '.', trim, drop empties; else null.
static func normalize_member_path(value):
	if value == null:
		return null
	if value is Array:
		var parts := []
		for seg in value:
			if seg:
				parts.append(seg)
		return parts if not parts.is_empty() else null
	if value is String:
		if value == "":
			return null
		var parts := []
		for seg in (value as String).split("."):
			var t := (seg as String).strip_edges()
			if t != "":
				parts.append(t)
		return parts if not parts.is_empty() else null
	return null

static func path_starts_with(path, prefix) -> bool:
	if prefix == null or (prefix is Array and prefix.is_empty()):
		return true
	if path == null or path.size() < prefix.size():
		return false
	for i in range(prefix.size()):
		if path[i] != prefix[i]:
			return false
	return true

# Qualify a short member with its enum name: if `path` already starts with `prefix` return a
# copy; else try each proper suffix of `prefix`; else prepend the whole prefix.
static func apply_enum_prefix(path, prefix):
	if path == null or (path is Array and path.is_empty()):
		return path
	if prefix == null or (prefix is Array and prefix.is_empty()):
		return (path as Array).duplicate()
	if path_starts_with(path, prefix):
		return (path as Array).duplicate()
	for i in range(1, prefix.size()):
		var suffix = (prefix as Array).slice(i)
		if path_starts_with(path, suffix):
			var result: Array = (prefix as Array).slice(0, i)
			result.append_array(path)
			return result
	var concat: Array = (prefix as Array).duplicate()
	concat.append_array(path)
	return concat
