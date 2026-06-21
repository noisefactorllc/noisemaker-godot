#version 450
// filter/scale — ported PIXEL-IDENTICALLY from wgsl/scale.wgsl. Scales the input's
// sample coordinates around an arbitrary center point, with a per-axis scale and a
// wrap mode (mirror / repeat / clamp). A COORD-RESAMPLING warp. Single render pass
// (progName "scale").
//
// No-layout effect (scale.json has no uniformLayout): the backend SYNTHESIZES the
// Params UBO and injects, after #version, a `#define <name> data[slot].comp` for
// every engine global and every param uniform. The injected param names are the
// globals' `uniform` fields (NOT their keys): scaleX, scaleY, centerX, centerY,
// wrap. (So unlike scroll/repeat, there is NO single-letter `x`/`y` macro collision
// here — the params are `scaleX`/`scaleY`.) We use the bare names directly and
// declare NO UBO / NO uniforms. Input texture bound at set 0, binding 1.
//
// COORDINATE NOTE: the WGSL uses `st = position.xy / resolution` and the runtime-
// bound `aspect` uniform. We port from WGSL (top-left, no Y-flip): UV =
// gl_FragCoord.xy / textureSize(inputTex). The injected `aspectRatio` global equals
// the WGSL `aspect` binding (both = width/height), so we read `aspectRatio` for it.
// The reference GLSL's extra tileOffset/fullResolution global-UV remapping is a
// tiling concern we do not reproduce (no Y-flip, no tile remap) — matches WGSL.
//
// `wrap` is an int param but arrives as a float component of `vec4 data[]`; narrow
// with int(). WGSL `%` on floats is floor-based modulo (a - b*floor(a/b)); GLSL
// `mod` is exactly that identity, so `%`→`mod`. No arithmetic reassociation.
layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

void main() {
	int wrapMode = int(wrap);

	vec2 texSize = vec2(textureSize(inputTex, 0));

	// WGSL: var st = position.xy / resolution;
	vec2 st = gl_FragCoord.xy / texSize;

	// WGSL: let center = vec2<f32>(-centerX, centerY); st -= center;
	vec2 center = vec2(-centerX, centerY);
	st -= center;

	// WGSL: st.x *= aspect;
	float aspect = aspectRatio;
	st.x *= aspect;

	// WGSL: st /= vec2<f32>(scaleX, scaleY);
	st /= vec2(scaleX, scaleY);

	// WGSL: st.x /= aspect;
	st.x /= aspect;

	// WGSL: st += center;
	st += center;

	// Apply wrap mode.
	if (wrapMode == 0) {
		// WGSL mirror: st = abs(((st + 1.0) % 2.0 + 2.0) % 2.0 - 1.0);
		st = abs(mod(mod(st + 1.0, vec2(2.0)) + 2.0, vec2(2.0)) - 1.0);
	} else if (wrapMode == 1) {
		// WGSL repeat: st = (st % 1.0 + 1.0) % 1.0;
		st = mod(mod(st, vec2(1.0)) + 1.0, vec2(1.0));
	} else {
		// WGSL clamp: st = clamp(st, vec2<f32>(0.0), vec2<f32>(1.0));
		st = clamp(st, vec2(0.0), vec2(1.0));
	}

	// WGSL: let color = textureSample(inputTex, samp, st).rgb; return vec4(color, 1.0);
	vec3 color = texture(inputTex, st).rgb;
	frag = vec4(color, 1.0);
}
