#version 450
// synth/navierStokes — program "nsSplat" (external-force / source pass). Ported from
// glsl/nsSplat.glsl (the webgl2 golden source; the WGSL textureLoad variant is numerically
// identical here because the backend binds state surfaces NEAREST + clamp-to-edge, so a
// texture() at a texel center fetches that exact texel). On first frame (state alpha == 0)
// or resetState, seeds NUM_INIT_VORTICES coherent vortex blobs + matching dye. Otherwise
// the input-texture luminance gradient drives a continuous force and brightness adds dye.
// State is rgba16f so velocity is stored unencoded in R,G; dye in B; alpha == 1 marks
// "initialized". NO deltaTime engine global — dt is derived from speed (speed*0.0001).
//
// Layout effect: vec4 data[2] (effects/synth/navierStokes.json, uniformLayouts.nsSplat):
//   resolution = data[0].xy, seed = data[0].w, speed = data[1].x, inputForce = data[1].y,
//   inputDye = data[1].z, resetState = data[1].w.
// Inputs (pass.inputs order): bufTex = binding 1 (read state), inputTex = binding 2 (source).
// gl_FragCoord top-left, +0.5 — NO Y-flip.
#include "include/nm_core.glsl"

layout(set = 0, binding = 0, std140) uniform Params { vec4 data[2]; };
layout(set = 0, binding = 1) uniform sampler2D bufTex;
layout(set = 0, binding = 2) uniform sampler2D inputTex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

#define NUM_INIT_VORTICES 9

float hash11(float x) {
	return fract(sin(x * 12.9898) * 43758.5453);
}

vec2 hash22(vec2 p) {
	p = vec2(dot(p, vec2(127.1, 311.7)), dot(p, vec2(269.5, 183.3)));
	return fract(sin(p) * 43758.5453);
}

float lum(vec3 c) {
	return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b;
}

void main() {
	float seed = data[0].w;
	float speed = data[1].x;
	float inputForce = data[1].y;
	float inputDye = data[1].z;
	bool resetState = data[1].w > 0.5;

	ivec2 texSize = textureSize(bufTex, 0);
	vec2 fragCoord = gl_FragCoord.xy;
	vec2 uv = fragCoord / vec2(texSize);

	vec4 prev = texture(bufTex, uv);

	// First-frame buffer is all zeros (alpha initialized to 0 by the runtime). Seed initial
	// conditions on the first frame OR when the user hits reset.
	bool bufferEmpty = (prev.a == 0.0);
	if (resetState || bufferEmpty) {
		vec2 vel = vec2(0.0);
		float dye = 0.0;
		float seedF = seed;
		for (int i = 0; i < NUM_INIT_VORTICES; i++) {
			float idf = float(i);
			vec2 c = hash22(vec2(idf * 7.31 + 1.0, seedF * 13.7 + idf));
			float vsign = hash11(idf * 4.17 + seedF * 5.9) > 0.5 ? 1.0 : -1.0;
			float radius = 0.10 + 0.06 * hash11(idf * 2.11 + seedF);

			vec2 d = uv - c;
			float r2 = dot(d, d);
			float falloff = exp(-r2 / (2.0 * radius * radius));
			// Tangential velocity: rotate radial vector 90 degrees, scale by Gaussian envelope.
			vec2 tangent = vec2(-d.y, d.x);
			vel += tangent * vsign * falloff * 12.0;
			dye += falloff;
		}
		// A=1.0 marks "buffer initialized".
		frag = vec4(vel, clamp(dye, 0.0, 1.0), 1.0);
		return;
	}

	vec2 vel = prev.rg;
	float dye = prev.b;

	float dt = clamp(speed, 0.0, 200.0) * 0.0001;

	// Input-texture-driven additions.
	float iForce = clamp(inputForce, 0.0, 100.0) * 0.01;
	float iDye = clamp(inputDye, 0.0, 100.0) * 0.01;
	if (iForce > 0.0 || iDye > 0.0) {
		vec2 texel = 1.0 / vec2(texSize);
		float lc = lum(texture(inputTex, uv).rgb);
		float lr = lum(texture(inputTex, uv + vec2(texel.x, 0.0)).rgb);
		float lu = lum(texture(inputTex, uv + vec2(0.0, texel.y)).rgb);
		vec2 grad = vec2(lr - lc, lu - lc);
		vel += grad * iForce * 50.0;
		dye += lc * iDye * dt * 60.0;
	}

	dye = clamp(dye, 0.0, 2.0);

	frag = vec4(vel, dye, 1.0);
}
