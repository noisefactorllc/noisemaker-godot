#version 450
// synth/mnca — program "mncaFb" (the multi-neighbourhood update / feedback pass).
// Ported from wgsl/mncaFb.wgsl (cross-checked against the golden glsl/mncaFb.glsl).
// Advances the ping-pong state buffer one MNCA generation: averages two concentric
// neighbourhoods (a circle r=3 and a ring inner r=4 / outer r=7) with texelFetch
// (integer coords — no filtering, NEAREST state sampler), maps the two averages
// through six UI threshold windows, optionally luminance-blends a seed surface, and
// seeds a random board when the buffer is empty (all four channels zero) or resetState.
//
// SINGLE shared layout: vec4 data[6] (effects/synth/mnca.json uniformLayout, max slot 5).
//   slot0: resolution.xy, time.z, deltaTime.w
//   slot1: speed.x, smoothing.y, weight.z, seed.w
//   slot2: resetState.x, n1v1.y, n1r1.z, n1v2.w
//   slot3: n1r2.x, n1v3.y, n1r3.z, n1v4.w
//   slot4: n1r4.x, n2v1.y, n2r1.z, n2v2.w
//   slot5: n2r2.x
//
// Inputs (pass.inputs order): bufTex = binding 1 (the read buffer, integer-fetched),
// seedTex = binding 2 (optional previous-frame surface for luminance perturbation;
// bound to a black texture when "none"). gl_FragCoord is top-left/+0.5 like the WGSL
// @position — NO Y-flip (single global flip at present). The state grid is sub-
// resolution (screenDivide zoom), so all geometry uses textureSize(bufTex), never the
// screen.
//
// NOTE on pinned-time parity: at the pinned capture deltaTime == 0, so the final mix()
// collapses to currentState — the board freezes at the frame-0 random seed. The rule
// evaluation is still ported verbatim (correctness off the pinned path + the shader
// compiles whole).
layout(set = 0, binding = 0, std140) uniform Params { vec4 data[6]; };
layout(set = 0, binding = 1) uniform sampler2D bufTex;
layout(set = 0, binding = 2) uniform sampler2D seedTex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

float map(float value, float inMin, float inMax, float outMin, float outMax) {
	return outMin + (outMax - outMin) * (value - inMin) / (inMax - inMin);
}

float lum(vec3 color) {
	return 0.2126 * color.r + 0.7152 * color.g + 0.0722 * color.b;
}

float random(vec2 st) {
	return fract(sin(dot(st, vec2(12.9898, 78.233))) * 43758.5453123);
}

// Clamp a texel coordinate to the valid texture bounds.
ivec2 clampCoord(ivec2 p, ivec2 size) {
	int cx = clamp(p.x, 0, size.x - 1);
	int cy = clamp(p.y, 0, size.y - 1);
	return ivec2(cx, cy);
}

// Fetch a single cell value with integer coords to avoid any filtering.
float cellAt(ivec2 base, ivec2 offset, ivec2 size) {
	ivec2 pc = clampCoord(base + offset, size);
	return texelFetch(bufTex, pc, 0).r;
}

// Neighbourhood 1 = circle with r = 3 (36 cells).
float neighborsAvgCircle(ivec2 base, ivec2 size) {
	float total = 0.0;
	for (int y = -3; y <= 3; y++) {
		for (int x = -3; x <= 3; x++) {
			if (x == 0 && y == 0) { continue; }
			if (abs(x) == 3 && abs(y) > 1) { continue; }
			if (abs(y) == 3 && abs(x) > 1) { continue; }
			total += cellAt(base, ivec2(x, y), size);
		}
	}
	return total / 36.0;
}

// Neighbourhood 2 = ring with inner r = 4 and outer r = 7 (108 cells).
float neighborsAvgRing(ivec2 base, ivec2 size) {
	float total = 0.0;
	for (int y = -7; y <= 7; y++) {
		for (int x = -7; x <= 7; x++) {
			// ignore inner area
			if (abs(x) <= 3 && abs(y) <= 3) { continue; }
			if (abs(x) == 4 && abs(y) <= 2) { continue; }
			if (abs(y) == 4 && abs(x) <= 2) { continue; }
			// ignore outer corners
			if (abs(x) == 7 && abs(y) > 2) { continue; }
			if (abs(x) == 6 && abs(y) > 4) { continue; }
			if (abs(x) == 5 && abs(y) > 5) { continue; }
			if (abs(x) > 2 && abs(y) > 6) { continue; }
			total += cellAt(base, ivec2(x, y), size);
		}
	}
	return total / 108.0;
}

float getState(float avg1, float avg2, float state,
		float n1v1, float n1r1, float n1v2, float n1r2,
		float n1v3, float n1r3, float n1v4, float n1r4,
		float n2v1, float n2r1, float n2v2, float n2r2) {
	float newState = state;
	if (avg1 >= n1v1 * 0.01 && avg1 <= n1v1 * 0.01 + n1r1 * 0.01) { newState = 1.0; }
	if (avg1 >= n1v2 * 0.01 && avg1 <= n1v2 * 0.01 + n1r2 * 0.01) { newState = 0.0; }
	if (avg1 >= n1v3 * 0.01 && avg1 <= n1v3 * 0.01 + n1r3 * 0.01) { newState = 0.0; }
	if (avg2 >= n2v1 * 0.01 && avg2 <= n2v1 * 0.01 + n2r1 * 0.01) { newState = 0.0; }
	if (avg2 >= n2v2 * 0.01 && avg2 <= n2v2 * 0.01 + n2r2 * 0.01) { newState = 1.0; }
	if (avg1 >= n1v4 * 0.01 && avg1 <= n1v4 * 0.01 + n1r4 * 0.01) { newState = 0.0; }
	return newState;
}

void main() {
	ivec2 texSizeI = textureSize(bufTex, 0);
	vec2 texSize = vec2(float(texSizeI.x), float(texSizeI.y));
	vec2 uv = gl_FragCoord.xy / texSize;

	// Slot 0: resolution, time, deltaTime
	float deltaTime = data[0].w;

	// Slot 1: speed, smoothing, weight, seed
	float speed = data[1].x;
	float weight = data[1].z;
	int seed = int(data[1].w);

	// Slot 2: resetState, n1v1, n1r1, n1v2
	bool resetState = data[2].x > 0.5;
	float n1v1 = data[2].y;
	float n1r1 = data[2].z;
	float n1v2 = data[2].w;

	// Slot 3: n1r2, n1v3, n1r3, n1v4
	float n1r2 = data[3].x;
	float n1v3 = data[3].y;
	float n1r3 = data[3].z;
	float n1v4 = data[3].w;

	// Slot 4: n1r4, n2v1, n2r1, n2v2
	float n1r4 = data[4].x;
	float n2v1 = data[4].y;
	float n2r1 = data[4].z;
	float n2v2 = data[4].w;

	// Slot 5: n2r2
	float n2r2 = data[5].x;

	// Sample the seed surface unconditionally (uniform control flow); only applied
	// when weight > 0.
	vec3 prevFrame = texture(seedTex, uv).rgb;
	float prevLum = lum(prevFrame);

	// UV-derived integer coordinate, matching the WGSL (handles any resolution
	// mismatch between output and feedback texture).
	ivec2 base = ivec2(int(uv.x * texSize.x), int(uv.y * texSize.y));
	vec4 bufState = texelFetch(bufTex, clampCoord(base, texSizeI), 0);
	float state = bufState.r;
	bool bufferIsEmpty = (bufState.r == 0.0 && bufState.g == 0.0 && bufState.b == 0.0 && bufState.a == 0.0);

	// Initialize when reset button pressed or when buffer is completely empty (first load).
	if (resetState || bufferIsEmpty) {
		float r = random(uv + vec2(float(seed), float(seed)));
		float alive = step(0.5, r);
		frag = vec4(alive, alive, alive, 1.0);
		return;
	}

	float n1 = neighborsAvgCircle(base, texSizeI);
	float n2 = neighborsAvgRing(base, texSizeI);
	float newState = getState(n1, n2, state, n1v1, n1r1, n1v2, n1r2, n1v3, n1r3, n1v4, n1r4, n2v1, n2r1, n2v2, n2r2);

	if (weight > 0.0) {
		newState = mix(newState, prevLum, weight * 0.01);
	}

	// speed is a BPM-style knob remapped to a stable integration step.
	float animSpeed = map(speed, 1.0, 100.0, 0.1, 100.0);
	vec4 currentState = vec4(state, state, state, 1.0);
	vec4 nextState = vec4(newState, newState, newState, 1.0);
	frag = mix(currentState, nextState, min(1.0, deltaTime * animSpeed));
}
