#version 450
// filter/smooth program "smoothBlend" — ported from wgsl/smoothBlend.wgsl.
// Pass 2 of 2. Dispatches on smoothType: 0=MSAA rotated-grid supersampling,
// 1=SMAA morphological edge blend, 2=edge-selective Gaussian blur; then lerps
// original -> result by `strength`. Output target is outputTex.
// No-layout effect: backend injects the Params UBO + `#define smoothType …`/
// `strength …`/`threshold …`/`radius …`/`samples …`/`searchSteps …` and engine
// globals. Inputs bound at set 0 in pass.inputs order: inputTex = binding 1,
// edgeTex (_smoothEdges) = binding 2. Backend sampler is NEAREST + clamp-to-edge
// (matches the reference WebGL2 render-target NEAREST), so the MSAA path's
// texture() bilinear samples and the integer texelFetch reads both reproduce the
// golden exactly.
//
// WGSL sampling distinction preserved verbatim:
//  * textureSampleLevel(inputTex, sampler, uv, 0.0)  -> texture(inputTex, uv)
//    (MSAA path + the per-pixel `original` read; bilinear-class sample).
//  * textureLoad(tex, coordI32, 0)                    -> texelFetch(tex, coord, 0)
//    (SMAA/Blur paths on inputTex AND edgeTex; integer-texel fetch, no filtering).
//
// Reserved-name collisions (param names injected as `#define`s): WGSL locals
// `smoothType`/`strength`/`threshold`/`samples`/`searchSteps`/`radius` and helper
// params `threshold`/`radius`/`searchSteps`/`samples` are renamed to plain locals
// (localType/localStrength/localThreshold/.../thr/rad/...). Pure symbol renames,
// no behavior change — the HLSL port does the same. The bare param names survive
// only at the main() use sites where the `#define` must resolve.
layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(set = 0, binding = 2) uniform sampler2D edgeTex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

const vec3 LUMA_WEIGHTS = vec3(0.299, 0.587, 0.114);

float luminance(vec3 rgb) {
	return dot(rgb, LUMA_WEIGHTS);
}

// --- MSAA: rotated grid sample offsets ---

vec2 sampleOffset2x(int i) {
	if (i == 0) { return vec2(-0.25, 0.25); }
	return vec2(0.25, -0.25);
}

vec2 sampleOffset4x(int i) {
	if (i == 0) { return vec2(-0.125, -0.375); }
	if (i == 1) { return vec2( 0.375, -0.125); }
	if (i == 2) { return vec2(-0.375,  0.125); }
	return vec2( 0.125,  0.375);
}

vec2 sampleOffset8x(int i) {
	if (i == 0) { return vec2(-0.375, -0.375); }
	if (i == 1) { return vec2( 0.125, -0.375); }
	if (i == 2) { return vec2(-0.125, -0.125); }
	if (i == 3) { return vec2( 0.375, -0.125); }
	if (i == 4) { return vec2(-0.375,  0.125); }
	if (i == 5) { return vec2( 0.125,  0.125); }
	if (i == 6) { return vec2(-0.125,  0.375); }
	return vec2( 0.375,  0.375);
}

vec2 getSampleOffset(int i, int count) {
	if (count <= 2) { return sampleOffset2x(i); }
	if (count <= 4) { return sampleOffset4x(i); }
	return sampleOffset8x(i);
}

vec4 msaaBlend(vec2 uv, vec2 texelSize, float thr, int sampleCount, float rad) {
	// textureSampleLevel(...,0.0) -> bilinear-class sample at mip 0.
	vec4 center = texture(inputTex, uv);

	// Threshold check: skip AA for low-contrast pixels
	float L = luminance(center.rgb);
	float Ln = luminance(texture(inputTex, uv + vec2(0.0, -texelSize.y)).rgb);
	float Ls = luminance(texture(inputTex, uv + vec2(0.0,  texelSize.y)).rgb);
	float Lw = luminance(texture(inputTex, uv + vec2(-texelSize.x, 0.0)).rgb);
	float Le = luminance(texture(inputTex, uv + vec2( texelSize.x, 0.0)).rgb);

	float maxDiff = max(max(abs(L - Ln), abs(L - Ls)),
	                    max(abs(L - Lw), abs(L - Le)));

	if (maxDiff < thr) {
		return center;
	}

	// Supersample at radius-scaled offsets (bilinear filtering via sampler)
	vec4 sum = vec4(0.0);
	for (int i = 0; i < 8; i = i + 1) {
		if (i >= sampleCount) { break; }
		vec2 offset = getSampleOffset(i, sampleCount) * rad;
		sum = sum + texture(inputTex, uv + offset * texelSize);
	}
	return sum / float(sampleCount);
}

// --- SMAA: morphological edge search and blending ---

float searchEdge(ivec2 coord, ivec2 dir, ivec2 maxCoord, int component, int maxSteps) {
	for (int i = 1; i <= 32; i = i + 1) {
		if (i > maxSteps) { break; }
		ivec2 sampleCoord = clamp(coord + dir * i, ivec2(0), maxCoord);
		float edge;
		if (component == 0) {
			edge = texelFetch(edgeTex, sampleCoord, 0).r;
		} else {
			edge = texelFetch(edgeTex, sampleCoord, 0).g;
		}
		if (edge < 0.5) {
			return float(i - 1);
		}
	}
	return float(maxSteps);
}

vec4 smaaBlend(vec2 fragPos, int searchStepsArg, float rad) {
	ivec2 size = ivec2(textureSize(inputTex, 0));
	ivec2 coord = ivec2(int(fragPos.x), int(fragPos.y));
	ivec2 maxCoord = size - ivec2(1);

	vec4 edges = texelFetch(edgeTex, coord, 0);
	float edgeH = edges.r;
	float edgeV = edges.g;

	vec4 center = texelFetch(inputTex, coord, 0);
	if (edgeH < 0.5 && edgeV < 0.5) {
		return center;
	}

	vec4 blended = center;

	// Horizontal edge: search left/right, blend with vertical neighbor
	if (edgeH > 0.5) {
		float distLeft  = searchEdge(coord, ivec2(-1, 0), maxCoord, 0, searchStepsArg);
		float distRight = searchEdge(coord, ivec2( 1, 0), maxCoord, 0, searchStepsArg);
		float edgeLength = distLeft + distRight + 1.0;

		// Stronger blend for shorter edges (more jaggy), scaled by radius
		float weight = clamp(rad * 0.5 / sqrt(edgeLength), 0.0, 0.5);

		vec4 neighbor = texelFetch(inputTex, clamp(coord + ivec2(0, 1), ivec2(0), maxCoord), 0);
		blended = mix(blended, neighbor, weight);
	}

	// Vertical edge: search up/down, blend with horizontal neighbor
	if (edgeV > 0.5) {
		float distUp   = searchEdge(coord, ivec2(0, -1), maxCoord, 1, searchStepsArg);
		float distDown = searchEdge(coord, ivec2(0,  1), maxCoord, 1, searchStepsArg);
		float edgeLength = distUp + distDown + 1.0;

		float weight = clamp(rad * 0.5 / sqrt(edgeLength), 0.0, 0.5);

		vec4 neighbor = texelFetch(inputTex, clamp(coord + ivec2(1, 0), ivec2(0), maxCoord), 0);
		blended = mix(blended, neighbor, weight);
	}

	return blended;
}

// --- Blur: edge-selective Gaussian ---

vec4 edgeBlur(vec2 fragPos, float rad) {
	ivec2 size = ivec2(textureSize(inputTex, 0));
	ivec2 coord = ivec2(int(fragPos.x), int(fragPos.y));
	ivec2 maxCoord = size - ivec2(1);

	vec4 edges = texelFetch(edgeTex, coord, 0);
	vec4 center = texelFetch(inputTex, coord, 0);

	if (edges.r < 0.5 && edges.g < 0.5) {
		return center;
	}

	int r = int(ceil(rad));
	float sigma = rad * 0.5;
	float sigma2 = 2.0 * sigma * sigma;

	vec4 sum = center;
	float totalWeight = 1.0;

	for (int dy = -4; dy <= 4; dy = dy + 1) {
		for (int dx = -4; dx <= 4; dx = dx + 1) {
			if (dx == 0 && dy == 0) { continue; }
			if (abs(dx) > r || abs(dy) > r) { continue; }

			float d = float(dx * dx + dy * dy);
			float w = exp(-d / sigma2);

			sum = sum + texelFetch(inputTex, clamp(coord + ivec2(dx, dy), ivec2(0), maxCoord), 0) * w;
			totalWeight = totalWeight + w;
		}
	}

	return sum / totalWeight;
}

void main() {
	int localType = int(smoothType);
	float localStrength = strength;
	float localThreshold = threshold;
	int localSamples = int(samples);
	int localSearchSteps = int(searchSteps);
	float localRadius = radius;

	vec2 pos = gl_FragCoord.xy;

	vec2 texSize = vec2(textureSize(inputTex, 0));
	vec2 uv = pos / texSize;
	vec2 texelSize = 1.0 / texSize;

	vec4 original = texture(inputTex, uv);
	vec4 result;

	if (localType == 0) {
		result = msaaBlend(uv, texelSize, localThreshold, localSamples, localRadius);
	} else if (localType == 1) {
		result = smaaBlend(pos, localSearchSteps, localRadius);
	} else {
		result = edgeBlur(pos, localRadius);
	}

	frag = mix(original, result, localStrength);
}
