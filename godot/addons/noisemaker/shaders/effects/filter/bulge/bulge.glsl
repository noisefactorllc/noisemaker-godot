#version 450
// filter/bulge — ported PIXEL-IDENTICALLY from wgsl/bulge.wgsl. Radial bulge/pinch
// distortion around the center, with a pre/post rotation, a per-axis aspect lens,
// and a wrap mode (mirror / repeat / clamp). Optional 4x derivative supersample AA.
// Single render pass (progName "bulge").
//
// No-layout effect (bulge.json has no uniformLayout): the backend SYNTHESIZES the
// Params UBO and injects `#define <name> data[slot].comp` for the engine globals and
// every param uniform: strength, aspectLens, wrap, rotation, antialias. We use the
// bare names directly.
//
// ⚠️ RESERVED-NAME COLLISION: the WGSL's local/param `aspectRatio` collides with the
// injected `#define aspectRatio data[0].w` engine macro. Renamed to `ar` (a pure
// symbol rename, no behavior change) — the LOCAL aspect (texSize.x/texSize.y) is what
// the WGSL uses, NOT the engine aspectRatio. `aspectLens`/`antialias` are bool params
// arriving as float components → narrowed with `!= 0.0`. `wrap` int → int(wrap).
//
// COORDINATE NOTE: ported from WGSL (top-left, no Y-flip): uv = gl_FragCoord.xy /
// textureSize(inputTex), ar = texSize.x/texSize.y. The reference GLSL's
// tileOffset/fullResolution global-frame remap + fract() retiling is a tiling concern
// we do not reproduce (WGSL has none). WGSL `dpdx`/`dpdy` → GLSL `dFdx`/`dFdy`. WGSL
// float `%` (floor modulo) → GLSL `mod`. No arithmetic reassociation.
layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

#define BULGE_PI 3.14159265359

vec2 rotate2D(vec2 st, float rot, float ar) {
	st.x = st.x * ar;
	float angle = rot * BULGE_PI;
	st = st - vec2(0.5 * ar, 0.5);
	float c = cos(angle);
	float s = sin(angle);
	st = vec2(c * st.x - s * st.y, s * st.x + c * st.y);
	st = st + vec2(0.5 * ar, 0.5);
	st.x = st.x / ar;
	return st;
}

void main() {
	vec2 texSize = vec2(textureSize(inputTex, 0));
	float ar = texSize.x / texSize.y;
	vec2 uv = gl_FragCoord.xy / texSize;

	// Apply rotation before distortion.
	uv = rotate2D(uv, rotation / 180.0, ar);

	float intensity = strength * -0.01;

	uv = uv - 0.5;

	if (aspectLens != 0.0) {
		uv.x = uv.x * ar;
	}

	float r = length(uv);
	float effect = pow(r, 1.0 - intensity);
	uv = normalize(uv) * effect;

	if (aspectLens != 0.0) {
		uv.x = uv.x / ar;
	}

	uv = uv + 0.5;

	// Apply wrap mode.
	int wrapMode = int(wrap);
	if (wrapMode == 0) {
		// mirror
		uv = abs(mod(mod(uv + 1.0, 2.0) + 2.0, 2.0) - 1.0);
	} else if (wrapMode == 1) {
		// repeat
		uv = mod(mod(uv, 1.0) + 1.0, 1.0);
	} else {
		// clamp
		uv = clamp(uv, vec2(0.0), vec2(1.0));
	}

	// Reverse rotation after distortion.
	uv = rotate2D(uv, -rotation / 180.0, ar);

	if (antialias != 0.0) {
		// 4x supersample using distortion derivatives for adaptive spread.
		vec2 dx = dFdx(uv);
		vec2 dy = dFdy(uv);
		vec4 col = vec4(0.0);
		col += texture(inputTex, uv + dx * -0.375 + dy * -0.125);
		col += texture(inputTex, uv + dx *  0.125 + dy * -0.375);
		col += texture(inputTex, uv + dx *  0.375 + dy *  0.125);
		col += texture(inputTex, uv + dx * -0.125 + dy *  0.375);
		frag = col * 0.25;
	} else {
		frag = texture(inputTex, uv);
	}
}
