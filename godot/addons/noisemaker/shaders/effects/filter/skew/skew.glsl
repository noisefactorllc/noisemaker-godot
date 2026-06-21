#version 450
// filter/skew — ported PIXEL-IDENTICALLY from wgsl/skew.wgsl. Rotates then skews the
// input's sample coordinates about the center, aspect-corrected, with a wrap mode
// (clamp / mirror / repeat). A COORD-RESAMPLING warp. Single render pass (progName
// "skew").
//
// No-layout effect (skew.json has no uniformLayout): the backend SYNTHESIZES the
// Params UBO and injects `#define skewAmt …`/`#define rotation …`/`#define wrap …`
// (uniform fields; + engine globals). We use the bare names directly and declare NO
// UBO / NO uniforms. Input texture bound at set 0, binding 1.
//
// COORDINATE NOTE: WGSL `st = pos.xy / textureDimensions(inputTex)` and
// `aspect = texSize.x / texSize.y`. gl_FragCoord is top-left (matches WGSL); NO
// Y-flip. The reference GLSL adds a tileOffset/fullResolution global-UV remap AND a
// `maxSkew = 512/fullResolution.y` clamp on skewAmt — those are tiling concerns we do
// NOT reproduce (we port the WGSL, which does neither).
//
// `wrap` is an int param arriving as a float component of `vec4 data[]`; narrow with
// int(). The rotation is reproduced literally as `vec2(c*st.x - s*st.y, s*st.x +
// c*st.y)` (NOT the GLSL's mat2 form) — same result, no reassociation. `s`/`c` are
// local variables (no param of that name), so no macro collision. PI verbatim from
// WGSL. WGSL `%` on floats → GLSL `mod` (same floor-modulo identity).
layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

const float PI = 3.14159265359;

void main() {
	// WGSL: let texSize = vec2<f32>(textureDimensions(inputTex));
	vec2 texSize = vec2(textureSize(inputTex, 0));
	// WGSL: var st = pos.xy / texSize;
	vec2 st = gl_FragCoord.xy / texSize;
	// WGSL: let aspect = texSize.x / texSize.y;
	float aspect = texSize.x / texSize.y;

	// WGSL: st = st - 0.5; st.x = st.x * aspect;
	st = st - 0.5;
	st.x = st.x * aspect;

	// WGSL: let angle = u.rotation * PI / 180.0; c = cos; s = sin;
	float angle = rotation * PI / 180.0;
	float c = cos(angle);
	float s = sin(angle);
	// WGSL: st = vec2<f32>(c * st.x - s * st.y, s * st.x + c * st.y);
	st = vec2(c * st.x - s * st.y, s * st.x + c * st.y);

	// WGSL: st.x = st.x + st.y * -u.skewAmt;
	st.x = st.x + st.y * -skewAmt;

	// WGSL: st.x = st.x / aspect; st = st + 0.5;
	st.x = st.x / aspect;
	st = st + 0.5;

	// Wrap mode. WGSL: let wrapMode = i32(u.wrap);
	int wrapMode = int(wrap);
	if (wrapMode == 0) {
		// clamp: st = clamp(st, vec2<f32>(0.0), vec2<f32>(1.0));
		st = clamp(st, vec2(0.0), vec2(1.0));
	} else if (wrapMode == 1) {
		// mirror: st = abs(((st + 1.0) % 2.0 + 2.0) % 2.0 - 1.0);
		st = abs(mod(mod(st + 1.0, vec2(2.0)) + 2.0, vec2(2.0)) - 1.0);
	} else {
		// repeat: st = (st % 1.0 + 1.0) % 1.0;
		st = mod(mod(st, vec2(1.0)) + 1.0, vec2(1.0));
	}

	// WGSL: return textureSample(inputTex, inputSampler, st);
	frag = texture(inputTex, st);
}
