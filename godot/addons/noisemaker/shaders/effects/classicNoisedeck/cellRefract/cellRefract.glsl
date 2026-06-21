#version 450
// classicNoisedeck/cellRefract — cell-noise distance-field refraction with optional
// convolution kernels. Ported PIXEL-IDENTICALLY from the canonical WGSL source:
//   shaders/effects/classicNoisedeck/cellRefract/wgsl/cellRefract.wgsl
// (cross-checked against the reference GLSL; the reference GLSL's `aspectRatio` uses
// fullResolution — a tiling remap the WGSL lacks — NOT reproduced. WGSL uses
// u.resolution, so we use the engine `resolution`.)
//
// Single render pass (program "cellRefract"). Input-taker: reads inputTex (no-layout
// effect, cellRefract.json declares no uniformLayout). The backend SYNTHESIZES the
// Params UBO and injects `#define <name> data[slot].comp` for the 8 engine globals plus
// every param's `uniform` field: refractAmt, direction, wrap, speed, scale, cellScale,
// cellSmooth, variation, effectWidth (seed too). SHAPE and KERNEL are compile-time
// integer #defines injected by the runtime from the graph's `defines` (cellRefract.json
// globals.{shape,kernel}.define) — kept here as BARE identifiers, never declared. Engine
// `time`, `resolution` read (bare). Input texture set 0, binding 1.
//
// ⚠️ RESERVED-NAME COLLISIONS (injected #defines vs reference symbols) — pure symbol
// renames, no behavior change:
//   - WGSL helper function `aspectRatio()` collides with the engine #define → renamed to
//     `aspectRatioFn` (call site updated).
//   - local `let speed` inside cells() collides with the `speed` param #define → `spd`.
//   - shapeFn()'s `scale` parameter collides with the `scale` param #define → `scaleArg`.
//
// WGSL `select(a,b,cond)` → `cond ? b : a` (operands reversed). `atan2(x,y)` → `atan(x,y)`
// (arg order literal). `%` → `mod()`. WGSL vecNf/vec3u → GLSL vecN/uvec3. `array<f32,9>`
// → GLSL `float[9]`. gl_FragCoord top-left (Godot/Vulkan, matches WGSL) — NO Y-flip.
layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

const float CR_PI = 3.14159265359;
const float CR_TAU = 6.28318530718;

float aspectRatioFn() {
	return resolution.x / resolution.y;
}

// PCG PRNG
uvec3 pcg(uvec3 v_in) {
	uvec3 v = v_in * 1664525u + 1013904223u;
	v.x += v.y * v.z;
	v.y += v.z * v.x;
	v.z += v.x * v.y;
	v ^= v >> uvec3(16u);
	v.x += v.y * v.z;
	v.y += v.z * v.x;
	v.z += v.x * v.y;
	return v;
}

vec3 prng(vec3 p) {
	return vec3(pcg(uvec3(p))) / float(0xffffffffu);
}

float mapRange(float value, float inMin, float inMax, float outMin, float outMax) {
	return outMin + (outMax - outMin) * (value - inMin) / (inMax - inMin);
}

vec3 hsv2rgb(vec3 hsv) {
	float h = fract(hsv.x);
	float s = hsv.y;
	float v = hsv.z;
	float c = v * s;
	float x = c * (1.0 - abs(fract(h * 6.0) * 2.0 - 1.0));
	float m = v - c;
	vec3 rgb;
	if (h < 1.0 / 6.0) { rgb = vec3(c, x, 0.0); }
	else if (h < 2.0 / 6.0) { rgb = vec3(x, c, 0.0); }
	else if (h < 3.0 / 6.0) { rgb = vec3(0.0, c, x); }
	else if (h < 4.0 / 6.0) { rgb = vec3(0.0, x, c); }
	else if (h < 5.0 / 6.0) { rgb = vec3(x, 0.0, c); }
	else { rgb = vec3(c, 0.0, x); }
	return rgb + vec3(m);
}

vec3 rgb2hsv(vec3 rgb) {
	float maxC = max(rgb.r, max(rgb.g, rgb.b));
	float minC = min(rgb.r, min(rgb.g, rgb.b));
	float delta = maxC - minC;
	float h = 0.0;
	if (delta != 0.0) {
		if (maxC == rgb.r) { h = mod((rgb.g - rgb.b) / delta, 6.0) / 6.0; }
		else if (maxC == rgb.g) { h = ((rgb.b - rgb.r) / delta + 2.0) / 6.0; }
		else { h = ((rgb.r - rgb.g) / delta + 4.0) / 6.0; }
	}
	float s = (maxC != 0.0) ? delta / maxC : 0.0;
	return vec3(h, s, maxC);
}

vec3 desaturate(vec3 color) {
	float avg = 0.2126 * color.r + 0.7152 * color.g + 0.0722 * color.b;
	return vec3(avg);
}

vec3 convolve(vec2 uv, float kernel[9], bool divide) {
	vec2 steps = 1.0 / resolution;
	vec2 offsets[9] = vec2[9](
		vec2(-steps.x, -steps.y), vec2(0.0, -steps.y), vec2(steps.x, -steps.y),
		vec2(-steps.x, 0.0), vec2(0.0, 0.0), vec2(steps.x, 0.0),
		vec2(-steps.x, steps.y), vec2(0.0, steps.y), vec2(steps.x, steps.y)
	);
	float kernelWeight = 0.0;
	vec3 conv = vec3(0.0);
	float ew = effectWidth;
	for (int i = 0; i < 9; i++) {
		vec3 color = texture(inputTex, uv + offsets[i] * ew).rgb;
		conv += color * kernel[i];
		kernelWeight += kernel[i];
	}
	if (divide && kernelWeight != 0.0) { conv /= kernelWeight; }
	return clamp(conv, vec3(0.0), vec3(1.0));
}

vec3 derivatives(vec3 color, vec2 uv, bool divide) {
	float deriv_x[9] = float[9](0.0, 0.0, 0.0, 0.0, 1.0, -1.0, 0.0, 0.0, 0.0);
	float deriv_y[9] = float[9](0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, -1.0, 0.0);
	vec3 s1 = convolve(uv, deriv_x, divide);
	vec3 s2 = convolve(uv, deriv_y, divide);
	float dist = distance(s1, s2);
	return color * dist;
}

vec3 sobel(vec3 color, vec2 uv) {
	float sobel_x[9] = float[9](1.0, 0.0, -1.0, 2.0, 0.0, -2.0, 1.0, 0.0, -1.0);
	float sobel_y[9] = float[9](1.0, 2.0, 1.0, 0.0, 0.0, 0.0, -1.0, -2.0, -1.0);
	vec3 s1 = convolve(uv, sobel_x, false);
	vec3 s2 = convolve(uv, sobel_y, false);
	float dist = distance(s1, s2);
	return color * dist;
}

vec3 shadow(vec3 color_in, vec2 uv) {
	float sobel_x[9] = float[9](1.0, 0.0, -1.0, 2.0, 0.0, -2.0, 1.0, 0.0, -1.0);
	float sobel_y[9] = float[9](1.0, 2.0, 1.0, 0.0, 0.0, 0.0, -1.0, -2.0, -1.0);
	vec3 color = rgb2hsv(color_in);
	vec3 x = convolve(uv, sobel_x, false);
	vec3 y = convolve(uv, sobel_y, false);
	float shade_dist = distance(x, y);
	float highlight = shade_dist * shade_dist;
	float shade = (1.0 - ((1.0 - color.z) * (1.0 - highlight))) * shade_dist;
	float alpha = 0.75;
	color = vec3(color.x, color.y, mix(color.z, shade, alpha));
	return hsv2rgb(color);
}

vec3 outline(vec3 color, vec2 uv) {
	float sobel_x[9] = float[9](1.0, 0.0, -1.0, 2.0, 0.0, -2.0, 1.0, 0.0, -1.0);
	float sobel_y[9] = float[9](1.0, 2.0, 1.0, 0.0, 0.0, 0.0, -1.0, -2.0, -1.0);
	vec3 s1 = convolve(uv, sobel_x, false);
	vec3 s2 = convolve(uv, sobel_y, false);
	float dist = distance(s1, s2);
	return max(color - dist, vec3(0.0));
}

vec3 convolutionKernel(vec3 color, vec2 uv) {
	float emboss[9] = float[9](-2.0, -1.0, 0.0, -1.0, 1.0, 1.0, 0.0, 1.0, 2.0);
	float sharpen[9] = float[9](-1.0, 0.0, -1.0, 0.0, 5.0, 0.0, -1.0, 0.0, -1.0);
	float blur[9] = float[9](1.0, 2.0, 1.0, 2.0, 4.0, 2.0, 1.0, 2.0, 1.0);
	float edge2[9] = float[9](-1.0, 0.0, -1.0, 0.0, 4.0, 0.0, -1.0, 0.0, -1.0);

	if (KERNEL == 1) { return convolve(uv, blur, true); }
	else if (KERNEL == 2) { return derivatives(color, uv, true); }
	else if (KERNEL == 120) { return clamp(derivatives(color, uv, false) * 2.5, vec3(0.0), vec3(1.0)); }
	else if (KERNEL == 3) { return color * convolve(uv, edge2, true); }
	else if (KERNEL == 4) { return convolve(uv, emboss, false); }
	else if (KERNEL == 5) { return outline(color, uv); }
	else if (KERNEL == 6) { return shadow(color, uv); }
	else if (KERNEL == 7) { return convolve(uv, sharpen, false); }
	else if (KERNEL == 8) { return sobel(color, uv); }
	else if (KERNEL == 9) { return max(color, convolve(uv, edge2, true)); }
	return color;
}

// WGSL atan2(st.x, st.y) — arg order copied LITERALLY.
float polarShape(vec2 st, int sides) {
	float a = atan(st.x, st.y) + CR_PI;
	float r = CR_TAU / float(sides);
	return cos(floor(0.5 + a / r) * r - a) * length(st);
}

float shapeFn(vec2 st_in, vec2 offset, float scaleArg) {
	vec2 st = st_in + offset;
	float d = 1.0;
	if (SHAPE == 0) { d = length(st * 1.2); }
	else if (SHAPE == 2) { d = polarShape(st * 1.2, 6); }
	else if (SHAPE == 3) { d = polarShape(st * 1.2, 8); }
	else if (SHAPE == 4) { d = polarShape(st * 1.5, 4); }
	else if (SHAPE == 6) { d = polarShape(vec2(st.x, st.y + 0.05) * 1.5, 3); }
	return d * scaleArg;
}

float smin(float a, float b, float k) {
	if (k == 0.0) { return min(a, b); }
	float h = max(k - abs(a - b), 0.0) / k;
	return min(a, b) - h * h * k * 0.25;
}

float cells(vec2 st_in, float freq, float cellSize) {
	vec2 st = st_in * freq;
	// GLSL uses prng(vec3(float(seed))), i.e. the seed splatted to (seed,seed,seed).
	st += prng(vec3(float(int(seed)))).xy;
	vec2 i = floor(st);
	vec2 f = fract(st);
	float d = 1.0;
	for (int y = -2; y <= 2; y++) {
		for (int x = -2; x <= 2; x++) {
			vec2 n = vec2(float(x), float(y));
			vec2 wrap_coord = i + n;
			vec2 point = prng(vec3(wrap_coord, float(int(seed)))).xy;
			vec3 r1 = prng(vec3(float(int(seed)), wrap_coord)) * 0.5 - 0.25;
			vec3 r2 = prng(vec3(wrap_coord, float(int(seed)))) * 2.0 - 1.0;
			float spd = floor(speed);
			point += vec2(sin(time * CR_TAU * spd + r2.x) * r1.x, cos(time * CR_TAU * spd + r2.y) * r1.y);
			vec2 diff = n + point - f;
			float dist;
			if (SHAPE == 1) {
				dist = (abs(n.x + point.x - f.x) + abs(n.y + point.y - f.y)) * cellSize;
			} else {
				dist = shapeFn(vec2(diff.x, -diff.y), vec2(0.0), cellSize);
			}
			dist += r1.z * (variation * 0.01);
			d = smin(d, dist, cellSmooth * 0.01);
		}
	}
	return d;
}

vec3 posterize(vec3 color, float levIn) {
	float lev = levIn;
	if (lev == 0.0) { return color; }
	else if (lev == 1.0) { lev = 2.0; }
	vec3 c = clamp(color, vec3(0.0), vec3(0.99));
	return (floor(c * lev) + 0.5) / lev;
}

vec3 pixellate(vec2 uv, float size) {
	if (size <= 1.0) { return texture(inputTex, uv).rgb; }
	float dx = size / resolution.x;
	float dy = size / resolution.y;
	vec2 coord = vec2(dx * floor(uv.x / dx), dy * floor(uv.y / dy));
	return texture(inputTex, coord).rgb;
}

void main() {
	vec2 st = gl_FragCoord.xy / resolution;

	float freq = mapRange(scale, 1.0, 100.0, 20.0, 1.0);
	float cellSize = mapRange(cellScale, 1.0, 100.0, 3.0, 0.75);
	float d = cells(st * vec2(aspectRatioFn(), 1.0), freq, cellSize);
	float refAmt = mapRange(refractAmt, 0.0, 100.0, 0.0, 0.125);
	float refLen = d + direction / 360.0;
	st.x += cos(refLen * CR_TAU) * refAmt;
	st.y += sin(refLen * CR_TAU) * refAmt;

	if (wrap == 1) {
		st = fract(st);
	}

	vec4 color = texture(inputTex, st);
	float ew = effectWidth;
	if (ew != 0.0 && KERNEL != 0) {
		if (KERNEL == 100) {
			color = vec4(pixellate(st, ew * 4.0), color.a);
		} else if (KERNEL == 110) {
			color = vec4(posterize(color.rgb, floor(mapRange(ew, 0.0, 10.0, 0.0, 20.0))), color.a);
		} else {
			color = vec4(convolutionKernel(color.rgb, st), color.a);
		}
	}

	frag = color;
}
