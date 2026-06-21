#version 450
// filter/repeat — ported from wgsl/repeat.wgsl. Tiles/repeats the input texture
// across the screen with configurable repeat count, offset, and wrap mode
// (mirror / repeat / clamp). COORD-RESAMPLING via fract/mod on the sample coord.
//
// No-layout effect (repeat.json has no uniformLayout): the backend injects the
// Params UBO + `#define x …`/`#define y …`/`#define offsetX …`/`#define offsetY …`/
// `#define wrap …` (synthesized layout) and engine globals, so we use the bare
// reference names directly. Input texture bound at set 0, binding 1.
//
// IMPORTANT — macro re-expansion collision. The backend's synthesized layout names
// two params `x` and `y` (`#define x data[3].x`, `#define y data[3].y`). When ANOTHER
// injected macro expands to a component ending in `.x`/`.y` (here `#define wrap
// data[4].x`), the C preprocessor re-scans that result and expands the trailing `x`
// token via the `x` macro, yielding `data[4].data[3].x` and a parse error. (`x`/`y`
// themselves are safe — a macro is not re-expanded inside its own expansion.) To
// reference `wrap` safely we capture `x`/`y` into real locals first, then `#undef`
// the `x`/`y` macros so no further re-expansion can occur.
//
// Also: never write a `.x`/`.y` vector swizzle while the macros are live, as that
// `x`/`y` token would be macro-expanded into the swizzle. We use component indexing
// (`st[0]`/`st[1]`) instead. The multi-letter swizzles `.xy`/`.rgb` are single tokens
// (`xy`, `rgb`), distinct from the `x`/`y` macros, so those remain safe.
//
// Coordinate derivation: WGSL `st = position.xy / resolution`. The HLSL cross-check
// notes `position.xy / resolution == i.uv` (NM_FragCoord = uv * resolution), so the
// Godot equivalent is `gl_FragCoord.xy / textureSize(inputTex)`. WGSL `aspect` is
// bound from fullResolution.x/y — identical to the injected `aspectRatio` global.
//
// WGSL `%` on floats is floor-based modulo (a - b*floor(a/b)) — GLSL `mod` is exactly
// that identity, so `%`→`mod`. The backend sampler is NEAREST. No Y-flip.
layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

void main() {
	// Capture the `x`/`y`/`wrap` param macros into real locals while they expand
	// cleanly, then drop the `x`/`y` macros (see header note on re-expansion).
	float repX = x;
	float repY = y;
#undef x
#undef y
	// `wrap` is an int param, but the synthesized UBO stores it as a float
	// component (vec4 data[]); narrow with int() like other no-layout ports.
	int wrapMode = int(wrap);

	vec2 texSize = vec2(textureSize(inputTex, 0));

	// WGSL: var st = position.xy / resolution;
	vec2 st = gl_FragCoord.xy / texSize;

	// WGSL: st.x = st.x * aspect;
	float aspect = aspectRatio;
	st[0] = st[0] * aspect;

	// WGSL: st = st * vec2<f32>(x, y) + vec2<f32>(offsetX * aspect, offsetY);
	st = st * vec2(repX, repY) + vec2(offsetX * aspect, offsetY);

	// WGSL: st.x = st.x / aspect;
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

	// WGSL: return vec4<f32>(textureSample(inputTex, samp, st).rgb, 1.0);
	frag = vec4(texture(inputTex, st).rgb, 1.0);
}
