#version 450
// filter/tile — ported PIXEL-IDENTICALLY from wgsl/tile.wgsl.
// Symmetry-based kaleidoscope tiler (a COORD-RESAMPLING warp: maps fragCoord to a
// folded/tiled coord via square or hex symmetry, then samples the input there).
// Single render pass (progName "tile").
//
// No-layout effect (tile.json has no uniformLayout): the backend SYNTHESIZES the
// Params UBO and injects, after #version, a `#define <name> data[slot].comp` for
// every engine global and every param uniform (symmetry, scale, offsetX, offsetY,
// angle, repeat, aspectLens). So we use the bare names directly and declare NO UBO
// and NO uniforms. The input texture is bound at set 0, binding 1 (pass.inputs
// order). No shared nm_core primitives are used, so nm_core.glsl is NOT included.
//
// COORDINATE NOTE: this is a filter — WGSL samples uv = pos.xy / textureDimensions
// (inputTex), i.e. divides by the INPUT TEXTURE size (NOT fullResolution). We use
// textureSize(inputTex, 0). gl_FragCoord is top-left (matches WGSL); NO Y-flip —
// the uv math is ported EXACTLY and the global present flip reconciles orientation.
//
// SAMPLING NOTE: the backend's sampler for effect targets is NEAREST (matches the
// reference). This is a coord-resampling warp, so we sample at the computed coord
// directly via plain texture() — no added interpolation, no texel snapping.
//
// TRANSLATION HAZARDS:
//  * symmetry / aspectLens are int params -> synthesized layout delivers them as a
//    float `data[].comp`. symmetry is compared against enum values, so wrap int()
//    at each comparison site: int(symmetry) == 3, etc. aspectLens is boolean: test
//    against 0 (here via `int(aspectLens) != 0`).
//  * atan2(p.y, p.x) -> atan(p.y, p.x) — WGSL arg order copied literally.
//  * WGSL float `%` (modulo) -> GLSL mod(a, b); operands are made non-negative first
//    so the sign convention matches.
//  * select(a, b, cond) -> cond ? b : a (operands reversed).
//  * textureSampleLevel(t, s, c, 0.0) -> texture(t, c); textureDimensions(t) ->
//    textureSize(t, 0).
//  * The WGSL local `let fn_val = f32(n)` (renamed there because `fn` is reserved in
//    WGSL) is kept verbatim — `fn_val` is a fine GLSL identifier.
//  * `repeat`/`scale`/`angle`/`offsetX`/`offsetY` are used as the bare injected names
//    exactly where the WGSL used the uniforms (no `let` alias exists to drop).
//  * PI / TAU constants copied verbatim from WGSL; no arithmetic reassociation.
layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

const float PI = 3.14159265359;
const float TAU = 6.28318530718;

// rot — verbatim from WGSL rot(p, a).
vec2 rot(vec2 p, float a) {
	float c = cos(a);
	float s = sin(a);
	return vec2(p.x * c - p.y * s, p.x * s + p.y * c);
}

// mirrorFold — verbatim from WGSL mirrorFold(t).
float mirrorFold(float t) {
	return 1.0 - abs(2.0 * fract(t * 0.5) - 1.0);
}

// fract2 — verbatim from WGSL fract2(v).
vec2 fract2(vec2 v) {
	return v - floor(v);
}

// mod2 — verbatim from WGSL mod2(v, m).
vec2 mod2(vec2 v, vec2 m) {
	return v - m * floor(v / m);
}

// hexCoord — verbatim from WGSL hexCoord(uv).
vec2 hexCoord(vec2 uv) {
	vec2 s = vec2(1.0, 1.7320508);
	vec2 h = s * 0.5;

	vec2 a = mod2(uv, s) - h;
	vec2 b = mod2(uv + h, s) - h;

	if (dot(a, a) < dot(b, b)) {
		return a;
	} else {
		return b;
	}
}

// rotationalFold — verbatim from WGSL rotationalFold(uv, n).
//   WGSL: a = ((a + TAU) % TAU) % sectorAngle; -> GLSL mod() (args non-negative).
vec2 rotationalFold(vec2 uv, int n) {
	float fn_val = float(n);
	float sectorAngle = TAU / fn_val;

	vec2 p = uv - 0.5;
	float a = atan(p.y, p.x);
	float r = length(p);

	a = mod(mod(a + TAU, TAU), sectorAngle);
	if (a > sectorAngle * 0.5) {
		a = sectorAngle - a;
	}

	return vec2(r * cos(a), r * sin(a)) + 0.5;
}

void main() {
	vec2 texSize = vec2(textureSize(inputTex, 0));
	vec2 uv = gl_FragCoord.xy / texSize;
	float asp = texSize.x / texSize.y;
	bool doAspect = int(aspectLens) != 0;

	// Rotate in aspect-corrected space to avoid shearing on non-square canvases
	vec2 st = uv - 0.5;
	if (doAspect) { st.x *= asp; }
	st = rot(st, angle * PI / 180.0);
	if (doAspect) { st.x /= asp; }
	st += 0.5;

	// Aspect-corrected repeat count: more tiles along the longer axis
	vec2 rep = doAspect ? vec2(repeat * asp, repeat) : vec2(repeat);

	if (int(symmetry) == 3) {
		// Hex tiling with 6-fold rotational symmetry
		// Offset pans the entire texture (applied before hex grid computation)
		vec2 local_hex = hexCoord((st + vec2(offsetX, offsetY)) * rep);
		vec2 local_scaled = local_hex / scale;
		st = rotationalFold(local_scaled + 0.5, 6);
	} else {
		// Square tiling
		st = fract2(st * rep);

		// Apply source region transforms (before fold — fold handles any input range)
		// mirrorXY needs half the range so edges match at default scale
		float effectiveScale = scale;
		if (int(symmetry) == 0) { effectiveScale = scale * 0.5; }
		st = (st - 0.5) / effectiveScale;
		st = st + 0.5 + vec2(offsetX, offsetY);

		// Apply symmetry fold
		if (int(symmetry) == 0) {
			// mirrorXY
			st.x = mirrorFold(st.x);
			st.y = mirrorFold(st.y);
		} else if (int(symmetry) == 1) {
			// rotate2
			st = rotationalFold(fract2(st), 2);
		} else {
			// rotate4
			st = rotationalFold(fract2(st), 4);
		}
	}

	// Clamp to valid texture range
	st = clamp(st, vec2(0.0), vec2(1.0));

	frag = vec4(texture(inputTex, st).rgb, 1.0);
}
