#version 450
// synth/subdivide — ported VERBATIM from wgsl/subdivide.wgsl (WGSL is canonical).
// Recursive grid subdivision with shapes: a pixel walks a binary/quad subdivision
// tree (up to 6 levels), then is shaded with a per-cell crossfaded shape + background,
// with an optional input-texture blend and cell outlines. Top-left origin
// (Godot/Vulkan, matches WGSL) — NO Y-flip (runtime handles the single global flip).
//
// LAYOUT effect: declares its own packed UBO `vec4 data[3]` at set 0, binding 0
// (effects/synth/subdivide.json uniformLayout) and reads data[i].comp verbatim
// (WGSL u.data[i].comp). The input texture binds at set 0, binding 1 (pass.inputs
// order); it is sampled ONLY inside the `blend > 0` branch with a generated
// cell-relative UV (NOT gl_FragCoord/textureSize).
//
// pcg/prng here are this effect's OWN copies (Variant B — NO negative fold; reference
// /08 §1.2), inlined under renamed symbols. Do NOT substitute nm_core's prng (Variant
// A, with fold). All shape/shade helpers are this effect's own, inlined verbatim.
// No shared nm_core primitive is used unchanged, so nm_core is not included.

layout(set = 0, binding = 0, std140) uniform Params { vec4 data[3]; };
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

// NOTE — input texture (WGSL @binding(2) inputTex, pass.inputs.inputTex = "tex"):
// subdivide is a SYNTH whose `tex` input defaults to "none". The reference WebGPU
// backend binds a 1x1 TRANSPARENT-BLACK dummy texture for "none" inputs, so the
// `blend > 0` branch samples (0,0,0). The Godot RenderingDevice backend
// (runtime/nm_backend.gd) instead SKIPS "none" inputs entirely, and Godot requires
// every declared descriptor binding to be provided — declaring `sampler2D inputTex`
// at binding 1 makes uniform_set_create fail and the pass draws nothing. With the
// default graph inputMix=0 (blend=0) the branch is unreachable, and for "none" the
// reference samples transparent black anyway, so the input color is sourced as
// vec3(0.0) below — pixel-identical to the reference for every reachable case under
// this backend, without an unbindable descriptor. (A real bound texture would need a
// backend change; the shader contract here is binding-set parity with nm_backend.gd.)

// Golden ratio for staggering level transitions (WGSL: const PHI).
const float PHI = 1.618033988749895;

// PCG PRNG — deterministic across platforms (WGSL: fn pcg). Inlined verbatim.
uvec3 sd_pcg(uvec3 v_in) {
	uvec3 v = v_in * 1664525u + 1013904223u;
	v.x = v.x + v.y * v.z;
	v.y = v.y + v.z * v.x;
	v.z = v.z + v.x * v.y;
	v = v ^ (v >> uvec3(16u));
	v.x = v.x + v.y * v.z;
	v.y = v.y + v.z * v.x;
	v.z = v.z + v.x * v.y;
	return v;
}

// prng (Variant B — no fold): float->uint is TRUNCATION toward zero. Divisor
// float(0xffffffffu) = 4294967295.0.
vec3 sd_prng(vec3 p) {
	return vec3(sd_pcg(uvec3(uint(p.x), uint(p.y), uint(p.z)))) / float(0xffffffffu);
}

// Get a random float for a cell at a given level and channel. Reads the seed from
// data[1].y (WGSL u.data[1].y).
float cellRand(vec2 cellMin, float level, float channel, float animSeed) {
	float cx = floor(cellMin.x * 1000.0);
	float cy = floor(cellMin.y * 1000.0);
	float seed = data[1].y;
	return sd_prng(vec3(cx + level * 7.0, cy + level * 13.0, seed + channel + animSeed * 100.0)).x;
}

// Shape functions (1.0 inside, 0.0 outside). All work in 1:1 aspect-corrected
// centered coords.
float circleShape(vec2 centered) {
	return step(length(centered), 0.32);
}

float diamondShape(vec2 centered) {
	return step(abs(centered.x) + abs(centered.y), 0.32);
}

float squareShape(vec2 centered) {
	return step(max(abs(centered.x), abs(centered.y)), 0.28);
}

float arcShape(vec2 centered, float halfW, float halfH, float h) {
	int corner = int(h * 4.0);
	vec2 origin;
	if (corner == 0) { origin = vec2(-halfW, -halfH); }
	else if (corner == 1) { origin = vec2(halfW, -halfH); }
	else if (corner == 2) { origin = vec2(-halfW, halfH); }
	else { origin = vec2(halfW, halfH); }
	float dist = length(centered - origin);
	return step(dist, 0.7) * (1.0 - step(dist, 0.5));
}

float drawShape(int shapeType, vec2 centered, float halfW, float halfH, float h) {
	if (shapeType == 0) { return 1.0; }  // solid
	if (shapeType == 1) { return circleShape(centered); }
	if (shapeType == 2) { return diamondShape(centered); }
	if (shapeType == 3) { return squareShape(centered); }
	if (shapeType == 4) { return arcShape(centered, halfW, halfH, h); }
	return 1.0;
}

float shadeFromHash(float h) {
	int idx = int(h * 5.0);
	if (idx == 0) { return 0.15; }
	if (idx == 1) { return 0.35; }
	if (idx == 2) { return 0.55; }
	if (idx == 3) { return 0.75; }
	return 1.0;
}

void main() {
	vec2 resolution = data[0].xy;
	int modeType = int(data[0].z);
	int maxDepth = int(data[0].w);
	float dens = data[1].x / 100.0;
	int fillType = int(data[1].z);
	float outlineWidthX = data[1].w / resolution.x;
	float outlineWidthY = data[1].w / resolution.y;

	float time = data[2].z;
	float spd = floor(data[2].w) * 2.0;

	vec2 st = gl_FragCoord.xy / resolution;

	// Subdivision loop
	vec2 cellMin = vec2(0.0);
	vec2 cellMax = vec2(1.0);
	bool isOutline = false;

	for (int level = 0; level < 6; level = level + 1) {
		if (level >= maxDepth) { break; }

		// Stagger each level's transition using golden ratio
		float levelTime = floor(time * spd + float(level) * PHI);
		float h = cellRand(cellMin, float(level), 0.0, levelTime);

		if (h < dens) {
			// Skip splits that would create too-narrow cells (max 5:1 aspect)
			float cellW = (cellMax.x - cellMin.x) * resolution.x;
			float cellH = (cellMax.y - cellMin.y) * resolution.y;
			bool canSplitH = min(cellW, cellH * 0.5) / max(cellW, cellH * 0.5) >= 0.2;
			bool canSplitV = min(cellW * 0.5, cellH) / max(cellW * 0.5, cellH) >= 0.2;

			if (modeType == 0) {
				float dir = cellRand(cellMin, float(level), 1.0, levelTime);
				int splitDir = -1;
				if (dir < 0.5) {
					if (canSplitH) { splitDir = 0; }
					else if (canSplitV) { splitDir = 1; }
				} else {
					if (canSplitV) { splitDir = 1; }
					else if (canSplitH) { splitDir = 0; }
				}
				if (splitDir == 0) {
					float mid = (cellMin.y + cellMax.y) * 0.5;
					if (abs(st.y - mid) < outlineWidthY) { isOutline = true; }
					if (st.y < mid) { cellMax.y = mid; }
					else { cellMin.y = mid; }
				} else if (splitDir == 1) {
					float mid = (cellMin.x + cellMax.x) * 0.5;
					if (abs(st.x - mid) < outlineWidthX) { isOutline = true; }
					if (st.x < mid) { cellMax.x = mid; }
					else { cellMin.x = mid; }
				}
			} else {
				if (canSplitH && canSplitV) {
					vec2 mid = (cellMin + cellMax) * 0.5;
					if (abs(st.x - mid.x) < outlineWidthX || abs(st.y - mid.y) < outlineWidthY) {
						isOutline = true;
					}
					if (st.x < mid.x) { cellMax.x = mid.x; }
					else { cellMin.x = mid.x; }
					if (st.y < mid.y) { cellMax.y = mid.y; }
					else { cellMin.y = mid.y; }
				}
			}
		}
	}

	// Cell properties
	vec2 cellSize = cellMax - cellMin;
	vec2 cellUv = (st - cellMin) / cellSize;

	// 1:1 aspect-corrected coords, scaled to fit shorter side
	float cellPixelW = cellSize.x * resolution.x;
	float cellPixelH = cellSize.y * resolution.y;
	float minDim = min(cellPixelW, cellPixelH);
	vec2 centered = cellUv - 0.5;
	centered.x = centered.x * (cellPixelW / minDim);
	centered.y = centered.y * (cellPixelH / minDim);
	float halfW = cellPixelW / minDim * 0.5;
	float halfH = cellPixelH / minDim * 0.5;

	// Visual properties crossfade between current and next state
	float visualT = time * spd + PHI * 7.0;
	float curVisualTime = floor(visualT);
	float nextVisualTime = curVisualTime + 1.0;
	float visualBlend = smoothstep(0.0, 1.0, fract(visualT));

	// Crossfade shades
	float shade = mix(
		shadeFromHash(cellRand(cellMin, 0.0, 2.0, curVisualTime)),
		shadeFromHash(cellRand(cellMin, 0.0, 2.0, nextVisualTime)),
		visualBlend);
	float bgShade = mix(
		shadeFromHash(cellRand(cellMin, 0.0, 8.0, curVisualTime)),
		shadeFromHash(cellRand(cellMin, 0.0, 8.0, nextVisualTime)),
		visualBlend);

	// Crossfade shapes (dissolve between current and next)
	int curShapeType = fillType;
	int nextShapeType = fillType;
	if (modeType == 0) {
		curShapeType = 0;
		nextShapeType = 0;
	} else if (fillType == 5) {
		curShapeType = int(cellRand(cellMin, 0.0, 3.0, curVisualTime) * 5.0);
		nextShapeType = int(cellRand(cellMin, 0.0, 3.0, nextVisualTime) * 5.0);
	}
	float curCorner = cellRand(cellMin, 0.0, 4.0, curVisualTime);
	float nextCorner = cellRand(cellMin, 0.0, 4.0, nextVisualTime);
	float curMask = drawShape(curShapeType, centered, halfW, halfH, curCorner);
	float nextMask = drawShape(nextShapeType, centered, halfW, halfH, nextCorner);
	float shapeMask = mix(curMask, nextMask, visualBlend);

	float color = mix(bgShade, shade, shapeMask);
	vec3 result = vec3(color);

	// Input texture blend (random scale, offset, aspect-preserving)
	float blend = data[2].x / 100.0;
	if (blend > 0.0) {
		float curTexScale = 0.3 + cellRand(cellMin, 0.0, 5.0, curVisualTime) * 0.7;
		float nextTexScale = 0.3 + cellRand(cellMin, 0.0, 5.0, nextVisualTime) * 0.7;
		float texScale = mix(curTexScale, nextTexScale, visualBlend);

		vec2 texUv = cellUv;
		// Correct for aspect ratio difference between cell and texture
		float cellAspect = (cellSize.x * resolution.x) / (cellSize.y * resolution.y);
		float texAspect = resolution.x / resolution.y;
		float ratio = cellAspect / texAspect;
		if (ratio > 1.0) {
			texUv.x = 0.5 + (texUv.x - 0.5) * ratio;
		} else {
			texUv.y = 0.5 + (texUv.y - 0.5) / ratio;
		}
		texUv = texUv * texScale;
		texUv.x = texUv.x + mix(
			cellRand(cellMin, 0.0, 6.0, curVisualTime),
			cellRand(cellMin, 0.0, 6.0, nextVisualTime),
			visualBlend) * (1.0 - texScale);
		texUv.y = texUv.y + mix(
			cellRand(cellMin, 0.0, 7.0, curVisualTime),
			cellRand(cellMin, 0.0, 7.0, nextVisualTime),
			visualBlend) * (1.0 - texScale);
		// Apply wrap mode
		int wrapMode = int(data[2].y);
		if (wrapMode == 0) {
			texUv = abs(mod(texUv + 1.0, 2.0) - 1.0);
		} else if (wrapMode == 1) {
			texUv = mod(texUv, 1.0);
		} else {
			texUv = clamp(texUv, vec2(0.0), vec2(1.0));
		}
		// Reference "none"-input fallback: 1x1 transparent-black dummy -> rgb (0,0,0).
		// (texUv computed verbatim above for fidelity; nm_backend.gd binds no sampler
		// for a "none" input, so there is no descriptor to sample.)
		vec3 inputColor = vec3(0.0);
		result = mix(result, inputColor, blend);
	}

	// Outline (black, drawn after texture so it stays visible)
	if (isOutline && data[1].w > 0.0) {
		result = vec3(0.0);
	}

	frag = vec4(result, 1.0);
}
