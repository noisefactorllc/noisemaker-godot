#version 450
// filter/temporalAberration — program "temporalAberration" (read pass). Ported from
// glsl/temporalAberration.glsl. Samples the live frame (delay 0) and the eight history
// stages h1..h8 (delay 1..8), then builds each output channel from an independently,
// fractionally-delayed frame so colour separates in time. Runs BEFORE the delayShift passes,
// so the history textures still hold last frame's values. An unwritten slot has alpha 0
// (zero-init) and falls back to the live frame, giving a clean ramp-in over the first frames.
//
// Layout effect: vec4 data[1] (effects/filter/temporalAberration.json, uniformLayouts):
//   redDelay = data[0].x, greenDelay = data[0].y, blueDelay = data[0].z.
// Inputs (pass.inputs): inputTex=1, h1=2, h2=3, h3=4, h4=5, h5=6, h6=7, h7=8, h8=9.
// gl_FragCoord top-left, +0.5 — NO Y-flip.
layout(set = 0, binding = 0, std140) uniform Params { vec4 data[1]; };
#define redDelay   data[0].x
#define greenDelay data[0].y
#define blueDelay  data[0].z

layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(set = 0, binding = 2) uniform sampler2D h1;
layout(set = 0, binding = 3) uniform sampler2D h2;
layout(set = 0, binding = 4) uniform sampler2D h3;
layout(set = 0, binding = 5) uniform sampler2D h4;
layout(set = 0, binding = 6) uniform sampler2D h5;
layout(set = 0, binding = 7) uniform sampler2D h6;
layout(set = 0, binding = 8) uniform sampler2D h7;
layout(set = 0, binding = 9) uniform sampler2D h8;

layout(location = 0) out vec4 fragColor;
layout(location = 0) in vec2 v_uv;

void main() {
	ivec2 texSize = textureSize(inputTex, 0);
	vec2 uv = gl_FragCoord.xy / vec2(texSize);

	vec4 cur = texture(inputTex, uv);

	// slots[0] = live (delay 0); slots[1..8] = history (delay 1..8) with empty -> live.
	vec4 slots[9];
	slots[0] = cur;
	vec4 s;
	s = texture(h1, uv); slots[1] = (s.a < 0.5) ? cur : s;
	s = texture(h2, uv); slots[2] = (s.a < 0.5) ? cur : s;
	s = texture(h3, uv); slots[3] = (s.a < 0.5) ? cur : s;
	s = texture(h4, uv); slots[4] = (s.a < 0.5) ? cur : s;
	s = texture(h5, uv); slots[5] = (s.a < 0.5) ? cur : s;
	s = texture(h6, uv); slots[6] = (s.a < 0.5) ? cur : s;
	s = texture(h7, uv); slots[7] = (s.a < 0.5) ? cur : s;
	s = texture(h8, uv); slots[8] = (s.a < 0.5) ? cur : s;

	float dr = clamp(redDelay, 0.0, 8.0);
	int ir0 = int(floor(dr));
	int ir1 = min(ir0 + 1, 8);
	float rOut = mix(slots[ir0], slots[ir1], dr - float(ir0)).r;

	float dg = clamp(greenDelay, 0.0, 8.0);
	int ig0 = int(floor(dg));
	int ig1 = min(ig0 + 1, 8);
	float gOut = mix(slots[ig0], slots[ig1], dg - float(ig0)).g;

	float db = clamp(blueDelay, 0.0, 8.0);
	int ib0 = int(floor(db));
	int ib1 = min(ib0 + 1, 8);
	float bOut = mix(slots[ib0], slots[ib1], db - float(ib0)).b;

	fragColor = vec4(rOut, gOut, bOut, cur.a);
}
