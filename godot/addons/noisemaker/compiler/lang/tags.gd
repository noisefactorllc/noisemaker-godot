# tags.gd — effect tags, namespaces, and IO functions. Port of the REFERENCE
# shaders/src/runtime/tags.js (the stable parts the compiler consumes). Sources: upstream
# noisemaker + noisemaker-hlsl ONLY.
#
# The parser needs is_valid_namespace() + VALID_NAMESPACES (search-directive validation); the
# validator additionally needs the IO functions + built-in namespace. Runtime namespace
# registration (registerNamespace) is a UI/runtime concern, not used by corpus DSLs, so it is
# out of scope for the compiler port — VALID_NAMESPACES is the frozen built-in set.
extends RefCounted

# Built-in namespace ids, in declaration order (reference _builtinDescriptors).
const VALID_NAMESPACES := [
	"io", "classicNoisedeck", "synth", "mixer", "filter",
	"render", "points", "synth3d", "filter3d", "user",
]

# Valid effect tag ids (reference TAG_DEFINITIONS keys).
const VALID_TAGS := [
	"color", "distort", "edges", "geometric", "lens",
	"noise", "transform", "util", "sim", "3d", "audio",
]

# The always-available built-in namespace (functions need no search directive).
const BUILTIN_NAMESPACE := "io"

# Pipeline-level I/O operations (reference IO_FUNCTIONS).
const IO_FUNCTIONS := ["read", "write", "read3d", "write3d", "render", "render3d"]

static func is_valid_namespace(namespace_id: String) -> bool:
	return VALID_NAMESPACES.has(namespace_id)

static func is_valid_tag(tag_id: String) -> bool:
	return VALID_TAGS.has(tag_id)

static func is_io_function(func_name: String) -> bool:
	return IO_FUNCTIONS.has(func_name)
