#version 450
// mixer/cellSplit — ported from wgsl/cellSplit.wgsl. Splits between two inputs
// using Voronoi cell regions (edges mode / split mode). No-layout effect:
// backend injects Params UBO + `#define mode …`/`scale …`/`edgeWidth …`/`seed …`/
// `invert …`/`speed …` and engine globals `time`/`tileOffset`/`fullResolution`.
// Two inputs (pass.inputs order): inputTex = A (binding 1), tex = B (binding 2).
layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(set = 0, binding = 2) uniform sampler2D tex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

const float TAU = 6.28318530718;

// PCG PRNG - MIT License
// https://github.com/riccardoscalco/glsl-pcg-prng
uvec3 pcg(uvec3 seedv) {
	uvec3 v = seedv * 1664525u + 1013904223u;
	v.x = v.x + v.y * v.z;
	v.y = v.y + v.z * v.x;
	v.z = v.z + v.x * v.y;
	v = v ^ (v >> uvec3(16u));
	v.x = v.x + v.y * v.z;
	v.y = v.y + v.z * v.x;
	v.z = v.z + v.x * v.y;
	return v;
}

vec3 prng(vec3 p0) {
	vec3 p = p0;
	if (p.x >= 0.0) { p.x = p.x * 2.0; } else { p.x = -p.x * 2.0 + 1.0; }
	if (p.y >= 0.0) { p.y = p.y * 2.0; } else { p.y = -p.y * 2.0 + 1.0; }
	if (p.z >= 0.0) { p.z = p.z * 2.0; } else { p.z = -p.z * 2.0 + 1.0; }
	uvec3 u = pcg(uvec3(p));
	return vec3(u) / float(0xffffffffu);
}

void main() {
	vec2 dims = vec2(textureSize(inputTex, 0));
	vec2 st = gl_FragCoord.xy / dims;

	vec4 colorA = texture(inputTex, st);
	vec4 colorB = texture(tex, st);

	// WGSL i32 uniforms (mode/seed/invert) — capture as ints (backend injects them
	// as float `data[].comp`; the WGSL uses them as i32 in compares/casts).
	int modeI = int(mode);
	int seedI = int(seed);
	int invertI = int(invert);

	// Aspect-correct, scaled coordinates using full image dimensions
	// so Voronoi cells are consistent across tiles
	float aspect = fullResolution.x / fullResolution.y;
	vec2 globalUV = (gl_FragCoord.xy + tileOffset) / fullResolution;
	vec2 p = globalUV * (31.0 - scale);
	p.x = p.x * aspect;

	float spd = floor(speed);
	vec2 cellCoord = floor(p);
	vec2 cellFract = fract(p);

	// Pass 1: find nearest cell center
	float d1 = 1e10;
	vec2 nearestPoint = vec2(0.0);
	vec2 nearestCell = vec2(0.0);
	float nearestHash = 0.0;

	for (int y = -1; y <= 1; y = y + 1) {
		for (int x = -1; x <= 1; x = x + 1) {
			vec2 neighbor = vec2(float(x), float(y));
			vec2 cellId = cellCoord + neighbor;
			vec3 rnd = prng(vec3(cellId, float(seedI)));
			vec2 wobble = sin(TAU * time * spd + rnd.xy * TAU) * 0.15 * min(spd, 1.0);
			vec2 point = neighbor + rnd.xy + wobble - cellFract;
			float dist = dot(point, point);

			if (dist < d1) {
				d1 = dist;
				nearestPoint = point;
				nearestCell = cellId;
				nearestHash = rnd.z;
			}
		}
	}

	// Pass 2: find minimum perpendicular distance to any Voronoi edge
	// (bisector between nearest center and each neighbor center)
	float edgeDistVal = 1e10;
	for (int y = -2; y <= 2; y = y + 1) {
		for (int x = -2; x <= 2; x = x + 1) {
			vec2 neighbor = vec2(float(x), float(y));
			vec2 cellId = cellCoord + neighbor;
			if (all(equal(cellId, nearestCell))) { continue; }
			vec3 rnd = prng(vec3(cellId, float(seedI)));
			vec2 wobble = sin(TAU * time * spd + rnd.xy * TAU) * 0.15 * min(spd, 1.0);
			vec2 point = neighbor + rnd.xy + wobble - cellFract;
			// Perpendicular distance to bisector between nearest and this neighbor
			vec2 mid = (nearestPoint + point) * 0.5;
			vec2 edge = normalize(point - nearestPoint);
			float d = abs(dot(mid, edge));
			edgeDistVal = min(edgeDistVal, d);
		}
	}

	float onEdge;
	if (edgeWidth > 0.0) {
		onEdge = step(edgeDistVal, edgeWidth);
	} else {
		onEdge = 0.0;
	}

	float mask;
	if (modeI == 0) {
		// Edges mode: cells show A, edges show B
		mask = onEdge;
	} else {
		// Split mode: cells randomly assigned to A or B, edges show 50/50
		float cellChoice = step(0.5, nearestHash);
		if (invertI == 1) {
			cellChoice = 1.0 - cellChoice;
		}
		mask = mix(cellChoice, 0.5, onEdge);
	}

	// Apply invert (in edges mode, swaps cells/edges assignment)
	if (modeI == 0 && invertI == 1) {
		mask = 1.0 - mask;
	}

	vec4 color = mix(colorA, colorB, mask);
	color.a = max(colorA.a, colorB.a);

	frag = color;
}
