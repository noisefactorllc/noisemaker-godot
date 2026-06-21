#version 450
// synth/cell — ported from wgsl/cell.wgsl (top-left origin = Godot/Vulkan,
// no Y-flip). Worley / Voronoi distance-field generator (mono output).
// Per-effect helpers (polarShape/shape/smin/cells) inlined verbatim; only
// pcg/prng/map/PI/TAU come from nm_core. Packed uniformLayout: vec4 data[4]
// (effects/synth/cell.json). PARITY HAZARDS:
//   atan2 arg order kept literal: atan(st.x, st.y).
//   prng arg ORDER differs: point/r2 use prng(vec3(wrap, seed)); r1 uses
//     prng(vec3(seed, wrap)). Reproduced exactly.
//   st divides by fullResolution.y (height). Full 32-bit float (PCG-sensitive).
#include "include/nm_core.glsl"

layout(set = 0, binding = 0, std140) uniform Params { vec4 data[4]; };
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

// polarShape: regular-polygon polar distance (cell.wgsl L50-54).
// atan2(st.x, st.y) -> atan(st.x, st.y): argument order copied literally.
float polarShape(vec2 st, int sides) {
	float a = atan(st.x, st.y) + PI;
	float r = TAU / float(sides);
	return cos(floor(0.5 + a / r) * r - a) * length(st);
}

// shape: distance metric by `kind` (cell.wgsl L56-73).
float shape(vec2 st0, vec2 offset, int kind, float scale) {
	vec2 st = st0 + offset;
	float d = 1.0;
	if (kind == 0) {
		d = length(st * 1.2);
	} else if (kind == 2) {
		d = polarShape(st * 1.2, 6);
	} else if (kind == 3) {
		d = polarShape(st * 1.2, 8);
	} else if (kind == 4) {
		d = polarShape(st * 1.5, 4);
	} else if (kind == 6) {
		vec2 st2 = st;
		st2.y = st2.y + 0.05;
		d = polarShape(st2 * 1.5, 3);
	}
	return d * scale;
}

// smin: iq polynomial smooth-min (cell.wgsl L75-79).
float smin(float a, float b, float k) {
	if (k == 0.0) { return min(a, b); }
	float h = max(k - abs(a - b), 0.0) / k;
	return min(a, b) - h * h * k * 0.25;
}

// cells: 5x5 Worley neighborhood evaluation (cell.wgsl L81-118).
float cells(vec2 st0, float freq, float cellSize, int metric, int seed, float speed, float variation, float cellSmooth, float time, float aspect) {
	vec2 st = st0;
	st = st - vec2(0.5 * aspect, 0.5);
	st = st * freq;
	st = st + vec2(0.5 * aspect, 0.5);
	st = st + prng(vec3(float(seed))).xy;

	vec2 i = floor(st);
	vec2 f = fract(st);

	float d = 1.0;
	for (int y = -2; y <= 2; y = y + 1) {
		for (int x = -2; x <= 2; x = x + 1) {
			vec2 n = vec2(float(x), float(y));
			vec2 wrap = i + n;
			vec2 point = prng(vec3(wrap, float(seed))).xy;

			vec3 r1 = prng(vec3(float(seed), wrap)) * 0.5 - vec3(0.25);
			vec3 r2 = prng(vec3(wrap, float(seed))) * 2.0 - vec3(1.0);
			float spd = floor(speed);
			point = point + vec2(
				sin(time * TAU * spd + r2.x) * r1.x,
				cos(time * TAU * spd + r2.y) * r1.y
			);

			vec2 diff = n + point - f;
			float dist = shape(vec2(diff.x, -diff.y), vec2(0.0), metric, cellSize);
			if (metric == 1) {
				dist = abs(n.x + point.x - f.x) + abs(n.y + point.y - f.y);
				dist = dist * cellSize;
			}

			dist = dist + r1.z * (variation * 0.01);
			d = smin(d, dist, cellSmooth * 0.01);
		}
	}
	return d;
}

void main() {
	vec2 resolution = data[0].xy;
	float time = data[0].z;
	int seed = int(data[0].w);

	int metric = int(data[1].x);
	float scale = data[1].y;
	float cellScale = data[1].z;
	float cellSmooth = data[1].w;

	float variation = data[2].x;
	float speed = data[2].y;

	vec2 tileOffset = data[3].xy;
	vec2 fullResolution = data[3].zw;
	float aspect = fullResolution.x / fullResolution.y;

	vec4 color = vec4(0.0, 0.0, 1.0, 1.0);
	vec2 st = (gl_FragCoord.xy + tileOffset) / fullResolution.y;

	float freq = map(scale, 1.0, 100.0, 20.0, 1.0);
	float cellSize = map(cellScale, 1.0, 100.0, 3.0, 0.75);

	float d = cells(st, freq, cellSize, metric, seed, speed, variation, cellSmooth, time, aspect);

	// Mono output only
	color = vec4(vec3(d, d, d), color.a);

	frag = color;
}
