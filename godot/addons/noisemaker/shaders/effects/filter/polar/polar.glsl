#version 450
// filter/polar — ported PIXEL-IDENTICALLY from wgsl/polar.wgsl.
// Polar and vortex coordinate transforms (a COORD-RESAMPLING warp: maps fragCoord
// to polar/rotated coords, then samples the input there). Single render pass
// (progName "polar").
//
// No-layout effect (polar.json has no uniformLayout): the backend SYNTHESIZES the
// Params UBO and injects, after #version, a `#define <name> data[slot].comp` for
// every engine global and every param uniform. So we use the bare names directly
// and declare NO UBO and NO uniforms. The input texture is bound at set 0, binding 1
// (pass.inputs order). No shared nm_core primitives are used, so nm_core.glsl is NOT
// included.
//
// COORDINATE NOTE: this is a filter — WGSL samples uv = pos.xy / textureDimensions
// (inputTex), i.e. divides by the INPUT TEXTURE size (NOT fullResolution).
// We use textureSize(inputTex, 0). gl_FragCoord is top-left (matches WGSL); NO Y-flip.
//
// SAMPLING NOTE: the backend's sampler for effect targets is NEAREST (matches the
// reference). This is a coord-resampling warp, so we sample at the computed coord
// directly — no texel snapping.
//
// TRANSLATION HAZARDS:
//  * atan2(uv.y, uv.x) -> atan(uv.y, uv.x) — WGSL arg order copied literally.
//  * dpdx/dpdy -> dFdx/dFdy (screen-space derivatives of the warped coord).
//  * textureSample(t, s, c) -> texture(t, c); textureDimensions(t) -> textureSize(t, 0).
//  * The synthesized layout maps EVERY param #define to a scalar float component of
//    `vec4 data[]` (booleans -> 1.0/0.0, ints -> float(v)). So polarMode/aspectLens/
//    antialias arrive as floats: test `== 0.0` / `!= 0.0`. rotation/speed arrive as
//    floats too and are used directly (the WGSL struct holds them as f32 anyway).
//  * smod1 helper is this effect's OWN; copied verbatim (NOT nm_core).
//  * TAU constant: 6.28318530718 (verbatim from WGSL). No arithmetic reassociation.
layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

const float TAU = 6.28318530718;

// smod1 — verbatim from WGSL `smod1(v, m)`.
// WGSL: return m * (0.75 - abs(fract(v) - 0.5) - 0.25);
float smod1(float v, float m) {
	return m * (0.75 - abs(fract(v) - 0.5) - 0.25);
}

// polarCoords — verbatim from WGSL.
//   var uv = uvIn - 0.5;
//   if (doAspect) { uv.x = uv.x * aspect; }
//   var coord = vec2<f32>(atan2(uv.y, uv.x) / TAU + 0.5, length(uv) - uniforms.scale * 0.075);
//   coord.x = smod1(coord.x + uniforms.time * -uniforms.rotation, 1.0);
//   coord.y = smod1(coord.y + uniforms.time *  uniforms.speed,    1.0);
//   return coord;
vec2 polarCoords(vec2 uvIn, float aspect, bool doAspect) {
	vec2 uv = uvIn - 0.5;
	if (doAspect) { uv.x = uv.x * aspect; }
	vec2 coord = vec2(atan(uv.y, uv.x) / TAU + 0.5, length(uv) - scale * 0.075);
	coord.x = smod1(coord.x + time * -rotation, 1.0);
	coord.y = smod1(coord.y + time * speed, 1.0);
	return coord;
}

// vortexCoords — verbatim from WGSL.
//   var uv = uvIn - 0.5;
//   if (doAspect) { uv.x = uv.x * aspect; }
//   let r2 = dot(uv, uv) - uniforms.scale * 0.01;
//   uv = uv / r2;
//   uv.x = smod1(uv.x + uniforms.time * -uniforms.rotation, 1.0);
//   uv.y = smod1(uv.y + uniforms.time *  uniforms.speed,    1.0);
//   return uv;
vec2 vortexCoords(vec2 uvIn, float aspect, bool doAspect) {
	vec2 uv = uvIn - 0.5;
	if (doAspect) { uv.x = uv.x * aspect; }
	float r2 = dot(uv, uv) - scale * 0.01;
	uv = uv / r2;
	uv.x = smod1(uv.x + time * -rotation, 1.0);
	uv.y = smod1(uv.y + time * speed, 1.0);
	return uv;
}

void main() {
	vec2 texSize = vec2(textureSize(inputTex, 0));
	vec2 uv = gl_FragCoord.xy / texSize;
	float aspect = texSize.x / texSize.y;
	bool doAspect = aspectLens != 0.0;

	vec2 coord;
	if (polarMode == 0.0) {
		coord = polarCoords(uv, aspect, doAspect);
	} else {
		coord = vortexCoords(uv, aspect, doAspect);
	}

	if (antialias != 0.0) {
		vec2 dx = dFdx(coord);
		vec2 dy = dFdy(coord);
		vec4 col = vec4(0.0);
		col += texture(inputTex, coord + dx * -0.375 + dy * -0.125);
		col += texture(inputTex, coord + dx *  0.125 + dy * -0.375);
		col += texture(inputTex, coord + dx *  0.375 + dy *  0.125);
		col += texture(inputTex, coord + dx * -0.125 + dy *  0.375);
		frag = col * 0.25;
	} else {
		frag = texture(inputTex, coord);
	}
}
