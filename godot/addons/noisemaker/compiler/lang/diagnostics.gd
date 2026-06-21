# diagnostics.gd — diagnostic codes + default messages. Port of the REFERENCE
# shaders/src/lang/diagnostics.js (cross-checked vs noisemaker-hlsl Diagnostics.cs). Sources:
# upstream noisemaker + noisemaker-hlsl ONLY.
#
# The validator COLLECTS diagnostics (it does not throw, except missing-search) and builds each
# record itself (shape {code, message, severity, [location], [identifier]} — see validator.gd). This
# module supplies the code -> [default message, severity] table the validator looks up.
extends RefCounted

const SEVERITY_ERROR := "error"
const SEVERITY_WARNING := "warning"

# code -> [default message, severity] (verbatim from diagnostics.js).
const _TABLE := {
	"S001": ["Unknown identifier", "error"],
	"S002": ["Argument out of range", "warning"],
	"S003": ["Variable used before assignment", "error"],
	"S004": ["Cannot assign null or undefined", "error"],
	"S005": ["Illegal chain structure", "error"],
	"S006": ["Starter chain missing write() call", "error"],
	"S007": ["Deprecated parameter alias", "warning"],
	"S008": ["Deprecated effect", "warning"],
}

static func default_message(code: String) -> String:
	return _TABLE[code][0]

static func severity(code: String) -> String:
	return _TABLE[code][1]

# Build a diagnostic record (the shape the reference compile() emits in `diagnostics`).
static func make(code: String, message = null, line = null, column = null, identifier = null) -> Dictionary:
	var d := {
		"code": code,
		"message": message if message != null else default_message(code),
		"severity": severity(code),
	}
	if line != null:
		d["line"] = line
	if column != null:
		d["column"] = column
	if identifier != null:
		d["identifier"] = identifier
	return d
