#version 450
// classicNoisedeck/glitch — digital glitch processor (chunked shear, snow bursts,
// scanlines, lensing + chromatic aberration, vignette). Ported PIXEL-IDENTICALLY from
// the canonical WGSL source:
//   shaders/effects/classicNoisedeck/glitch/wgsl/glitch.wgsl
// (cross-checked against the reference GLSL).
//
// Single render pass (program "glitch"). Input-taker: reads inputTex (no-layout effect,
// glitch.json declares no uniformLayout). The backend SYNTHESIZES the Params UBO and
// injects `#define <name> data[slot].comp` for the 8 engine globals plus every param's
// `uniform` field: glitchiness, aberration, xChonk, yChonk, seed, scanlinesAmt, snowAmt,
// vignetteAmt, distortion, aspectLens. We use the bare names directly. Engine `time`,
// `resolution` read (bare). Input texture set 0, binding 1.
//
// ⚠️ RESERVED-NAME COLLISIONS (injected #defines vs reference symbols) — many here, all
// pure symbol renames with no behavior change:
//   - helper params named after engine globals / params: `time`→`timeArg`,
//     `resolution`→`res`, `seed`→`seedArg`, `scanlinesAmt`→`scanlinesAmtArg`,
//     `snowAmt`→`snowAmtArg`, and in glitch(): `aspectRatio`→`ar`, `xChonk`→`xChonkArg`,
//     `yChonk`→`yChonkArg`, `glitchiness`→`glitchinessArg`, `aspectLens`→`aspectLensArg`,
//     `distortion`→`distortionArg`, `aberration`→`aberrationArg`.
//   - main()'s locals `resolution`/`aspectRatio` collide with the engine #defines →
//     renamed to `res`/`ar`.
//   - local `let refract` inside glitch() shadows the GLSL builtin `refract` → renamed
//     to `refr`.
// The bare engine names remain only at main() use sites where the #define must resolve.
//
// WGSL `%` → GLSL `mod()`. gl_FragCoord top-left (Godot/Vulkan, matches WGSL) — NO
// per-effect Y-flip.
layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

const float GLITCH_PI = 3.14159265359;
const float GLITCH_TAU = 6.28318530718;

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

vec3 prng(vec3 p) {
	return vec3(pcg(uvec3(uint(p.x), uint(p.y), uint(p.z)))) / float(0xffffffffu);
}

float f(vec2 st, int seedArg) {
	return prng(vec3(floor(st), float(seedArg))).x;
}

float bicubic(vec2 p, int seedArg) {
	float x = p.x;
	float y = p.y;
	float x1 = floor(x);
	float y1 = floor(y);
	float x2 = x1 + 1.0;
	float y2 = y1 + 1.0;
	float f11 = f(vec2(x1, y1), seedArg);
	float f12 = f(vec2(x1, y2), seedArg);
	float f21 = f(vec2(x2, y1), seedArg);
	float f22 = f(vec2(x2, y2), seedArg);
	float f11x = (f(vec2(x1 + 1.0, y1), seedArg) - f(vec2(x1 - 1.0, y1), seedArg)) / 2.0;
	float f12x = (f(vec2(x1 + 1.0, y2), seedArg) - f(vec2(x1 - 1.0, y2), seedArg)) / 2.0;
	float f21x = (f(vec2(x2 + 1.0, y1), seedArg) - f(vec2(x2 - 1.0, y1), seedArg)) / 2.0;
	float f22x = (f(vec2(x2 + 1.0, y2), seedArg) - f(vec2(x2 - 1.0, y2), seedArg)) / 2.0;
	float f11y = (f(vec2(x1, y1 + 1.0), seedArg) - f(vec2(x1, y1 - 1.0), seedArg)) / 2.0;
	float f12y = (f(vec2(x1, y2 + 1.0), seedArg) - f(vec2(x1, y2 - 1.0), seedArg)) / 2.0;
	float f21y = (f(vec2(x2, y1 + 1.0), seedArg) - f(vec2(x2, y1 - 1.0), seedArg)) / 2.0;
	float f22y = (f(vec2(x2, y2 + 1.0), seedArg) - f(vec2(x2, y2 - 1.0), seedArg)) / 2.0;
	float f11xy = (f(vec2(x1 + 1.0, y1 + 1.0), seedArg) - f(vec2(x1 + 1.0, y1 - 1.0), seedArg) - f(vec2(x1 - 1.0, y1 + 1.0), seedArg) + f(vec2(x1 - 1.0, y1 - 1.0), seedArg)) / 4.0;
	float f12xy = (f(vec2(x1 + 1.0, y2 + 1.0), seedArg) - f(vec2(x1 + 1.0, y2 - 1.0), seedArg) - f(vec2(x1 - 1.0, y2 + 1.0), seedArg) + f(vec2(x1 - 1.0, y2 - 1.0), seedArg)) / 4.0;
	float f21xy = (f(vec2(x2 + 1.0, y1 + 1.0), seedArg) - f(vec2(x2 + 1.0, y1 - 1.0), seedArg) - f(vec2(x2 - 1.0, y1 + 1.0), seedArg) + f(vec2(x2 - 1.0, y1 - 1.0), seedArg)) / 4.0;
	float f22xy = (f(vec2(x2 + 1.0, y2 + 1.0), seedArg) - f(vec2(x2 + 1.0, y2 - 1.0), seedArg) - f(vec2(x2 - 1.0, y2 + 1.0), seedArg) + f(vec2(x2 - 1.0, y2 - 1.0), seedArg)) / 4.0;

	mat4 Q = mat4(
		vec4(f11, f21, f11x, f21x),
		vec4(f12, f22, f12x, f22x),
		vec4(f11y, f21y, f11xy, f21xy),
		vec4(f12y, f22y, f12xy, f22xy)
	);
	mat4 S = mat4(
		vec4(1.0, 0.0, 0.0, 0.0),
		vec4(0.0, 0.0, 1.0, 0.0),
		vec4(-3.0, 3.0, -2.0, -1.0),
		vec4(2.0, -2.0, 1.0, 1.0)
	);
	mat4 T = mat4(
		vec4(1.0, 0.0, -3.0, 2.0),
		vec4(0.0, 0.0, 3.0, -2.0),
		vec4(0.0, 1.0, -2.0, 1.0),
		vec4(0.0, 0.0, -1.0, 1.0)
	);
	mat4 A = T * Q * S;
	float t = fract(p.x);
	float uu = fract(p.y);
	vec4 tv = vec4(1.0, t, t * t, t * t * t);
	vec4 uv = vec4(1.0, uu, uu * uu, uu * uu * uu);
	return dot(tv * A, uv);
}

float map(float value, float inMin, float inMax, float outMin, float outMax) {
	return outMin + (outMax - outMin) * (value - inMin) / (inMax - inMin);
}

float periodicFunction(float p) {
	return map(sin(p * GLITCH_TAU), -1.0, 1.0, 0.0, 1.0);
}

vec4 scanlines(vec4 color, vec2 st, vec2 res, float scanlinesAmtArg, float timeArg, int seedArg) {
	float centerDistance = length(vec2(0.5) - st) * GLITCH_PI * 0.5;
	float noise = periodicFunction(bicubic(st * 4.0, seedArg) - timeArg) * map(scanlinesAmtArg, 0.0, 100.0, 0.0, 0.5);
	float hatch = (sin(mix(st.y, st.y + noise, pow(centerDistance, 8.0)) * res.y * 1.5) + 1.0) * 0.5;
	vec4 result = color;
	result = vec4(mix(color.rgb, color.rgb * hatch, map(scanlinesAmtArg, 0.0, 100.0, 0.0, 0.5)), color.a);
	return result;
}

vec4 snow(vec4 color, vec2 fragCoord, float snowAmtArg, float timeArg) {
	float amt = snowAmtArg / 100.0;
	float noise = prng(vec3(fragCoord, timeArg * 1000.0)).x;

	float maskNoise = prng(vec3(fragCoord + 10.0, timeArg * 1000.0)).x;
	float maskNoiseSparse = clamp(maskNoise - 0.93875, 0.0, 0.06125) * 16.0;

	float mask;
	if (amt < 0.5) {
		mask = mix(0.0, maskNoiseSparse, amt * 2.0);
	} else {
		mask = mix(maskNoiseSparse, maskNoise * maskNoise, map(amt, 0.5, 1.0, 0.0, 1.0));
		if (amt > 0.75) {
			mask = mix(mask, 1.0, map(amt, 0.75, 1.0, 0.0, 1.0));
		}
	}

	return vec4(mix(color.rgb, vec3(noise), mask), color.a);
}

float offsets(vec2 st) {
	return prng(vec3(floor(st), 0.0)).x;
}

vec4 glitch(vec2 st_in, float ar, float timeArg, float xChonkArg, float yChonkArg, float glitchinessArg, float aspectLensArg, float distortionArg, float aberrationArg) {
	vec2 st = st_in;
	vec2 freq = vec2(1.0);
	freq.x = freq.x * map(xChonkArg, 1.0, 100.0, 50.0, 1.0);
	freq.y = freq.y * map(yChonkArg, 1.0, 100.0, 50.0, 1.0);

	freq = freq * vec2(periodicFunction(prng(vec3(floor(st * freq), 0.0)).x - timeArg));

	float g = map(glitchinessArg, 0.0, 100.0, 0.0, 1.0);

	// get drift value from somewhere far away
	float xDrift = prng(vec3(floor(st * freq) + 10.0, 0.0)).x * g;
	float yDrift = prng(vec3(floor(st * freq) - 10.0, 0.0)).x * g;

	float sparseness = map(glitchinessArg, 0.0, 100.0, 8.0, 2.0);

	// clamp for sparseness
	float rand = prng(vec3(floor(st * freq), 0.0)).x;
	float xOffset = clamp((periodicFunction(rand + xDrift - timeArg) - periodicFunction(xDrift - timeArg) * sparseness) * 4.0, 0.0, 1.0);
	float yOffset = clamp((periodicFunction(rand + yDrift - timeArg) - periodicFunction(yDrift - timeArg) * sparseness) * 4.0, 0.0, 1.0);

	float refr = g * 0.125;

	st.x = mod(st.x + sin(xOffset * GLITCH_TAU) * refr, 1.0);
	st.y = mod(st.y + sin(yOffset * GLITCH_TAU) * refr, 1.0);

	// aberration and lensing
	vec2 diff = vec2(0.5 - st.x, 0.5 - st.y);
	if (aspectLensArg > 0.5) {
		diff = vec2(0.5 * ar, 0.5) - vec2(st.x * ar, st.y);
	}
	float centerDist = length(diff);

	float distort = 0.0;
	float zoom = 1.0;
	if (distortionArg < 0.0) {
		distort = map(distortionArg, -100.0, 0.0, -0.5, 0.0);
		zoom = map(distortionArg, -100.0, 0.0, 0.01, 0.0);
	} else {
		distort = map(distortionArg, 0.0, 100.0, 0.0, 0.5);
		zoom = map(distortionArg, 0.0, 100.0, 0.0, -0.25);
	}

	vec2 lensedCoords = fract((st - diff * zoom) - diff * centerDist * centerDist * distort);

	float aberrationOffset = map(aberrationArg, 0.0, 100.0, 0.0, 0.05) * centerDist * GLITCH_PI * 0.5;

	float redOffset = mix(clamp(lensedCoords.x + aberrationOffset, 0.0, 1.0), lensedCoords.x, lensedCoords.x);
	vec4 red = texture(inputTex, vec2(redOffset, lensedCoords.y));

	vec4 green = texture(inputTex, lensedCoords);

	float blueOffset = mix(lensedCoords.x, clamp(lensedCoords.x - aberrationOffset, 0.0, 1.0), lensedCoords.x);
	vec4 blue = texture(inputTex, vec2(blueOffset, lensedCoords.y));

	return vec4(red.r, green.g, blue.b, green.a);
}

void main() {
	vec2 res = resolution;
	float ar = res.x / res.y;

	vec2 uv = gl_FragCoord.xy / res;

	vec4 color = glitch(uv, ar, time, xChonk, yChonk, glitchiness, aspectLens, distortion, aberration);
	color = scanlines(color, uv, res, scanlinesAmt, time, int(seed));
	color = snow(color, gl_FragCoord.xy, snowAmt, time);

	// vignette
	if (vignetteAmt < 0.0) {
		color = vec4(
			mix(color.rgb * (1.0 - pow(length(vec2(0.5) - uv) * 1.125, 2.0)), color.rgb, map(vignetteAmt, -100.0, 0.0, 0.0, 1.0)),
			max(color.a, length(vec2(0.5) - uv) * map(vignetteAmt, -100.0, 0.0, 1.0, 0.0))
		);
	} else {
		color = vec4(
			mix(color.rgb, 1.0 - (1.0 - color.rgb * (1.0 - pow(length(vec2(0.5) - uv) * 1.125, 2.0))), map(vignetteAmt, 0.0, 100.0, 0.0, 1.0)),
			max(color.a, length(vec2(0.5) - uv) * map(vignetteAmt, -100.0, 0.0, 1.0, 0.0))
		);
	}

	frag = color;
}
