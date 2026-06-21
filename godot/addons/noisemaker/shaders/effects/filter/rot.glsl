#version 450
// filter/rotate — ported PIXEL-IDENTICALLY from wgsl/rot.wgsl.
// Rotate image 0..1 (0..360 degrees). A COORD-RESAMPLING warp: maps fragCoord to a
// centered/aspect-corrected/rotated uv, applies a wrap mode, then samples the input
// there. Single render pass (progName "rot").
//
// No-layout effect (rotate.json has no uniformLayout): the backend SYNTHESIZES the
// Params UBO and injects, after #version, a `#define <name> data[slot].comp` for
// every engine global and every param uniform. So we use the bare names directly
// (rotation, wrap, speed, time) and declare NO UBO and NO uniforms. The input texture
// is bound at set 0, binding 1 (pass.inputs order). No shared nm_core primitives are
// used, so nm_core.glsl is NOT included.
//
// COORDINATE NOTE: this is a filter — WGSL samples uv = pos.xy / textureDimensions
// (inputTex), i.e. divides by the INPUT TEXTURE size (NOT fullResolution). We use
// textureSize(inputTex, 0). gl_FragCoord is top-left (matches WGSL); NO Y-flip.
//
// SAMPLING NOTE: the backend's sampler for effect targets is NEAREST (matches the
// reference). This is a coord-resampling warp, so we sample at the computed coord
// directly — no texel snapping, no added interpolation.
//
// TRANSLATION HAZARDS:
//  * The synthesized layout maps EVERY param #define to a scalar float component of
//    `vec4 data[]` (ints -> float(v)). So wrap and speed arrive as floats; the WGSL
//    treats them as i32, so we wrap int() at the integer compare/cast sites
//    (int(wrap), int(speed)) to reproduce the integer semantics exactly. rotation and
//    time arrive as floats and are used directly (the WGSL struct holds them as f32).
//  * textureSample(t, s, uv) -> texture(t, uv); textureDimensions(t) -> textureSize(t, 0).
//  * rotate2D mat2x2<f32>(c, -s, s, c) -> mat2(c, -s, s, c) (both column-major; M*v same).
//  * TAU constant: 6.283185307179586 (verbatim from WGSL). No arithmetic reassociation.
layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

const float TAU = 6.283185307179586;

// rotate2D — verbatim from WGSL.
//   let c = cos(angle);
//   let s = sin(angle);
//   return mat2x2<f32>(c, -s, s, c);
mat2 rotate2D(float angle) {
	float c = cos(angle);
	float s = sin(angle);
	return mat2(c, -s, s, c);
}

void main() {
	vec2 texSize = vec2(textureSize(inputTex, 0));
	vec2 uv = gl_FragCoord.xy / texSize;

	// Animate rotation: full continuous rotation
	float angle = rotation;
	if (int(speed) != 0) {
		angle = angle + time * 360.0 * float(int(speed));
	}

	// Center, correct aspect, rotate, uncorrect, uncenter
	float aspect = texSize.x / texSize.y;
	vec2 center = vec2(0.5);
	uv -= center;
	uv.x = uv.x * aspect;
	uv = rotate2D(-angle * TAU / 360.0) * uv;
	uv.x = uv.x / aspect;
	uv += center;

	// Apply wrap mode. WGSL float `%` is floor-based modulo (a - b*floor(a/b)) and
	// GLSL `mod` is exactly that identity, so `%`->`mod` (matches filter/repeat.glsl,
	// which ports this same wrap idiom). The double-mod-with-offset keeps uv positive.
	if (int(wrap) == 0) {
		// WGSL mirror: uv = abs(((uv + 1.0) % 2.0 + 2.0) % 2.0 - 1.0);
		uv = abs(mod(mod(uv + 1.0, vec2(2.0)) + 2.0, vec2(2.0)) - 1.0);
	} else if (int(wrap) == 1) {
		// WGSL repeat: uv = (uv % 1.0 + 1.0) % 1.0;
		uv = mod(mod(uv, vec2(1.0)) + 1.0, vec2(1.0));
	} else {
		// WGSL clamp: uv = clamp(uv, vec2<f32>(0.0), vec2<f32>(1.0));
		uv = clamp(uv, vec2(0.0), vec2(1.0));
	}

	frag = texture(inputTex, uv);
}
