#version 450
// synth/newton — ported from wgsl/newton.wgsl (top-left origin = Godot/Vulkan,
// no Y-flip). Newton-Raphson root finding for z^n - 1 with df64 emulated
// double-precision deep zoom, golden-ratio animation, pre-baked points of
// interest, and three grayscale output modes (0 iteration, 1 rootIndex,
// 2 blended). All iteration runs in df64 complex arithmetic; z^n via repeated
// df64 complex multiplication. Uses no nm_core primitives, so the include is
// omitted; PI/TAU/PHI are inlined verbatim from the WGSL. Layout effect:
// vec4 data[7] (effects/synth/newton.json).
layout(set = 0, binding = 0, std140) uniform Params { vec4 data[7]; };
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

const float PI = 3.14159265359;
const float TAU = 6.28318530718;
const float PHI = 1.6180339887;

// ============================================================================
// df64 emulated double-precision
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
// df64 complex multiply
// ============================================================================

struct Df64Complex {
	vec2 re;
	vec2 im;
};

Df64Complex df64_cmul(Df64Complex a, Df64Complex b) {
	vec2 rr = df64_sub(df64_mul(a.re, b.re), df64_mul(a.im, b.im));
	vec2 ri = df64_add(df64_mul(a.re, b.im), df64_mul(a.im, b.re));
	return Df64Complex(rr, ri);
}

// ============================================================================
// df64 coordinate transform
// ============================================================================

struct CoordResult {
	vec2 re;
	vec2 im;
};

CoordResult transformCoords_df64(vec2 fragCoord, vec2 cX_df, vec2 cY_df,
								 vec2 res, float z_zoom, float rot) {
	vec2 uv = (fragCoord - 0.5 * res) / min(res.x, res.y);
	float angle = -rot * TAU / 360.0;
	float c = cos(angle);
	float s = sin(angle);
	uv = vec2(c * uv.x + s * uv.y, -s * uv.x + c * uv.y);
	float scale = 2.5 / z_zoom;
	vec2 uv_re_df = df64_mul_f(df64_from(uv.x), scale);
	vec2 uv_im_df = df64_mul_f(df64_from(uv.y), scale);
	vec2 re = df64_add(uv_re_df, cX_df);
	vec2 im = df64_add(uv_im_df, cY_df);
	return CoordResult(re, im);
}

// ============================================================================
// Points of interest
// ============================================================================

struct POIData {
	vec4 center;
	float deg;
	float maxZoom;
};

POIData getPOI(int idx) {
	// center = vec4(hiX, hiY, loX, loY), deg, maxZoom
	// Origin POIs: maxZoom=7 (pixel coord precision limit)
	// Non-origin POIs: df64 split provides ~14 digits
	if (idx == 1) { return POIData(vec4(0.0, 0.0, 0.0, 0.0), 3.0, 7.0); }           // triplePoint3
	if (idx == 2) { return POIData(vec4(0.25, 0.4330126941204071, 0.0, 7.7718e-9), 3.0, 14.0); } // spiralJunction3
	if (idx == 3) { return POIData(vec4(0.0, 0.0, 0.0, 0.0), 5.0, 7.0); }           // starCenter5
	if (idx == 4) { return POIData(vec4(0.6545084714889526, 0.4755282700061798, 2.5699e-8, -1.1859e-8), 5.0, 14.0); } // pentaSpiral5
	if (idx == 5) { return POIData(vec4(0.0, 0.0, 0.0, 0.0), 6.0, 7.0); }           // hexWeb6
	if (idx == 6) { return POIData(vec4(0.0, 0.0, 0.0, 0.0), 8.0, 7.0); }           // octoFlower8
	return POIData(vec4(0.0, 0.0, 0.0, 0.0), 3.0, 7.0);
}

// ============================================================================
// Main
// ============================================================================

void main() {
	// Unpack uniforms
	vec2 resolution = data[0].xy;
	float time = data[0].z;
	float degree = data[0].w;

	float relaxation = data[1].x;
	float iterations = data[1].y;
	float toleranceU = data[1].z;
	float poiU = data[1].w;

	float centerHiX = data[2].x;
	float centerHiY = data[2].y;
	float centerLoX = data[2].z;
	float centerLoY = data[2].w;

	float zoomSpeed = data[3].x;
	float zoomDepthU = data[3].y;
	float degreeSpeed = data[3].z;
	float degreeRangeU = data[3].w;

	float relaxSpeed = data[4].x;
	float relaxRangeU = data[4].y;
	float rotationU = data[4].z;
	float outputMode = data[5].x;
	float invertU = data[5].y;

	// Tile-aware global coords. When not tiling the engine supplies
	// tileOffset=(0,0) and fullResolution=resolution.
	vec2 tileOffset = data[6].xy;
	vec2 fullResolution = data[6].zw;
	vec2 frRes = (fullResolution.x > 0.0) ? fullResolution : resolution;

	int maxIter = int(iterations);
	int poiIdx = int(poiU);
	int outMode = int(outputMode);
	bool doInvert = invertU > 0.5;

	// --- Effective parameters with animation ---

	float effDegree = degree;
	if (degreeSpeed > 0.0 && degreeRangeU > 0.0) {
		effDegree = effDegree + degreeRangeU * sin(time * degreeSpeed * TAU);
		effDegree = clamp(effDegree, 3.0, 8.0);
	}

	float effRelax = relaxation;
	if (relaxSpeed > 0.0 && relaxRangeU > 0.0) {
		effRelax = effRelax + relaxRangeU * sin(time * relaxSpeed * TAU * PHI);
		effRelax = clamp(effRelax, 0.5, 2.0);
	}

	// --- Center and zoom ---

	vec2 cHi = vec2(centerHiX, centerHiY);
	vec2 cLo = vec2(centerLoX, centerLoY);
	float effZoomDepth = zoomDepthU;

	if (poiIdx > 0) {
		POIData p = getPOI(poiIdx);
		cHi = p.center.xy + cHi;
		cLo = p.center.zw + cLo;
		effDegree = p.deg;
		effZoomDepth = min(zoomDepthU, p.maxZoom);
	}

	// Sinusoidal zoom: time 0 = zoomed out, time 0.5/speed = max depth, time 1/speed = zoomed out
	float zoom;
	if (zoomSpeed > 0.0) {
		float zoomPhase = 0.5 * (1.0 - cos(time * zoomSpeed * TAU));
		zoom = pow(10.0, effZoomDepth * zoomPhase);
	} else {
		zoom = pow(10.0, effZoomDepth);
	}

	// --- df64 coordinate transform ---

	CoordResult coords = transformCoords_df64(gl_FragCoord.xy + tileOffset,
		vec2(cHi.x, cLo.x), vec2(cHi.y, cLo.y),
		frRes, zoom, rotationU);

	// --- Compute roots of z^n - 1 ---

	int intDeg = int(floor(effDegree));
	int numRoots = intDeg;
	vec2 roots[8];
	for (int k = 0; k < 8; k = k + 1) {
		if (k >= numRoots) { break; }
		float angle = TAU * float(k) / float(intDeg);
		roots[k] = vec2(cos(angle), sin(angle));
	}

	// --- df64 Newton iteration ---

	float iter = 0.0;
	int convergedRoot = -1;
	float convergeDist = 1.0;
	float bailout = 1e10 * effRelax;

	vec2 zr_df = coords.re;
	vec2 zi_df = coords.im;

	for (int n = 0; n < 500; n = n + 1) {
		if (n >= maxIter) { break; }

		// Compute z^(intDeg-1) via repeated df64 complex multiplication
		Df64Complex pw = Df64Complex(df64_from(1.0), df64_from(0.0));
		for (int j = 0; j < 7; j = j + 1) {
			if (j >= intDeg - 1) { break; }
			pw = df64_cmul(pw, Df64Complex(zr_df, zi_df));
		}

		// z^intDeg = z^(intDeg-1) * z
		Df64Complex zn = df64_cmul(pw, Df64Complex(zr_df, zi_df));

		// f(z) = z^n - 1
		vec2 fzr = df64_sub(zn.re, df64_from(1.0));
		vec2 fzi = zn.im;

		// f'(z) = n * z^(n-1)
		vec2 fpzr = df64_mul_f(pw.re, float(intDeg));
		vec2 fpzi = df64_mul_f(pw.im, float(intDeg));

		// Degenerate derivative guard
		float fpzr_f = df64_to_float(fpzr);
		float fpzi_f = df64_to_float(fpzi);
		if (fpzr_f * fpzr_f + fpzi_f * fpzi_f < 1e-20) { break; }

		// delta = f(z) / f'(z) via df64 complex division
		float denom = fpzr_f * fpzr_f + fpzi_f * fpzi_f;
		float inv_denom = 1.0 / denom;
		vec2 nr = df64_add(df64_mul(fzr, fpzr), df64_mul(fzi, fpzi));
		vec2 ni = df64_sub(df64_mul(fzi, fpzr), df64_mul(fzr, fpzi));
		vec2 dr = df64_mul_f(nr, inv_denom);
		vec2 di = df64_mul_f(ni, inv_denom);

		// z = z - relaxation * delta
		zr_df = df64_sub(zr_df, df64_mul_f(dr, effRelax));
		zi_df = df64_sub(zi_df, df64_mul_f(di, effRelax));

		// Divergence check
		float zx = df64_to_float(zr_df);
		float zy = df64_to_float(zi_df);
		if (zx * zx + zy * zy > bailout) { break; }

		// Convergence check
		for (int ck = 0; ck < 8; ck = ck + 1) {
			if (ck >= numRoots) { break; }
			float dx = zx - roots[ck].x;
			float dy = zy - roots[ck].y;
			float d = sqrt(dx * dx + dy * dy);
			if (d < toleranceU) {
				convergedRoot = ck;
				convergeDist = d;
				break;
			}
		}
		if (convergedRoot >= 0) { break; }

		iter = iter + 1.0;
	}

	// --- Smooth iteration count ---

	float smoothIter = iter;
	if (convergedRoot >= 0 && convergeDist > 0.0 && convergeDist < toleranceU) {
		smoothIter = iter - log2(log(convergeDist) / log(toleranceU));
	}

	// --- Output mapping ---

	float value = 0.0;
	float maxIterF = float(maxIter);
	float numRootsF = float(numRoots);

	if (outMode == 0) {
		value = smoothIter / maxIterF;
	} else if (outMode == 1) {
		if (convergedRoot >= 0) {
			value = float(convergedRoot) / numRootsF;
		}
	} else {
		if (convergedRoot >= 0) {
			value = (float(convergedRoot) + smoothIter / maxIterF) / numRootsF;
		}
	}

	if (doInvert) { value = 1.0 - value; }

	frag = vec4(vec3(value), 1.0);
}
