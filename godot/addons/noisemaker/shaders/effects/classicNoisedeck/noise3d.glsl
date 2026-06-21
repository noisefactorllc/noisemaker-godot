#version 450
// classicNoisedeck/noise3d — ported PIXEL-IDENTICALLY from the canonical WGSL source
//   shaders/effects/classicNoisedeck/noise3d/wgsl/noise3d.wgsl
// Cross-checked against the top-left HLSL port
//   ../noisemaker-hlsl/.../Shaders/Effects/classicNoisedeck/Noise3d.hlsl
//
// Generator (no texture inputs). Single render pass. Ray-marches 3D noise volumes
// (simplex / cellular / voronoi / sine / spheres / cubes / wavy planes) and colorizes
// by mode (grayscale / hsv / surface normal / depth) with fog. Despite the "3d" name
// it is a plain fullscreen fragment shader.
//
// No-layout effect (uniformLayout ABSENT in noise3d.json; like solid.glsl / perlin.glsl):
// the backend SYNTHESIZES the Params UBO and injects, after #version, a
// `#define <name> data[slot].comp` for every engine global (resolution/time/aspectRatio/
// tileOffset/fullResolution/renderScale) AND every param uniform (ridges/seed/speed/scale/
// offsetX/offsetY/colorMode/hueRotation/hueRange). We use the bare names directly and
// declare NO UBO and NO uniforms. NOISE_TYPE is a compile-time integer #define injected by
// the runtime (globals.type.define = "NOISE_TYPE"); kept as a bare identifier, never
// declared or hardcoded.
//
// The WGSL binds the param as `noiseScale`, but the runtime define is the definition.js
// uniform NAME, which is `scale` (paramAliases maps noiseScale->scale). So every WGSL
// `noiseScale` becomes the bare `scale` here, exactly as the HLSL uniform is named `scale`.
//
// RESERVED-NAME COLLISIONS handled (PORTING-GUIDE): the WGSL `getDist` declares
// `let scale = map_value(...)` locals, but `scale` is an injected `#define scale data[..]`,
// so a local named `scale` would expand to `float data[..] = …` (glslang error). Those
// locals are renamed `sc` (a pure rename; the HLSL does the same). No helper parameter or
// other local collides with an injected name.
//
// Helpers (pcg/prng/random, map_value, smootherstep, smoothabs, rhash/voronoi3d, cellular
// + its mod289/mod7/permute, snoise + its mod289_4/permute_4/taylorInvSqrt, sine3D, spheres,
// cubes, getDist, getNormal, rayMarch, hsv2rgb) are this effect's OWN versions, ported
// VERBATIM and INLINE under an `n3_` prefix (PORTING-GUIDE rule 2; avoids injected-name
// and MSL-keyword collisions). This WGSL inlines its OWN pcg/prng (sign-fold variant,
// divisor float(0xffffffffu) = 4294967295.0), reproduced here exactly rather than using
// nm_core's — kept self-contained per the task brief.
//
// NUMERIC HAZARDS reproduced literally:
//   - st = ((gl_FragCoord.xy + tileOffset) - 0.5*fullResolution) / fullResolution.y
//     (DIVIDE BY .y). Top-left WGSL port: NO per-effect Y-flip.
//   - WGSL select(a,b,cond) == cond ? b : a (operands REVERSED) — every select reproduced.
//   - vec3<u32>(q) is float->uint TRUNCATION toward zero (uvec3(q)), NOT a bitcast.
//   - snoise(p * scale + f32(seed)) adds a SCALAR to a vec3 (broadcast); float(seed).
//   - speed/seed/ridges/colorMode arrive as float #defines; cast at the use site
//     (int(colorMode), float(seed), float(speed)) matching perlin.glsl / the HLSL.
//   - Full 32-bit float throughout (PCG / floor / fract bit-sensitive).
//
// PI/TAU are this effect's own literals (nm_core's TAU is the truncated form); declared
// locally under N3_ names matching the WGSL values exactly. NOISE_TYPE / colorMode branch
// chains follow the WGSL if/else-if order verbatim.

layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

const float N3_PI  = 3.14159265359;
const float N3_TAU = 6.28318530718;

// ===== PCG PRNG =====
// https://github.com/riccardoscalco/glsl-pcg-prng - MIT License
uvec3 n3_pcg(uvec3 v_in) {
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

vec3 n3_prng(vec3 p) {
	vec3 q = p;
	q.x = (q.x < 0.0) ? (-q.x * 2.0 + 1.0) : (q.x * 2.0);
	q.y = (q.y < 0.0) ? (-q.y * 2.0 + 1.0) : (q.y * 2.0);
	q.z = (q.z < 0.0) ? (-q.z * 2.0 + 1.0) : (q.z * 2.0);
	return vec3(n3_pcg(uvec3(q))) / float(0xffffffffu);
}

float n3_random(vec2 st) {
	return n3_prng(vec3(st, 0.0)).x;
}

// ===== Utility functions =====
float n3_map_value(float value, float inMin, float inMax, float outMin, float outMax) {
	return outMin + (outMax - outMin) * (value - inMin) / (inMax - inMin);
}

float n3_smootherstep(float x) {
	return x * x * x * (x * (x * 6.0 - 15.0) + 10.0);
}

float n3_smoothabs(float v, float m) {
	return sqrt(v * v + m);
}

// ===== 3D Voronoi =====
// https://github.com/MaxBittker/glsl-voronoi-noise - MIT License
const mat2 n3_myt = mat2(0.12121212, 0.13131313, -0.13131313, 0.12121212);
const vec2 n3_mys = vec2(1e4, 1e6);

vec2 n3_rhash(vec2 uv_in) {
	vec2 uv = n3_myt * uv_in;
	uv = uv * n3_mys;
	return fract(fract(uv / n3_mys) * uv);
}

vec3 n3_voronoi3d(vec3 x) {
	vec3 p = floor(x);
	vec3 f = fract(x);

	float id = 0.0;
	vec2 res = vec2(100.0);

	for (int k = -1; k <= 1; k = k + 1) {
		for (int j = -1; j <= 1; j = j + 1) {
			for (int i = -1; i <= 1; i = i + 1) {
				vec3 b = vec3(float(i), float(j), float(k));
				vec3 r = b - f + n3_prng(p + b);
				float d = dot(r, r);

				float cond = max(sign(res.x - d), 0.0);
				float nCond = 1.0 - cond;

				float cond2 = nCond * max(sign(res.y - d), 0.0);
				float nCond2 = 1.0 - cond2;

				id = (dot(p + b, vec3(1.0, 57.0, 113.0)) * cond) + (id * nCond);
				res = vec2(d, res.x) * cond + res * nCond;

				res.y = cond2 * d + nCond2 * res.y;
			}
		}
	}

	return vec3(sqrt(res), abs(id));
}

// ===== 3D Cellular Noise =====
// Stefan Gustavson - MIT License
vec3 n3_mod289_3(vec3 x) {
	return x - floor(x * (1.0 / 289.0)) * 289.0;
}

vec3 n3_mod7(vec3 x) {
	return x - floor(x * (1.0 / 7.0)) * 7.0;
}

vec3 n3_permute_3(vec3 x) {
	return n3_mod289_3((34.0 * x + 10.0) * x);
}

vec2 n3_cellular(vec3 P) {
	float K = 0.142857142857;
	float Ko = 0.428571428571;
	float K2 = 0.020408163265306;
	float Kz = 0.166666666667;
	float Kzo = 0.416666666667;
	float jitter = 1.0;

	vec3 Pi = n3_mod289_3(floor(P));
	vec3 Pf = fract(P) - 0.5;

	vec3 Pfx = Pf.x + vec3(1.0, 0.0, -1.0);
	vec3 Pfy = Pf.y + vec3(1.0, 0.0, -1.0);
	vec3 Pfz = Pf.z + vec3(1.0, 0.0, -1.0);

	vec3 p = n3_permute_3(Pi.x + vec3(-1.0, 0.0, 1.0));
	vec3 p1 = n3_permute_3(p + Pi.y - 1.0);
	vec3 p2 = n3_permute_3(p + Pi.y);
	vec3 p3 = n3_permute_3(p + Pi.y + 1.0);

	vec3 p11 = n3_permute_3(p1 + Pi.z - 1.0);
	vec3 p12 = n3_permute_3(p1 + Pi.z);
	vec3 p13 = n3_permute_3(p1 + Pi.z + 1.0);

	vec3 p21 = n3_permute_3(p2 + Pi.z - 1.0);
	vec3 p22 = n3_permute_3(p2 + Pi.z);
	vec3 p23 = n3_permute_3(p2 + Pi.z + 1.0);

	vec3 p31 = n3_permute_3(p3 + Pi.z - 1.0);
	vec3 p32 = n3_permute_3(p3 + Pi.z);
	vec3 p33 = n3_permute_3(p3 + Pi.z + 1.0);

	vec3 ox11 = fract(p11 * K) - Ko;
	vec3 oy11 = n3_mod7(floor(p11 * K)) * K - Ko;
	vec3 oz11 = floor(p11 * K2) * Kz - Kzo;

	vec3 ox12 = fract(p12 * K) - Ko;
	vec3 oy12 = n3_mod7(floor(p12 * K)) * K - Ko;
	vec3 oz12 = floor(p12 * K2) * Kz - Kzo;

	vec3 ox13 = fract(p13 * K) - Ko;
	vec3 oy13 = n3_mod7(floor(p13 * K)) * K - Ko;
	vec3 oz13 = floor(p13 * K2) * Kz - Kzo;

	vec3 ox21 = fract(p21 * K) - Ko;
	vec3 oy21 = n3_mod7(floor(p21 * K)) * K - Ko;
	vec3 oz21 = floor(p21 * K2) * Kz - Kzo;

	vec3 ox22 = fract(p22 * K) - Ko;
	vec3 oy22 = n3_mod7(floor(p22 * K)) * K - Ko;
	vec3 oz22 = floor(p22 * K2) * Kz - Kzo;

	vec3 ox23 = fract(p23 * K) - Ko;
	vec3 oy23 = n3_mod7(floor(p23 * K)) * K - Ko;
	vec3 oz23 = floor(p23 * K2) * Kz - Kzo;

	vec3 ox31 = fract(p31 * K) - Ko;
	vec3 oy31 = n3_mod7(floor(p31 * K)) * K - Ko;
	vec3 oz31 = floor(p31 * K2) * Kz - Kzo;

	vec3 ox32 = fract(p32 * K) - Ko;
	vec3 oy32 = n3_mod7(floor(p32 * K)) * K - Ko;
	vec3 oz32 = floor(p32 * K2) * Kz - Kzo;

	vec3 ox33 = fract(p33 * K) - Ko;
	vec3 oy33 = n3_mod7(floor(p33 * K)) * K - Ko;
	vec3 oz33 = floor(p33 * K2) * Kz - Kzo;

	vec3 dx11 = Pfx + jitter * ox11;
	vec3 dy11 = Pfy.x + jitter * oy11;
	vec3 dz11 = Pfz.x + jitter * oz11;

	vec3 dx12 = Pfx + jitter * ox12;
	vec3 dy12 = Pfy.x + jitter * oy12;
	vec3 dz12 = Pfz.y + jitter * oz12;

	vec3 dx13 = Pfx + jitter * ox13;
	vec3 dy13 = Pfy.x + jitter * oy13;
	vec3 dz13 = Pfz.z + jitter * oz13;

	vec3 dx21 = Pfx + jitter * ox21;
	vec3 dy21 = Pfy.y + jitter * oy21;
	vec3 dz21 = Pfz.x + jitter * oz21;

	vec3 dx22 = Pfx + jitter * ox22;
	vec3 dy22 = Pfy.y + jitter * oy22;
	vec3 dz22 = Pfz.y + jitter * oz22;

	vec3 dx23 = Pfx + jitter * ox23;
	vec3 dy23 = Pfy.y + jitter * oy23;
	vec3 dz23 = Pfz.z + jitter * oz23;

	vec3 dx31 = Pfx + jitter * ox31;
	vec3 dy31 = Pfy.z + jitter * oy31;
	vec3 dz31 = Pfz.x + jitter * oz31;

	vec3 dx32 = Pfx + jitter * ox32;
	vec3 dy32 = Pfy.z + jitter * oy32;
	vec3 dz32 = Pfz.y + jitter * oz32;

	vec3 dx33 = Pfx + jitter * ox33;
	vec3 dy33 = Pfy.z + jitter * oy33;
	vec3 dz33 = Pfz.z + jitter * oz33;

	vec3 d11 = dx11 * dx11 + dy11 * dy11 + dz11 * dz11;
	vec3 d12 = dx12 * dx12 + dy12 * dy12 + dz12 * dz12;
	vec3 d13 = dx13 * dx13 + dy13 * dy13 + dz13 * dz13;
	vec3 d21 = dx21 * dx21 + dy21 * dy21 + dz21 * dz21;
	vec3 d22 = dx22 * dx22 + dy22 * dy22 + dz22 * dz22;
	vec3 d23 = dx23 * dx23 + dy23 * dy23 + dz23 * dz23;
	vec3 d31 = dx31 * dx31 + dy31 * dy31 + dz31 * dz31;
	vec3 d32 = dx32 * dx32 + dy32 * dy32 + dz32 * dz32;
	vec3 d33 = dx33 * dx33 + dy33 * dy33 + dz33 * dz33;

	// Full F1+F2 sort
	vec3 d1a = min(d11, d12);
	d12 = max(d11, d12);
	d11 = min(d1a, d13);
	d13 = max(d1a, d13);
	d12 = min(d12, d13);

	vec3 d2a = min(d21, d22);
	d22 = max(d21, d22);
	d21 = min(d2a, d23);
	d23 = max(d2a, d23);
	d22 = min(d22, d23);

	vec3 d3a = min(d31, d32);
	d32 = max(d31, d32);
	d31 = min(d3a, d33);
	d33 = max(d3a, d33);
	d32 = min(d32, d33);

	vec3 da = min(d11, d21);
	d21 = max(d11, d21);
	d11 = min(da, d31);
	d31 = max(da, d31);

	d11 = vec3(
		(d11.x > d11.y) ? d11.y : d11.x,
		(d11.x > d11.y) ? d11.x : d11.y,
		d11.z
	);
	d11 = vec3(
		(d11.x > d11.z) ? d11.z : d11.x,
		d11.y,
		(d11.x > d11.z) ? d11.x : d11.z
	);

	d12 = min(d12, d21);
	d12 = min(d12, d22);
	d12 = min(d12, d31);
	d12 = min(d12, d32);
	d11 = vec3(d11.x, min(d11.yz, d12.xy));
	d11.y = min(d11.y, d12.z);
	d11.y = min(d11.y, d11.z);

	return sqrt(d11.xy);
}

// ===== 3D Simplex Noise =====
// Ashima Arts - MIT License
vec4 n3_mod289_4(vec4 x) {
	return x - floor(x * (1.0 / 289.0)) * 289.0;
}

vec4 n3_permute_4(vec4 x) {
	return n3_mod289_4(((x * 34.0) + 10.0) * x);
}

vec4 n3_taylorInvSqrt(vec4 r) {
	return 1.79284291400159 - 0.85373472095314 * r;
}

float n3_snoise(vec3 v) {
	vec2 C = vec2(1.0 / 6.0, 1.0 / 3.0);
	vec4 D = vec4(0.0, 0.5, 1.0, 2.0);

	vec3 i = floor(v + dot(v, C.yyy));
	vec3 x0 = v - i + dot(i, C.xxx);

	vec3 g = step(x0.yzx, x0.xyz);
	vec3 l = 1.0 - g;
	vec3 i1 = min(g.xyz, l.zxy);
	vec3 i2 = max(g.xyz, l.zxy);

	vec3 x1 = x0 - i1 + C.xxx;
	vec3 x2 = x0 - i2 + C.yyy;
	vec3 x3 = x0 - D.yyy;

	i = n3_mod289_3(i);
	vec4 p = n3_permute_4(
		n3_permute_4(
			n3_permute_4(i.z + vec4(0.0, i1.z, i2.z, 1.0))
			+ i.y + vec4(0.0, i1.y, i2.y, 1.0)
		)
		+ i.x + vec4(0.0, i1.x, i2.x, 1.0)
	);

	float n_ = 0.142857142857;
	vec3 ns = n_ * D.wyz - D.xzx;

	vec4 j = p - 49.0 * floor(p * ns.z * ns.z);

	vec4 x_ = floor(j * ns.z);
	vec4 y_ = floor(j - 7.0 * x_);

	vec4 x = x_ * ns.x + ns.yyyy;
	vec4 y = y_ * ns.x + ns.yyyy;
	vec4 h = 1.0 - abs(x) - abs(y);

	vec4 b0 = vec4(x.xy, y.xy);
	vec4 bHigh = vec4(x.zw, y.zw);

	vec4 s0 = floor(b0) * 2.0 + 1.0;
	vec4 sHigh = floor(bHigh) * 2.0 + 1.0;
	vec4 sh = -step(h, vec4(0.0));

	vec4 a0 = b0.xzyw + s0.xzyw * sh.xxyy;
	vec4 aHigh = bHigh.xzyw + sHigh.xzyw * sh.zzww;

	vec3 p0 = vec3(a0.xy, h.x);
	vec3 p1 = vec3(a0.zw, h.y);
	vec3 p2 = vec3(aHigh.xy, h.z);
	vec3 p3 = vec3(aHigh.zw, h.w);

	vec4 norm = n3_taylorInvSqrt(vec4(dot(p0, p0), dot(p1, p1), dot(p2, p2), dot(p3, p3)));
	p0 = p0 * norm.x;
	p1 = p1 * norm.y;
	p2 = p2 * norm.z;
	p3 = p3 * norm.w;

	vec4 m = max(vec4(0.5) - vec4(dot(x0, x0), dot(x1, x1), dot(x2, x2), dot(x3, x3)), vec4(0.0));
	m = m * m;
	return 105.0 * dot(m * m, vec4(dot(p0, x0), dot(p1, x1), dot(p2, x2), dot(p3, x3)));
}

// ===== Additional noise types =====
float n3_sine3D(vec3 p) {
	vec3 r0 = n3_prng(vec3(float(seed))) * N3_TAU;
	float a = r0.x;
	float b = r0.y;
	float c = r0.z;

	vec3 r1 = n3_prng(vec3(float(seed))) + 1.0;
	vec3 r2 = n3_prng(vec3(float(seed) + 10.0)) + 1.0;
	vec3 r3 = n3_prng(vec3(float(seed) + 20.0)) + 1.0;
	float xv = sin(r1.x * p.z + sin(r1.y * p.x + a) + sin(r1.z * p.y + b) + c);
	float yv = sin(r2.x * p.x + sin(r2.y * p.y + b) + sin(r2.z * p.z + c) + a);
	float zv = sin(r3.x * p.y + sin(r3.y * p.z + c) + sin(r3.z * p.x + a) + b);

	return (xv + yv + zv) * 0.33 + 0.33;
}

float n3_spheres(vec3 p) {
	vec3 q = p;
	vec3 pr = p - round(p);
	vec3 ip = floor(q);
	vec3 fp = fract(pr);
	vec3 r1 = n3_prng(ip + float(seed)) * 0.5 + 0.25;
	return length(fp - 0.5) - n3_map_value(scale, 1.0, 100.0, 0.025, 0.55) * r1.x;
}

float n3_cubes(vec3 p_in) {
	vec3 p = p_in;
	float s = 4.0;
	p.x = p.x - s * 0.5;
	p = p - s * round(p / s);
	vec3 b = vec3(n3_map_value(scale, 1.0, 100.0, 0.1, 0.95));
	vec3 q = abs(p) - b;
	return length(max(q, vec3(0.0))) + min(max(q.x, max(q.y, q.z)), 0.0);
}

// ===== Distance function (SDF) =====
// NOISE_TYPE is the compile-time integer #define; if/else-if chain follows the WGSL order.
// The WGSL's `let scale = …` locals are renamed `sc` (the global `scale` is an injected
// #define and cannot name a local). `noiseScale` -> bare `scale`.
float n3_getDist(vec3 p) {
	float d;

	if (NOISE_TYPE == 12) {
		// simplex
		float sc = n3_map_value(scale, 1.0, 100.0, 0.25, 0.025);
		d = n3_snoise(p * sc + float(seed)) * 0.5 + 0.5;
		d = n3_smootherstep(d);
	} else if (NOISE_TYPE == 20) {
		// cell
		float sc = n3_map_value(scale, 1.0, 100.0, 0.1, 0.35);
		d = n3_cellular(p * 0.1 + float(seed)).x;
		d = smoothstep(sc, 0.5, d);
	} else if (NOISE_TYPE == 21) {
		// cell v2
		d = n3_voronoi3d(p * 0.1 + float(seed)).x;
		float sc = n3_map_value(scale, 1.0, 100.0, 0.1, 0.35);
		d = smoothstep(sc, 0.5, d);
	} else if (NOISE_TYPE == 30) {
		// sine
		float sc = n3_map_value(scale, 1.0, 100.0, 1.0, 0.1);
		d = n3_sine3D(p * sc);
	} else if (NOISE_TYPE == 40) {
		d = n3_spheres(p);
	} else if (NOISE_TYPE == 50) {
		d = n3_cubes(p);
	} else if (NOISE_TYPE == 60) {
		// wavy planes both
		float sc = n3_map_value(scale, 1.0, 100.0, 0.25, 0.025);
		d = -abs(p.y) + 4.0 + n3_snoise(p * sc + float(seed)) * 0.75;
	} else if (NOISE_TYPE == 61) {
		// wavy plane lower
		float sc = n3_map_value(scale, 1.0, 100.0, 0.25, 0.025);
		d = p.y + 4.0 + n3_snoise(p * sc + float(seed)) * 0.75;
	} else if (NOISE_TYPE == 62) {
		// wavy plane upper
		float sc = n3_map_value(scale, 1.0, 100.0, 0.25, 0.025);
		d = -p.y + 2.0 + n3_snoise(p * sc + float(seed)) * 0.75;
	} else {
		// default to simplex
		float sc = n3_map_value(scale, 1.0, 100.0, 0.25, 0.025);
		d = n3_snoise(p * sc + float(seed)) * 0.5 + 0.5;
		d = n3_smootherstep(d);
	}

	if (ridges != 0 && NOISE_TYPE == 12) {
		d = 1.0 - n3_smoothabs(d * 2.0 - 1.0, 0.05);
	}

	return d;
}

// ===== Surface normal =====
vec3 n3_getNormal(vec3 p) {
	float epsilon = 0.01;

	float d = n3_getDist(p);
	float dx = n3_getDist(p + vec3(epsilon, 0.0, 0.0)) - d;
	float dy = n3_getDist(p + vec3(0.0, epsilon, 0.0)) - d;
	float dz = n3_getDist(p + vec3(0.0, 0.0, epsilon)) - d;

	return normalize(vec3(dx, dy, dz));
}

// ===== Ray marching =====
float n3_rayMarch(vec3 rayOrigin, vec3 rayDirection) {
	int maxSteps = 100;
	float maxDist = 100.0;
	float minDist = 0.01;
	float d = 0.0;

	for (int i = 0; i < maxSteps; i = i + 1) {
		vec3 p = rayOrigin + rayDirection * d;
		float dist = n3_getDist(p);
		d = d + dist;
		if (d > maxDist || dist < minDist) {
			break;
		}
	}
	return d;
}

// ===== Color conversion =====
vec3 n3_hsv2rgb(vec3 hsv) {
	float h = fract(hsv.x);
	float s = hsv.y;
	float v = hsv.z;

	float c = v * s;
	float h6 = h * 6.0;
	float xv = c * (1.0 - abs((h6 - 2.0 * floor(h6 / 2.0)) - 1.0));
	float m = v - c;

	vec3 rgb;

	if (h6 < 1.0) {
		rgb = vec3(c, xv, 0.0);
	} else if (h6 < 2.0) {
		rgb = vec3(xv, c, 0.0);
	} else if (h6 < 3.0) {
		rgb = vec3(0.0, c, xv);
	} else if (h6 < 4.0) {
		rgb = vec3(0.0, xv, c);
	} else if (h6 < 5.0) {
		rgb = vec3(xv, 0.0, c);
	} else {
		rgb = vec3(c, 0.0, xv);
	}

	return rgb + vec3(m, m, m);
}

// ===== Main fragment shader =====
// Mirrors WGSL main(): st = ((pos.xy + tileOffset) - 0.5*fullResolution) / fullResolution.y.
// gl_FragCoord is top-left in Vulkan/Godot (matches WGSL @builtin(position)); NO Y-flip.
void main() {
	vec4 color = vec4(0.0, 0.0, 0.0, 1.0);
	vec2 st = ((gl_FragCoord.xy + tileOffset) - 0.5 * fullResolution) / fullResolution.y;

	// Ray marching - calculate distance to scene objects
	vec3 rayOrigin = vec3(offsetX * 0.1, offsetY * 0.1, -8.0 + time * N3_TAU * float(speed));
	vec3 rayDirection = normalize(vec3(st, 1.0));
	float d = n3_rayMarch(rayOrigin, rayDirection);

	// Calculate the lighting
	vec3 p = rayOrigin + rayDirection * d;
	vec3 lightPosition = rayOrigin + vec3(-5.0, 5.0, -10.0);
	vec3 lightVector = normalize(lightPosition - p);
	vec3 normal = n3_getNormal(p);
	float diffuse = clamp(dot(normal, lightVector), 0.0, 1.0);

	// Colorize based on mode
	if (colorMode == 0) {
		// grayscale
		color = vec4(vec3(diffuse), 1.0);
	} else if (colorMode == 6) {
		// hsv
		color = vec4(n3_hsv2rgb(vec3(diffuse * (hueRange * 0.01) + (hueRotation / 360.0), 0.75, 0.75)), 1.0);
	} else if (colorMode == 7) {
		// surface normal
		color = vec4(normal, 1.0);
	} else if (colorMode == 8) {
		// depth
		color = vec4(vec3(clamp(d, 0.0, 1.0)), 1.0);
	} else {
		// default to grayscale
		color = vec4(vec3(diffuse), 1.0);
	}

	// Apply fog
	float fogDist = clamp(d / 50.0, 0.0, 1.0);
	color = vec4(mix(color.rgb, vec3(0.0), fogDist), 1.0);

	frag = color;
}
