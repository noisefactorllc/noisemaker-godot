#version 450
// synth/gradient — ported from wgsl/gradient.wgsl (top-left origin = Godot/Vulkan,
// no Y-flip). Linear/radial/conic/diamond/corners/spiral/noise gradients with
// rotation + repeat. Packed uniformLayout: vec4 data[8] (effects/synth/gradient.json).
#include "include/nm_core.glsl"

layout(set = 0, binding = 0, std140) uniform Params { vec4 data[8]; };
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

// Values referenced by helper functions (set from data[] in main; WGSL private vars).
vec2 resolution;
vec2 fullResolution;
int seed;
int colorCount;
vec3 color1;
vec3 color2;
vec3 color3;
vec3 color4;

vec2 rotate2D(vec2 st, float angle) {
	vec2 fullRes = (fullResolution.x > 0.0) ? fullResolution : resolution;
	float aspectRatio = fullRes.x / fullRes.y;
	vec2 coord = st;
	coord.x = coord.x * aspectRatio;
	coord = coord - vec2(aspectRatio * 0.5, 0.5);
	float c = cos(angle);
	float s = sin(angle);
	coord = mat2(c, -s, s, c) * coord;
	coord = coord + vec2(aspectRatio * 0.5, 0.5);
	coord.x = coord.x / aspectRatio;
	return coord;
}

vec3 getColor(int idx) {
	if (idx == 0) { return color1; }
	if (idx == 1) { return color2; }
	if (idx == 2) { return color3; }
	return color4;
}

vec3 blendColors(float t_in) {
	float t = fract(t_in);
	float segment = t * float(colorCount);
	int idx = int(floor(segment));
	float localT = fract(segment);
	int next = idx + 1;
	if (next >= colorCount) { next = 0; }
	return mix(getColor(idx), getColor(next), localT);
}

float hash2D(vec2 p) {
	return prng(vec3(p, float(seed))).x;
}

float valueNoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	float a = hash2D(i);
	float b = hash2D(i + vec2(1.0, 0.0));
	float c = hash2D(i + vec2(0.0, 1.0));
	float d = hash2D(i + vec2(1.0, 1.0));
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

float fbmNoise(vec2 p) {
	float sum = 0.0;
	float amp = 0.5;
	float freq = 1.0;
	float maxVal = 0.0;
	for (int i = 0; i < 4; i = i + 1) {
		sum = sum + valueNoise(p * freq) * amp;
		maxVal = maxVal + amp;
		freq = freq * 2.0;
		amp = amp * 0.5;
	}
	return sum / maxVal;
}

void main() {
	resolution = data[0].xy;
	float time = data[0].z;
	float speed = data[0].w;
	float rotation = data[1].x;
	int gradientType = int(data[1].y);
	int repeat = int(data[1].z);
	colorCount = int(data[1].w);
	seed = int(data[2].x);
	color1 = data[3].xyz;
	color2 = data[4].xyz;
	color3 = data[5].xyz;
	color4 = data[6].xyz;
	vec2 tileOffset = data[7].xy;
	fullResolution = data[7].zw;

	vec2 fullRes = (fullResolution.x > 0.0) ? fullResolution : resolution;
	vec2 st = (gl_FragCoord.xy + tileOffset) / fullRes;
	float aspectRatio = fullRes.x / fullRes.y;
	float angle = -rotation * PI / 180.0;
	vec2 rotatedSt = rotate2D(st, angle);
	vec2 centered = st - 0.5;
	centered.x = centered.x * aspectRatio;
	float c = cos(angle);
	float s = sin(angle);
	vec2 rotatedCentered = mat2(c, -s, s, c) * centered;

	vec3 color;
	float t;
	float timeOffset = time * speed;

	if (gradientType == 0) {
		float a = atan(rotatedCentered.y, rotatedCentered.x);
		t = (a + PI) / TAU;
		t = fract(t * float(repeat) + timeOffset);
		color = blendColors(t);
	} else if (gradientType == 1) {
		t = abs(rotatedCentered.x) + abs(rotatedCentered.y);
		t = fract(t * float(repeat) + timeOffset);
		color = blendColors(t);
	} else if (gradientType == 2) {
		vec2 cornerSt = rotate2D(st, angle);
		vec3 cTL = color1;
		vec3 cTR = color1;
		vec3 cBL = color2;
		vec3 cBR = color2;
		if (colorCount >= 3) { cTR = color2; cBL = color3; cBR = color3; }
		if (colorCount >= 4) { cBR = color4; }
		vec3 top = mix(cTL, cTR, cornerSt.x);
		vec3 bottom = mix(cBL, cBR, cornerSt.x);
		color = mix(bottom, top, cornerSt.y);
	} else if (gradientType == 3) {
		t = rotatedSt.y;
		t = fract(t * float(repeat) + timeOffset);
		color = blendColors(t);
	} else if (gradientType == 4) {
		vec2 noiseSt = rotatedCentered * 4.0;
		t = fbmNoise(noiseSt);
		t = fract(t * float(repeat) + timeOffset);
		color = blendColors(t);
	} else if (gradientType == 5) {
		vec2 rotatedPoint = mat2(c, -s, s, c) * centered;
		float dist = length(rotatedPoint) * 2.0;
		t = dist;
		t = fract(t * float(repeat) + timeOffset);
		color = blendColors(t);
	} else if (gradientType == 6) {
		float a = atan(rotatedCentered.y, rotatedCentered.x);
		float dist = length(centered);
		t = fract(a / TAU + dist * 2.0);
		t = fract(t * float(repeat) + timeOffset);
		color = blendColors(t);
	} else {
		color = color1;
	}

	frag = vec4(color, 1.0);
}
