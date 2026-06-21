#version 450
// filter/spatter — ported PIXEL-IDENTICALLY from wgsl/spatter.wgsl. Multi-layer paint
// spatter: random values at integer grid points get pow(x,4) at the grid, then are
// upsampled (bicubic / bilinear / cosine) into exp-FBM smear/dots/specks layers,
// combined, broken by a ridged layer, density-scaled, hard-stepped at 0.5, and color-
// blended. Single render pass (progName "spatter").
//
// No-layout effect (spatter.json has no uniformLayout): the backend SYNTHESIZES the
// Params UBO and injects `#define <name> data[slot].comp` for the engine globals and
// every param uniform, in JSON declaration order: color (vec3, 3 comps), density, alpha,
// seed. We use the bare names directly. No helper parameter shares an injected name
// (helpers use pos/sd/uv/freq), so there is NO reserved-name collision.
//
// COORDINATE NOTE: ported from WGSL (top-left, no Y-flip): uv = gl_FragCoord.xy / texSize,
// aspect = texSize.x/texSize.y, nUV = uv*vec2(aspect,1). The WGSL forms uv from
// `(pos + tileOffset) / fullResolution`; for the (single-frame, non-tiling) parity path
// tileOffset=(0,0) and fullResolution==texSize, so that reduces to gl_FragCoord.xy/texSize
// — we do not reproduce the tiling remap. WGSL `u32(seed)` → `uint(seed)`. The integer
// grid hashing/cubic interpolation is reproduced verbatim (no arithmetic reassociation).
layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

// --- PCG PRNG ---

uvec3 pcg3(uvec3 v) {
	v = v * 1664525u + 1013904223u;
	v.x += v.y * v.z;
	v.y += v.z * v.x;
	v.z += v.x * v.y;
	v = v ^ (v >> uvec3(16u));
	v.x += v.y * v.z;
	v.y += v.z * v.x;
	v.z += v.x * v.y;
	return v;
}

uint pcg(uint v) {
	return pcg3(uvec3(v, 0u, 0u)).x;
}

float hashf(uint h) {
	return float(pcg3(uvec3(h, 0u, 0u)).x) / float(0xffffffffu);
}

// --- Grid value: hash at integer grid point ---

float gridVal(ivec2 p, uint sd) {
	uvec3 h = pcg3(uvec3(uint(p.x + 32768), uint(p.y + 32768), sd));
	return float(h.x) / float(0xffffffffu);
}

// --- Catmull-Rom cubic interpolation helper ---

float cubic(float a, float b, float c, float d, float t) {
	float t2 = t * t;
	float t3 = t2 * t;
	return 0.5 * ((2.0 * b) + (-a + c) * t + (2.0 * a - 5.0 * b + 4.0 * c - d) * t2 + (-a + 3.0 * b - 3.0 * c + d) * t3);
}

// --- Bicubic exp grid (Catmull-Rom, 4x4 neighborhood) ---

float bicubicExpGrid(vec2 pos, uint sd) {
	ivec2 ip = ivec2(floor(pos));
	vec2 fp = fract(pos);

	float row0;
	float row1;
	float row2;
	float row3;

	float g00 = pow(gridVal(ivec2(ip.x - 1, ip.y - 1), sd), 4.0);
	float g10 = pow(gridVal(ivec2(ip.x,     ip.y - 1), sd), 4.0);
	float g20 = pow(gridVal(ivec2(ip.x + 1, ip.y - 1), sd), 4.0);
	float g30 = pow(gridVal(ivec2(ip.x + 2, ip.y - 1), sd), 4.0);
	row0 = cubic(g00, g10, g20, g30, fp.x);

	float g01 = pow(gridVal(ivec2(ip.x - 1, ip.y), sd), 4.0);
	float g11 = pow(gridVal(ivec2(ip.x,     ip.y), sd), 4.0);
	float g21 = pow(gridVal(ivec2(ip.x + 1, ip.y), sd), 4.0);
	float g31 = pow(gridVal(ivec2(ip.x + 2, ip.y), sd), 4.0);
	row1 = cubic(g01, g11, g21, g31, fp.x);

	float g02 = pow(gridVal(ivec2(ip.x - 1, ip.y + 1), sd), 4.0);
	float g12 = pow(gridVal(ivec2(ip.x,     ip.y + 1), sd), 4.0);
	float g22 = pow(gridVal(ivec2(ip.x + 1, ip.y + 1), sd), 4.0);
	float g32 = pow(gridVal(ivec2(ip.x + 2, ip.y + 1), sd), 4.0);
	row2 = cubic(g02, g12, g22, g32, fp.x);

	float g03 = pow(gridVal(ivec2(ip.x - 1, ip.y + 2), sd), 4.0);
	float g13 = pow(gridVal(ivec2(ip.x,     ip.y + 2), sd), 4.0);
	float g23 = pow(gridVal(ivec2(ip.x + 1, ip.y + 2), sd), 4.0);
	float g33 = pow(gridVal(ivec2(ip.x + 2, ip.y + 2), sd), 4.0);
	row3 = cubic(g03, g13, g23, g33, fp.x);

	return clamp(cubic(row0, row1, row2, row3, fp.y), 0.0, 1.0);
}

// --- Bilinear exp grid (2x2 neighborhood) ---

float bilinearExpGrid(vec2 pos, uint sd) {
	ivec2 ip = ivec2(floor(pos));
	vec2 fp = fract(pos);

	float v00 = pow(gridVal(ip, sd), 4.0);
	float v10 = pow(gridVal(ivec2(ip.x + 1, ip.y), sd), 4.0);
	float v01 = pow(gridVal(ivec2(ip.x, ip.y + 1), sd), 4.0);
	float v11 = pow(gridVal(ivec2(ip.x + 1, ip.y + 1), sd), 4.0);

	float mx0 = mix(v00, v10, fp.x);
	float mx1 = mix(v01, v11, fp.x);
	return mix(mx0, mx1, fp.y);
}

// --- Cosine exp grid (2x2 neighborhood with cosine interpolation) ---

float cosineExpGrid(vec2 pos, uint sd) {
	ivec2 ip = ivec2(floor(pos));
	vec2 fp = fract(pos);

	float tx = (1.0 - cos(fp.x * 3.14159265358979)) * 0.5;
	float ty = (1.0 - cos(fp.y * 3.14159265358979)) * 0.5;

	float v00 = pow(gridVal(ip, sd), 4.0);
	float v10 = pow(gridVal(ivec2(ip.x + 1, ip.y), sd), 4.0);
	float v01 = pow(gridVal(ivec2(ip.x, ip.y + 1), sd), 4.0);
	float v11 = pow(gridVal(ivec2(ip.x + 1, ip.y + 1), sd), 4.0);

	float mx0 = mix(v00, v10, tx);
	float mx1 = mix(v01, v11, tx);
	return mix(mx0, mx1, ty);
}

// --- FBM functions ---

// 6-octave exp FBM with bicubic interpolation (smear layer)
float expFbm6Bicubic(vec2 uv, vec2 freq, uint sd) {
	float a = 0.0;
	a = a + bicubicExpGrid(uv * freq,        sd          ) * 0.5;
	a = a + bicubicExpGrid(uv * freq * 2.0,  sd + 10000u ) * 0.25;
	a = a + bicubicExpGrid(uv * freq * 4.0,  sd + 20000u ) * 0.125;
	a = a + bicubicExpGrid(uv * freq * 8.0,  sd + 30000u ) * 0.0625;
	a = a + bicubicExpGrid(uv * freq * 16.0, sd + 40000u ) * 0.03125;
	a = a + bicubicExpGrid(uv * freq * 32.0, sd + 50000u ) * 0.015625;
	return a / 0.984375;
}

// 4-octave exp FBM with bilinear interpolation (dots & specks)
float expFbm4Bilinear(vec2 uv, vec2 freq, uint sd) {
	float a = 0.0;
	a = a + bilinearExpGrid(uv * freq,        sd          ) * 0.5;
	a = a + bilinearExpGrid(uv * freq * 2.0,  sd + 10000u ) * 0.25;
	a = a + bilinearExpGrid(uv * freq * 4.0,  sd + 20000u ) * 0.125;
	a = a + bilinearExpGrid(uv * freq * 8.0,  sd + 30000u ) * 0.0625;
	return a / 0.9375;
}

// 3-octave exp+ridged FBM with cosine interpolation (removal layer)
float expRidgedFbm3Cosine(vec2 uv, vec2 freq, uint sd) {
	float a = 0.0;
	float v;
	v = cosineExpGrid(uv * freq,        sd          );
	a = a + (1.0 - abs(2.0 * v - 1.0)) * 0.5;
	v = cosineExpGrid(uv * freq * 2.0,  sd + 10000u );
	a = a + (1.0 - abs(2.0 * v - 1.0)) * 0.25;
	v = cosineExpGrid(uv * freq * 4.0,  sd + 20000u );
	a = a + (1.0 - abs(2.0 * v - 1.0)) * 0.125;
	return a / 0.875;
}

void main() {
	vec2 texSize = vec2(textureSize(inputTex, 0));
	vec2 uv = gl_FragCoord.xy / texSize;
	vec4 base = texture(inputTex, uv);

	// Aspect-corrected UV for noise sampling.
	float aspect = texSize.x / texSize.y;
	vec2 nUV = uv * vec2(aspect, 1.0);

	uint s = uint(seed) * 17u;
	vec3 user_color = color;

	// Seed-derived random frequencies (matching Python ranges).
	float smearFreq = mix(3.0, 6.0, hashf(pcg(s + 10u)));
	float dotFreq   = mix(32.0, 64.0, hashf(pcg(s + 50u)));
	float speckFreq = mix(150.0, 200.0, hashf(pcg(s + 90u)));
	float ridgeFreq = mix(2.0, 3.0, hashf(pcg(s + 130u)));

	// -- Layer 1: Large smear (6-oct bicubic exp FBM, domain warped) --
	float warpFreqX = mix(2.0, 3.0, hashf(pcg(s + 160u)));
	float warpFreqY = mix(1.0, 3.0, hashf(pcg(s + 170u)));
	float warpX = bilinearExpGrid(nUV * vec2(warpFreqX, warpFreqY), s + 200u);
	float warpY = bilinearExpGrid(nUV * vec2(warpFreqX, warpFreqY), s + 300u);
	float disp = 1.0 + hashf(pcg(s + 150u));
	vec2 warpedUV = nUV + (vec2(warpX, warpY) - 0.5) * disp * 0.12;
	float smear = expFbm6Bicubic(warpedUV, vec2(smearFreq), s + 100u);

	// -- Layer 2: Medium dots (4-oct bilinear exp FBM + brightness/contrast) --
	float dots = expFbm4Bilinear(nUV, vec2(dotFreq), s + 43u);
	dots = clamp(4.0 * dots - 1.6, 0.0, 1.0);

	// -- Layer 3: Fine specks (4-oct bilinear exp FBM + brightness/contrast) --
	float specks = expFbm4Bilinear(nUV, vec2(speckFreq), s + 71u);
	specks = clamp(4.0 * specks - 2.0, 0.0, 1.0);

	// Combine: max of layers.
	float combined = max(smear, max(dots, specks));

	// Subtract exp+ridged cosine noise for breaks.
	float ridge = expRidgedFbm3Cosine(nUV, vec2(ridgeFreq), s + 89u);
	combined = max(0.0, combined - ridge);

	// Density scales before threshold.
	combined = combined * (0.5 + density * 2.0);

	// Sharp step at 0.5 (Python blend_layers with feather=0.005).
	float mask = step(0.5, combined);

	// Color blend.
	vec3 colored = base.rgb * user_color;
	vec3 result = mix(base.rgb, mix(base.rgb, colored, mask), alpha);

	frag = vec4(result, base.a);
}
