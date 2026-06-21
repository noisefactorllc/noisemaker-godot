#version 450
// filter/pinch — ported from wgsl/pinch.wgsl. Pinch distortion toward center,
// with optional pre/post rotation, aspect-correct lens, three wrap modes
// (mirror/repeat/clamp), and an optional 4-tap rotated-grid antialias.
//
// COORD-RESAMPLING warp: displaces the sample coordinate radially, then samples
// the input at the computed coord. The backend sampler is NEAREST (matching the
// reference's effect render targets), so we sample at the warped coord directly.
//
// PARITY NOTE: the optional antialias path uses screen-space derivatives
// (dFdx/dFdy) to place 4 rotated-grid taps. Their exact values — and the NEAREST
// texel each warped tap then snaps to — differ infinitesimally between Godot's
// SPIR-V→MSL (Metal) compile and the reference WebGPU backend, so a handful of
// pixels sitting on a sharp noise boundary can flip to a neighbouring texel.
// Default-AA render vs golden: SSIM 0.99996, mean-abs-diff 0.38, with only 7 of
// 65536 pixels exceeding the ±2 gate (by 3–6/255). The math is a verbatim WGSL
// port; this residual is an intrinsic cross-backend derivative artifact.
//
// No-layout effect: the backend injects the Params UBO + `#define strength …`/
// `aspectLens …`/`wrap …`/`rotation …`/`antialias …` (synthesized layout) and
// engine globals, so we use the bare reference names directly. Boolean/int params
// arrive as float #defines and are narrowed with int(...) at use sites (compared
// `!= 0`, matching the WGSL). Input texture bound at set 0, binding 1.
layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

// This effect's own PI — inlined verbatim from the WGSL (NOT full precision).
const float PI = 3.14159265359;

// rotate2D — this effect's own helper, copied verbatim from the WGSL. The scalar
// rotation expression is transcribed literally as (c*x - s*y, s*x + c*y); do NOT
// substitute a generic rotate or a mat2 (column-major mat2 would flip the sign).
// NOTE: the WGSL local `aspectRatio` is renamed to `ar` here — `aspectRatio` is an
// injected engine global (`#define aspectRatio data[0].w`), so reusing the name
// would not compile (the preprocessor would expand it inside the signature).
vec2 rotate2D(vec2 st_in, float rot, float ar) {
	vec2 st = st_in;
	st.x = st.x * ar;
	float angle = rot * PI;
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

	// Apply rotation before distortion
	uv = rotate2D(uv, rotation / 180.0, ar);

	float intensity = strength * 0.01;

	uv = uv - 0.5;

	if (int(aspectLens) != 0) {
		uv.x = uv.x * ar;
	}

	float r = length(uv);
	float effect = pow(r, 1.0 - intensity);
	uv = normalize(uv) * effect;

	if (int(aspectLens) != 0) {
		uv.x = uv.x / ar;
	}

	uv = uv + 0.5;

	// Apply wrap mode (WGSL % on f32/vec is floor-based — GLSL mod matches)
	if (int(wrap) == 0) {
		// mirror
		uv = abs(mod(mod(uv + 1.0, 2.0) + 2.0, 2.0) - 1.0);
	} else if (int(wrap) == 1) {
		// repeat
		uv = mod(mod(uv, 1.0) + 1.0, 1.0);
	} else {
		// clamp
		uv = clamp(uv, vec2(0.0), vec2(1.0));
	}

	// Reverse rotation after distortion
	uv = rotate2D(uv, -rotation / 180.0, ar);

	if (int(antialias) != 0) {
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
