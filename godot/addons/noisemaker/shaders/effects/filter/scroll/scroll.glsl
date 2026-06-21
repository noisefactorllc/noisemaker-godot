#version 450
// filter/scroll — ported from wgsl/scroll.wgsl. Scrolls the input texture's sample
// coordinates over time with a configurable per-axis offset/speed and wrap mode
// (mirror / repeat / clamp). COORD-RESAMPLING via fract/mod on the sample coord.
//
// No-layout effect (scroll.json has no uniformLayout): the backend injects the
// Params UBO + `#define x …`/`#define y …`/`#define speedX …`/`#define speedY …`/
// `#define wrap …` (synthesized layout) and engine globals, so we use the bare
// reference names directly. Input texture bound at set 0, binding 1.
//
// IMPORTANT — single-letter `x`/`y` macro collision (same case as repeat.glsl).
// The backend's synthesized layout names two params `x` and `y` (`#define x
// data[?].x`, `#define y data[?].y`). When ANOTHER injected macro expands to a
// component ending in `.x`/`.y` (here `#define wrap data[?].x`), the C
// preprocessor re-scans that result and expands the trailing `x` token via the
// `x` macro, yielding `data[?].data[?].x` and a parse error. (`x`/`y` themselves
// are safe — a macro is not re-expanded inside its own expansion.) To reference
// `wrap` safely, and to write `.x`/`.y` swizzles without corruption, we capture
// `x`/`y` (and the other scalars we need) into real locals at the TOP of main(),
// then `#undef` the `x`/`y` macros so no further re-expansion can occur. We index
// vectors by component (`st[0]`/`st[1]`) to stay collision-proof while building
// the offset, then reference `wrap` (int) only after the `#undef`.
//
// Coordinate derivation: WGSL `st = position.xy / resolution`. The HLSL cross-check
// notes `position.xy / resolution == i.uv` (NM_FragCoord = uv * resolution), so the
// Godot equivalent is `gl_FragCoord.xy / textureSize(inputTex)`. WGSL `aspect` is
// bound from fullResolution.x/y — identical to the injected `aspectRatio` global.
//
// WGSL `%` on floats is floor-based modulo (a - b*floor(a/b)) — GLSL `mod` is exactly
// that identity, so `%`→`mod`. WGSL `textureSampleLevel(…, 0.0)` → `texture()` (the
// backend sampler is NEAREST, single mip). No Y-flip.
layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

void main() {
	// Capture the single-letter `x`/`y` param macros (and the scalars used to
	// build the offset) into real locals while they expand cleanly, then drop the
	// `x`/`y` macros (see header note on re-expansion).
	float sx = x;
	float sy = y;
	float sSpeedX = speedX;
	float sSpeedY = speedY;
	float sTime = time;
#undef x
#undef y
	// `wrap` is an int param, but the synthesized UBO stores it as a float
	// component (vec4 data[]); narrow with int() like other no-layout ports.
	int wrapMode = int(wrap);

	vec2 texSize = vec2(textureSize(inputTex, 0));

	// WGSL: var st = position.xy / resolution;
	vec2 st = gl_FragCoord.xy / texSize;

	// WGSL: st.x *= aspect;
	float aspect = aspectRatio;
	st[0] = st[0] * aspect;

	// WGSL: var offset = vec2<f32>(-x + time * -speedX, y + time * speedY);
	vec2 offset = vec2(-sx + sTime * -sSpeedX, sy + sTime * sSpeedY);

	// WGSL: offset.x *= aspect;
	offset[0] = offset[0] * aspect;

	// WGSL: st += offset;
	st = st + offset;

	// WGSL: st.x /= aspect;
	st[0] = st[0] / aspect;

	// Apply wrap mode
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

	// WGSL: let color = textureSampleLevel(inputTex, samp, st, 0.0).rgb;
	//       return vec4<f32>(color, 1.0);
	vec3 color = texture(inputTex, st).rgb;
	frag = vec4(color, 1.0);
}
