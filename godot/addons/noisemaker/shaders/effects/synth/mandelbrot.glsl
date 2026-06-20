#version 450
// synth/mandelbrot — ported from wgsl/mandelbrot.wgsl (top-left origin = Godot/Vulkan,
// no Y-flip). df64 deep-zoom Mandelbrot explorer. 5 output modes:
//   0 smoothIteration, 1 distance, 2 stripeAverage, 3 orbitTrap, 4 normalMap.
// 9 POIs with df64-precision coordinates. Single render pass. Uses no nm_core
// primitives, so the include is omitted; PI/TAU/BAILOUT/LOG2/MAX_ITER are inlined
// verbatim from the WGSL. Layout effect: vec4 data[5] (effects/synth/mandelbrot.json).
layout(set = 0, binding = 0, std140) uniform Params { vec4 data[5]; };
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

const float PI = 3.14159265359;
const float TAU = 6.28318530718;
const float BAILOUT = 256.0;
const float LOG2 = 0.6931471805599453;
const int MAX_ITER = 2048;

// ============================================================================
// df64 arithmetic
// ============================================================================

vec2 df64_quick_two_sum(float a, float b) {
	float s = a + b;
	float e = b - (s - a);
	return vec2(s, e);
}

vec2 df64_two_sum(float a, float b) {
	float s = a + b;
	float v = s - a;
	float e = (a - (s - v)) + (b - v);
	return vec2(s, e);
}

// Dekker's split method for error-free product
vec2 df64_two_prod(float a, float b) {
	float p = a * b;
	float ca = 4097.0 * a;
	float ah = ca - (ca - a);
	float al = a - ah;
	float cb = 4097.0 * b;
	float bh = cb - (cb - b);
	float bl = b - bh;
	float e = ((ah * bh - p) + ah * bl + al * bh) + al * bl;
	return vec2(p, e);
}

vec2 df64_add(vec2 a, vec2 b) {
	vec2 s = df64_two_sum(a.x, b.x);
	s.y = s.y + a.y + b.y;
	return df64_quick_two_sum(s.x, s.y);
}

vec2 df64_sub(vec2 a, vec2 b) {
	return df64_add(a, vec2(-b.x, -b.y));
}

vec2 df64_mul(vec2 a, vec2 b) {
	vec2 p = df64_two_prod(a.x, b.x);
	p.y = p.y + a.x * b.y + a.y * b.x;
	return df64_quick_two_sum(p.x, p.y);
}

vec2 df64_mul_f(vec2 a, float b) {
	vec2 p = df64_two_prod(a.x, b);
	p.y = p.y + a.y * b;
	return df64_quick_two_sum(p.x, p.y);
}

vec2 df64_from(float a) {
	return vec2(a, 0.0);
}

float df64_to_float(vec2 a) {
	return a.x + a.y;
}

// ============================================================================
// Points of Interest
// ============================================================================

struct PoiCoords {
	vec2 cX;
	vec2 cY;
};

float getPoiMaxZoom(int index) {
	if (index == 2 || index == 7) { return 7.0; }   // 5-8 digit coords
	if (index == 8) { return 10.0; }                  // 10 digit coords
	return 14.0;                                       // full df64 precision
}

PoiCoords getPOI(int index, float centerHiX, float centerLoX, float centerHiY, float centerLoY) {
	// Verified from authoritative sources (MROB, superliminal, fractaljourney)
	if (index == 1) { // seahorseValley — MROB embedded Julia nucleus
		return PoiCoords(vec2(-0.7445398569107056, -3.4452027897e-9),
						 vec2( 0.12172377109527588, 2.7991489404e-9));
	} else if (index == 2) { // elephantValley — MROB
		return PoiCoords(vec2( 0.29833000898361206, -8.9836120765e-9),
						 vec2( 0.0011099999537691474, 4.6230852696e-11));
	} else if (index == 3) { // scepterValley — period-3 nucleus
		return PoiCoords(vec2(-1.7548776865005493, 2.0253856592e-8),
						 vec2( 0.0, 0.0));
	} else if (index == 4) { // miniBrot — fractaljourney verified
		return PoiCoords(vec2(-1.7400623559951782, -2.6584161761e-8),
						 vec2( 0.028175339102745056, 6.7646594229e-10));
	} else if (index == 5) { // feigenbaum — Myrberg-Feigenbaum constant
		return PoiCoords(vec2(-1.4011552333831787, 4.4291128098e-8),
						 vec2( 0.0, 0.0));
	} else if (index == 6) { // birdOfParadise — superliminal verified
		return PoiCoords(vec2( 0.37500011920928955, 8.5257595428e-10),
						 vec2(-0.21663938462734222, -3.8103704636e-9));
	} else if (index == 7) { // spiralGalaxy — MROB seahorse double hook
		return PoiCoords(vec2(-0.7445389032363892, -1.6763610833e-8),
						 vec2( 0.12172418087720871, -8.7720870845e-10));
	} else if (index == 8) { // doubleSpiral — MROB seahorse medallion
		return PoiCoords(vec2(-1.2553445100784302, -1.4721569741e-8),
						 vec2(-0.3822004497051239, -1.3294876089e-8));
	}
	return PoiCoords(vec2(centerHiX, centerLoX), vec2(centerHiY, centerLoY));
}

// ============================================================================
// Coordinate transform
// ============================================================================

struct Df64Pair {
	vec2 re;
	vec2 im;
};

Df64Pair transformCoords_df64(vec2 fragCoord, vec2 resolution,
							  vec2 cX_df, vec2 cY_df,
							  float z, float rot) {
	vec2 uv = (fragCoord - 0.5 * resolution) / min(resolution.x, resolution.y);
	float angle = -rot * TAU / 360.0;
	float c = cos(angle);
	float s = sin(angle);
	// Match GLSL mat2(c, -s, s, c) column-major rotation
	uv = vec2(c * uv.x + s * uv.y, -s * uv.x + c * uv.y);

	float scale = 2.5 / z;
	vec2 re = df64_add(df64_from(uv.x * scale), cX_df);
	vec2 im = df64_add(df64_from(uv.y * scale), cY_df);
	return Df64Pair(re, im);
}

// ============================================================================
// Early-out tests
// ============================================================================

bool inCardioid(float x, float y) {
	float y2 = y * y;
	float q = (x - 0.25) * (x - 0.25) + y2;
	return q * (q + (x - 0.25)) <= 0.25 * y2;
}

bool inPeriod2Bulb(float x, float y) {
	float xp1 = x + 1.0;
	return xp1 * xp1 + y * y <= 0.0625;
}

// ============================================================================
// Orbit trap
// ============================================================================

float trapDistance(vec2 z, int shape) {
	if (shape == 0) {
		return length(z);
	} else if (shape == 1) {
		return min(abs(z.x), abs(z.y));
	} else {
		return abs(length(z) - 1.0);
	}
}

// ============================================================================
// Iteration result
// ============================================================================

struct IterResult {
	float smoothIter;
	float rawIter;
	vec2 z_final;
	vec2 dz_final;
	float stripeAcc;
	float trapMin;
};

// ============================================================================
// df64 iteration — deep precision
// ============================================================================

IterResult mandelbrot_df64(vec2 c_re, vec2 c_im, int maxIter,
						   float sFreq, int tShape) {
	float cx = df64_to_float(c_re);
	float cy = df64_to_float(c_im);
	if (inCardioid(cx, cy) || inPeriod2Bulb(cx, cy)) {
		return IterResult(float(maxIter), float(maxIter), vec2(0.0), vec2(0.0), 0.0, 1e20);
	}

	vec2 zr = vec2(0.0, 0.0);
	vec2 zi = vec2(0.0, 0.0);
	vec2 dz = vec2(1.0, 0.0);
	float stripe = 0.0;
	float trap = 1e20;
	float i = 0.0;

	for (int n = 0; n < MAX_ITER; n = n + 1) {
		if (n >= maxIter) { break; }

		float zx = df64_to_float(zr);
		float zy = df64_to_float(zi);

		dz = vec2(
			2.0 * (zx * dz.x - zy * dz.y) + 1.0,
			2.0 * (zx * dz.y + zy * dz.x)
		);

		vec2 zr2 = df64_mul(zr, zr);
		vec2 zi2 = df64_mul(zi, zi);
		vec2 zri = df64_mul(zr, zi);
		vec2 new_zr = df64_add(df64_sub(zr2, zi2), c_re);
		vec2 new_zi = df64_add(df64_mul_f(zri, 2.0), c_im);
		zr = new_zr;
		zi = new_zi;

		float post_zx = df64_to_float(zr);
		float post_zy = df64_to_float(zi);
		float post_mag2 = post_zx * post_zx + post_zy * post_zy;

		if (sFreq > 0.0) {
			stripe = stripe + sin(sFreq * atan(post_zy, post_zx));
		}
		trap = min(trap, trapDistance(vec2(post_zx, post_zy), tShape));

		if (post_mag2 > BAILOUT * BAILOUT) { break; }
		i = i + 1.0;
	}

	float fx = df64_to_float(zr);
	float fy = df64_to_float(zi);
	vec2 z_final = vec2(fx, fy);

	float smoothI = i;
	float mag2 = dot(z_final, z_final);
	if (i < float(maxIter) && mag2 > 1.0) {
		float log_zn = log(mag2) * 0.5;
		float nu = log(log_zn / LOG2) / LOG2;
		smoothI = i + 1.0 - nu;
	}

	return IterResult(smoothI, i, z_final, dz, stripe, trap);
}

// ============================================================================
// Output algorithms
// ============================================================================

float outputSmoothIteration(float smoothI, float rawI, int maxIter) {
	if (rawI >= float(maxIter)) { return 0.0; }
	return smoothI / float(maxIter);
}

float outputDistance(vec2 z, vec2 dz, float rawI, int maxIter) {
	if (rawI >= float(maxIter)) { return 0.0; }
	float mag = length(z);
	float dmag = length(dz);
	if (dmag == 0.0) { return 0.0; }
	float dist = 2.0 * mag * log(mag) / dmag;
	return clamp(sqrt(dist * float(maxIter)) * 0.5, 0.0, 1.0);
}

float outputStripeAverage(float smoothI, float rawI, float stripeAcc, int maxIter) {
	if (rawI >= float(maxIter)) { return 0.0; }
	float count = max(rawI, 1.0);
	float avg = stripeAcc / count;
	float frac = smoothI - floor(smoothI);
	return clamp(0.5 + 0.5 * avg * (1.0 - frac), 0.0, 1.0);
}

float outputOrbitTrap(float trapMin, float rawI, int maxIter) {
	if (rawI >= float(maxIter)) { return 0.0; }
	return clamp(1.0 - trapMin * 0.5, 0.0, 1.0);
}

// ============================================================================
// Normal map helpers
// ============================================================================

float computeDistAt_df64(vec2 fragCoord, vec2 resolution,
						 vec2 cX_df, vec2 cY_df, float z_zoom, float rot,
						 int maxIter, float sFreq, int tShape) {
	Df64Pair coords = transformCoords_df64(fragCoord, resolution, cX_df, cY_df, z_zoom, rot);
	IterResult r = mandelbrot_df64(coords.re, coords.im, maxIter, sFreq, tShape);
	return outputDistance(r.z_final, r.dz_final, r.rawIter, maxIter);
}

float outputNormalMap(vec2 fragCoord, vec2 resolution,
					  vec2 cX_df, vec2 cY_df,
					  float z_zoom, float rot, int maxIter, float angle,
					  float sFreq, int tShape) {
	float eps = 1.0 / min(resolution.x, resolution.y);
	float h0 = computeDistAt_df64(fragCoord, resolution, cX_df, cY_df, z_zoom, rot, maxIter, sFreq, tShape);
	float hx = computeDistAt_df64(fragCoord + vec2(1.0, 0.0), resolution, cX_df, cY_df, z_zoom, rot, maxIter, sFreq, tShape);
	float hy = computeDistAt_df64(fragCoord + vec2(0.0, 1.0), resolution, cX_df, cY_df, z_zoom, rot, maxIter, sFreq, tShape);

	vec3 normal = normalize(vec3(h0 - hx, h0 - hy, eps));
	float rad = angle * TAU / 360.0;
	vec3 lightDir = normalize(vec3(cos(rad), sin(rad), 0.7));
	return clamp(dot(normal, lightDir), 0.0, 1.0);
}

// ============================================================================
// Main
// ============================================================================

void main() {
	vec2 resolution = data[0].xy;
	float time = data[0].z;

	int poi = int(data[1].x);
	int outputMode = int(data[1].y);
	int iterations = int(data[1].z);

	float centerHiX = data[2].x;
	float centerHiY = data[2].y;
	float centerLoX = data[2].z;
	float centerLoY = data[2].w;

	float zoomSpeed = data[3].x;
	float zoomDepth = data[3].y;
	float invertVal = data[3].z;
	float stripeFreq = data[3].w;

	int trapShape = int(data[4].x);
	float lightAngle = data[4].y;
	float rotation = data[4].z;

	int maxIter = min(iterations, MAX_ITER);

	// Clamp zoom depth to POI coordinate precision
	float maxDepth = (poi > 0) ? getPoiMaxZoom(poi) : 14.0;
	float effDepth = min(zoomDepth, maxDepth);
	float effZoom;
	if (zoomSpeed > 0.0) {
		// Sinusoidal zoom: t=0 zoomed out, t=0.5/speed max depth, t=1/speed zoomed out
		float zoomPhase = 0.5 * (1.0 - cos(time * zoomSpeed * TAU));
		effZoom = pow(10.0, effDepth * zoomPhase);
	} else {
		effZoom = pow(10.0, effDepth);
	}

	float rot = (poi > 0) ? 0.0 : rotation;

	// Resolve POI coordinates
	PoiCoords poiCoords = getPOI(poi, centerHiX, centerLoX, centerHiY, centerLoY);
	vec2 cX_df = poiCoords.cX;
	vec2 cY_df = poiCoords.cY;

	float value;

	if (outputMode == 4) {
		value = outputNormalMap(gl_FragCoord.xy, resolution, cX_df, cY_df,
							   effZoom, rot, maxIter, lightAngle,
							   stripeFreq, trapShape);
	} else {
		Df64Pair coords = transformCoords_df64(gl_FragCoord.xy, resolution, cX_df, cY_df, effZoom, rot);
		IterResult r = mandelbrot_df64(coords.re, coords.im, maxIter, stripeFreq, trapShape);

		if (outputMode == 0) {
			value = outputSmoothIteration(r.smoothIter, r.rawIter, maxIter);
		} else if (outputMode == 1) {
			value = outputDistance(r.z_final, r.dz_final, r.rawIter, maxIter);
		} else if (outputMode == 2) {
			value = outputStripeAverage(r.smoothIter, r.rawIter, r.stripeAcc, maxIter);
		} else if (outputMode == 3) {
			value = outputOrbitTrap(r.trapMin, r.rawIter, maxIter);
		} else {
			value = outputSmoothIteration(r.smoothIter, r.rawIter, maxIter);
		}
	}

	if (invertVal > 0.5) {
		value = 1.0 - value;
	}

	frag = vec4(vec3(value), 1.0);
}
