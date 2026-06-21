#version 450
// filter/waves — ported PIXEL-IDENTICALLY from wgsl/waves.wgsl. Sine-wave vertical
// distortion of the sample coords, applied in a rotated frame, with a wrap mode and
// optional 4-tap antialias. A COORD-RESAMPLING warp. Single render pass (progName
// "waves").
//
// No-layout effect (waves.json has no uniformLayout): the backend SYNTHESIZES the
// Params UBO and injects `#define strength …`/`#define scale …`/`#define speed …`/
// `#define wrap …`/`#define rotation …`/`#define antialias …` (uniform fields) plus
// the engine `#define time …`. We use the bare names directly; NO UBO / NO uniforms.
// Input texture bound at set 0, binding 1.
//
// ⚠️ RESERVED/PARAM-NAME COLLISIONS: the WGSL aliases the params into locals
// (`let strength = uniforms.strength`, `let scale = …`, `let speed = …`, `let t =
// time`). Those would expand the injected `#define`s on the LHS of a declaration
// (`float scale = …`) → glslang error, so we DROP the aliases and use the bare
// injected names directly. Likewise the helper param `aspectRatio` is a RESERVED
// engine name → renamed to `ar` (pure symbol rename, no behavior change).
//
// COORDINATE NOTE: WGSL `uv = pos.xy / textureDimensions(inputTex)`,
// `aspectRatio = texSize.x / texSize.y`. gl_FragCoord is top-left (matches WGSL); NO
// Y-flip. int params (`speed`,`wrap`,`antialias`) arrive as float components of
// `vec4 data[]`: `float(speed)`, compare `wrap`/`antialias` `== 0.0`/`!= 0.0`.
// WGSL `%` floats → GLSL `mod`. PI/TAU verbatim. No arithmetic reassociation.
layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

const float PI = 3.14159265359;
const float TAU = 6.28318530718;

// rotate2D — verbatim from WGSL (param `aspectRatio` renamed `ar` to avoid the
// reserved-name macro collision).
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
	// WGSL: let texSize = vec2<f32>(textureDimensions(inputTex));
	vec2 texSize = vec2(textureSize(inputTex, 0));
	// WGSL: let aspectRatio = texSize.x / texSize.y;
	float ar = texSize.x / texSize.y;
	// WGSL: var uv = pos.xy / texSize;
	vec2 uv = gl_FragCoord.xy / texSize;

	// Apply rotation before distortion. WGSL: rotate2D(uv, uniforms.rotation/180, ar)
	uv = rotate2D(uv, rotation / 180.0, ar);

	// Sine wave distortion.
	// WGSL: uv.y = uv.y + sin(uv.x*scale*10 + t*TAU*f32(speed)) * (strength*0.01);
	uv.y = uv.y + sin(uv.x * scale * 10.0 + time * TAU * float(speed)) * (strength * 0.01);

	// Apply wrap mode.
	if (wrap == 0.0) {
		// mirror: uv = abs(((uv + 1.0) % 2.0 + 2.0) % 2.0 - 1.0);
		uv = abs(mod(mod(uv + 1.0, vec2(2.0)) + 2.0, vec2(2.0)) - 1.0);
	} else if (wrap == 1.0) {
		// repeat: uv = (uv % 1.0 + 1.0) % 1.0;
		uv = mod(mod(uv, vec2(1.0)) + 1.0, vec2(1.0));
	} else {
		// clamp: uv = clamp(uv, vec2<f32>(0.0), vec2<f32>(1.0));
		uv = clamp(uv, vec2(0.0), vec2(1.0));
	}

	// Reverse rotation after distortion.
	uv = rotate2D(uv, -rotation / 180.0, ar);

	if (antialias != 0.0) {
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
