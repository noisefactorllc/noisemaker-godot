#version 450
// classicNoisedeck/splat — splatter-paint compositor overlay. Ported PIXEL-IDENTICALLY
// from the canonical WGSL source:
//   shaders/effects/classicNoisedeck/splat/wgsl/splat.wgsl
// (cross-checked against the reference GLSL; the reference GLSL adds tileOffset/
// fullResolution tiling remaps the WGSL lacks — NOT reproduced here, per the porting
// guide. WGSL is the source of truth.)
//
// Single render pass (program "splat"). Input-taker: reads inputTex (no-layout effect,
// splat.json declares no uniformLayout). The backend SYNTHESIZES the Params UBO and
// injects `#define <name> data[slot].comp` for the 8 engine globals plus every param's
// `uniform` field: enabled, mode, scale, seed, color, cutoff, speed, useSpecks,
// speckMode, speckScale, speckSeed, speckColor, speckCutoff, speckSpeed. We use the bare
// names directly. Only engine `time` is read (bare). Input texture at set 0, binding 1.
//
// ⚠️ RESERVED-NAME COLLISIONS (injected #defines vs reference symbols):
//   - param `color` (the splat tint, vec3) collides with the working `vec4 color`
//     variable. Captured the tint into `splatTint` at the top of main and `#undef color`
//     before any further use.
//   - helper params named `scale` / `speed` collide with the param #defines → renamed to
//     `scaleArg` / `speedArg` (pure symbol renames, no behavior change).
//   - local `aspectRatio` (= dims.x/dims.y) collides with the engine #define → renamed
//     to `ar` (this shader never reads the engine aspectRatio).
//
// COORDINATE NOTE (from WGSL): uv = gl_FragCoord.xy / dims, aspectRatio = dims.x/dims.y,
// where dims = textureSize(inputTex, 0). gl_FragCoord is top-left (Godot/Vulkan, matches
// WGSL) — NO per-effect Y-flip.
layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

const float SPLAT_PI = 3.14159265359;
const float SPLAT_TAU = 6.28318530718;

float map(float value, float inMin, float inMax, float outMin, float outMax) {
	return outMin + (outMax - outMin) * (value - inMin) / (inMax - inMin);
}

// PCG PRNG
uvec3 pcg(uvec3 v_in) {
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

vec3 prng(vec3 p_in) {
	vec3 p = p_in;
	if (p.x >= 0.0) { p.x = p.x * 2.0; } else { p.x = -p.x * 2.0 + 1.0; }
	if (p.y >= 0.0) { p.y = p.y * 2.0; } else { p.y = -p.y * 2.0 + 1.0; }
	if (p.z >= 0.0) { p.z = p.z * 2.0; } else { p.z = -p.z * 2.0 + 1.0; }
	return vec3(pcg(uvec3(uint(p.x), uint(p.y), uint(p.z)))) / float(0xffffffffu);
}

float smootherstep(float x) {
	return x * x * x * (x * (x * 6.0 - 15.0) + 10.0);
}

float smoothlerp(float x, float a, float b) {
	return a + smootherstep(x) * (b - a);
}

float grid(vec2 st, vec2 cell, float speedArg) {
	float angle = prng(vec3(cell, 1.0)).r * SPLAT_TAU;
	angle = angle + time * SPLAT_TAU * speedArg;
	vec2 gradient = vec2(cos(angle), sin(angle));
	vec2 dist = st - cell;
	return dot(gradient, dist);
}

float perlin(vec2 st_in, vec2 scaleArg, float speedArg) {
	vec2 st = st_in - 0.5;
	st = st * scaleArg;
	st = st + 0.5;
	vec2 cell = floor(st);
	float tl = grid(st, cell, speedArg);
	float tr = grid(st, vec2(cell.x + 1.0, cell.y), speedArg);
	float bl = grid(st, vec2(cell.x, cell.y + 1.0), speedArg);
	float br = grid(st, cell + 1.0, speedArg);
	float upper = smoothlerp(st.x - cell.x, tl, tr);
	float lower = smoothlerp(st.x - cell.x, bl, br);
	float val = smoothlerp(st.y - cell.y, upper, lower);
	return val * 0.5 + 0.5;
}

float splat(vec2 st_in, vec2 scaleArg) {
	vec2 st = st_in;
	st.x = st.x + perlin(st + seed + 50.0, vec2(2.0, 3.0), 0.0) * 0.5 - 0.5;
	st.y = st.y + perlin(st + seed + 60.0, vec2(2.0, 3.0), 0.0) * 0.5 - 0.5;
	float d = perlin(st, vec2(4.0) * scaleArg, speed) +
	          (perlin(st + 10.0, vec2(8.0) * scaleArg, speed) * 0.5) +
	          (perlin(st + 20.0, vec2(16.0) * scaleArg, speed) * 0.25);
	return step(map(cutoff, 0.0, 100.0, 0.85, 0.99), d);
}

float speckle(vec2 st, vec2 scaleArg) {
	float d = perlin(st, scaleArg, speckSpeed) + (perlin(st + 10.0, scaleArg * 2.0, speckSpeed) * 0.5);
	d = d / 1.5;
	return step(map(speckCutoff, 0.0, 100.0, 0.6, 0.7), d);
}

void main() {
	// Capture the splat-tint param (injected as `#define color ...`) before it shadows the
	// working `color` variable, then drop the macro.
	vec3 splatTint = color;
	#undef color

	vec2 dims = vec2(textureSize(inputTex, 0));
	// `aspectRatio` is an injected engine #define → rename the local (pure symbol rename).
	float ar = dims.x / dims.y;
	vec2 uv = gl_FragCoord.xy / dims;

	vec4 color = texture(inputTex, uv);

	vec2 noiseCoord = uv * vec2(ar, 1.0);

	if (useSpecks != 0.0) {
		float speckMask = speckle(noiseCoord + speckSeed, vec2(32.0) * map(speckScale, 1.0, 5.0, 2.0, 0.5));

		if (speckMode == 0) {
			color = vec4(mix(color.rgb, speckColor, speckMask), color.a); // color
		} else if (speckMode == 1) {
			color = texture(inputTex, uv + speckMask * 0.1); // displace
		} else if (speckMode == 2) {
			color = vec4(mix(color.rgb, 1.0 - color.rgb, speckMask), color.a); // invert
		} else if (speckMode == 3) {
			color = vec4(color.rgb * speckMask, color.a); // negative
		}
	}

	if (enabled != 0.0) {
		float splatMask = splat(noiseCoord + seed, vec2(map(scale, 1.0, 5.0, 2.0, 0.5)));

		if (mode == 0) {
			color = vec4(mix(color.rgb, splatTint, splatMask), color.a); // color
		} else if (mode == 1) {
			vec4 texColor = texture(inputTex, uv + splatMask * 0.1); // displace
			color = mix(color, texColor, splatMask);
		} else if (mode == 2) {
			color = vec4(mix(color.rgb, 1.0 - color.rgb, splatMask), color.a); // invert
		} else if (mode == 3) {
			color = vec4(color.rgb * map(splatMask * 0.5 - 0.5, -0.25, 0.0, 0.0, 1.0), color.a); // negative
		}
	}

	frag = color;
}
