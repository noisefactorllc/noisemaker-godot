#version 450
// filter/translate — ported from wgsl/translate.wgsl. Shifts the input texture
// in X and Y by the `x`/`y` params, then applies a wrap mode (mirror / repeat /
// clamp) to the sample coordinate. COORD-RESAMPLING via fract/mod on the uv.
//
// No-layout effect (translate.json has no uniformLayout): the backend injects the
// Params UBO + `#define x …`/`#define y …`/`#define wrap …` (synthesized layout)
// and engine globals, so we use the bare reference names directly. Input texture
// bound at set 0, binding 1.
//
// IMPORTANT — macro re-expansion collision. The backend's synthesized layout names
// two params `x` and `y` (`#define x data[0].x`, `#define y data[0].y`). When ANOTHER
// injected macro expands to a component ending in `.x`/`.y` (here `#define wrap
// data[N].x`), the C preprocessor re-scans that result and expands the trailing `x`
// token via the `x` macro, yielding `data[N].data[0].x` and a parse error. (`x`/`y`
// themselves are safe — a macro is not re-expanded inside its own expansion.) To
// reference `wrap` safely we capture `x`/`y` into real locals first, then `#undef`
// the `x`/`y` macros so no further re-expansion can occur.
//
// Also: never write a `.x`/`.y` vector swizzle while the macros are live, as that
// `x`/`y` token would be macro-expanded into the swizzle. After the `#undef` we use
// `.x`/`.y` normally. The multi-letter swizzles `.xy`/`.rgb` are single tokens
// (`xy`, `rgb`), distinct from the `x`/`y` macros, so those remain safe regardless.
//
// Coordinate derivation: WGSL `uv = pos.xy / texSize` where `texSize =
// textureDimensions(inputTex)`. `pos` is `@builtin(position)` → `gl_FragCoord`
// (top-left, +0.5 — matches WGSL). The Godot equivalent is `gl_FragCoord.xy /
// textureSize(inputTex, 0)`.
//
// WGSL `%` on floats is floor-based modulo (a - b*floor(a/b)) — GLSL `mod` is exactly
// that identity, so `%`→`mod`. The backend sampler is NEAREST. No Y-flip.
layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

void main() {
	// Capture the `x`/`y` param macros into real locals while they expand cleanly,
	// then drop the `x`/`y` macros (see header note on re-expansion).
	float tx = x;
	float ty = y;
#undef x
#undef y
	// `wrap` is an int param, but the synthesized UBO stores it as a float
	// component (vec4 data[]); narrow with int() like other no-layout ports.
	// Referenced only AFTER the #undef so its trailing `.x` cannot re-expand.
	int wrapMode = int(wrap);

	// WGSL: let texSize = vec2<f32>(textureDimensions(inputTex));
	vec2 texSize = vec2(textureSize(inputTex, 0));

	// WGSL: var uv = pos.xy / texSize;
	vec2 uv = gl_FragCoord.xy / texSize;

	// Apply translation
	// WGSL: uv.x = uv.x - uniforms.x;
	uv.x = uv.x - tx;
	// WGSL: uv.y = uv.y - uniforms.y;
	uv.y = uv.y - ty;

	// Apply wrap mode
	if (wrapMode == 0) {
		// WGSL mirror: uv = abs(((uv + 1.0) % 2.0 + 2.0) % 2.0 - 1.0);
		uv = abs(mod(mod(uv + 1.0, vec2(2.0)) + 2.0, vec2(2.0)) - 1.0);
	} else if (wrapMode == 1) {
		// WGSL repeat: uv = (uv % 1.0 + 1.0) % 1.0;
		uv = mod(mod(uv, vec2(1.0)) + 1.0, vec2(1.0));
	} else {
		// WGSL clamp: uv = clamp(uv, vec2<f32>(0.0), vec2<f32>(1.0));
		uv = clamp(uv, vec2(0.0), vec2(1.0));
	}

	// WGSL: return textureSample(inputTex, inputSampler, uv);
	frag = texture(inputTex, uv);
}
