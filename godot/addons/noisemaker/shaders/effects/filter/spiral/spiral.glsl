#version 450
// filter/spiral — ported PIXEL-IDENTICALLY from wgsl/spiral.wgsl. Polar spiral
// distortion of the sample coords (rotation-framed, optional aspect lens), with a
// wrap mode and optional 4-tap antialias. A COORD-RESAMPLING warp. Single render
// pass (progName "spiral").
//
// No-layout effect (spiral.json has no uniformLayout): the backend SYNTHESIZES the
// Params UBO and injects `#define strength …`/`#define speed …`/`#define aspectLens
// …`/`#define wrap …`/`#define rotation …`/`#define antialias …` (uniform fields)
// plus the engine `#define time …`. Bare names; NO UBO / NO uniforms. Input texture
// bound at set 0, binding 1.
//
// ⚠️ RESERVED/PARAM-NAME COLLISIONS: the WGSL aliases params into locals
// (`let strength = …`, `let speed = …`, `let t = time`) — those expand the injected
// `#define`s on a declaration LHS → glslang error, so we DROP the aliases and use the
// bare injected names. The helper param `aspectRatio` is a RESERVED engine name →
// renamed `ar` (pure symbol rename).
//
// COORDINATE NOTE: WGSL `uv = pos.xy / textureDimensions(inputTex)`,
// `aspectRatio = texSize.x/texSize.y`. gl_FragCoord top-left (matches WGSL); NO
// Y-flip. int params (`speed`,`aspectLens`,`wrap`,`antialias`) arrive as float
// components: `float(speed)`, compare flags `!= 0.0`/`== 0.0`. atan2→atan (arg order
// copied literally). textureSampleLevel(…,0.0)→texture(). WGSL `%` floats→GLSL `mod`.
// PI/TAU verbatim. No arithmetic reassociation.
layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

const float PI = 3.14159265359;
const float TAU = 6.28318530718;

// rotate2D — verbatim from WGSL (param `aspectRatio` renamed `ar`).
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

	// Apply rotation before distortion.
	uv = rotate2D(uv, rotation / 180.0, ar);

	uv = uv - 0.5;

	if (aspectLens != 0.0) {
		uv.x = uv.x * ar;
	}

	// Convert to polar coordinates. WGSL: r = length(uv); a = atan2(uv.y, uv.x);
	float r = length(uv);
	float a = atan(uv.y, uv.x);

	// Apply spiral distortion.
	// WGSL: spiralAmt = (strength*0.05)*r; a = a + spiralAmt - (t*TAU*f32(speed)*sign(strength));
	float spiralAmt = (strength * 0.05) * r;
	a = a + spiralAmt - (time * TAU * float(speed) * sign(strength));

	// Convert back to cartesian coordinates. WGSL: uv = vec2(cos(a), sin(a)) * r;
	uv = vec2(cos(a), sin(a)) * r;

	if (aspectLens != 0.0) {
		uv.x = uv.x / ar;
	}

	uv = uv + 0.5;

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
