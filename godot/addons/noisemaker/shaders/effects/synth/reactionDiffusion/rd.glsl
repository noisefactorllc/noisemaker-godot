#version 450
// synth/rd — reaction-diffusion display/render pass (mono only), ported from
// reactionDiffusion/wgsl/rd.wgsl (top-left origin = Godot/Vulkan, no Y-flip).
// Formats the simulation state into grayscale output with selectable smoothing
// (0 constant/nearest, 1 bilinear, 2 hermite/smoothstep, 3 catmull-rom 3x3,
// 4 catmull-rom 4x4, 5 b-spline 3x3, 6 b-spline 4x4, else cosine). Reads the .g channel.
//
// Layout effect: vec4 data[4] (effects/synth/reactionDiffusion.json, uniformLayouts.rd):
//   resolution = data[0].xy, inputIntensity = data[1].x, smoothing = int(data[3].w).
//   (time = data[0].z unused.)
// gl_FragCoord top-left, +0.5 pixel-centered, no Y-flip.
// fbTex (binding 1) is the simulation state; inputTex (binding 2) is sampled in the
// runtime `if (inputIntensity > 0.0)` blend block (not compiler-stripped). The WGSL
// `samp` sampler folds into the combined sampler2D (NEAREST, no mipmaps — LOD always
// 0, so textureSampleLevel(...,0.0) -> plain texture()).
layout(set = 0, binding = 0, std140) uniform Params { vec4 data[4]; };
layout(set = 0, binding = 1) uniform sampler2D fbTex;
layout(set = 0, binding = 2) uniform sampler2D inputTex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

const float PI = 3.14159265359;

float modulo(float a, float b) {
	return a - b * floor(a / b);
}

vec4 quadratic3(vec4 p0, vec4 p1, vec4 p2, float t) {
	float t2 = t * t;

	return p0 * 0.5 * (1.0 - t) * (1.0 - t) +
		   p1 * 0.5 * (-2.0 * t2 + 2.0 * t + 1.0) +
		   p2 * 0.5 * t2;
}

vec4 bicubic4(vec4 p0, vec4 p1, vec4 p2, vec4 p3, float t) {
	float t2 = t * t;
	float t3 = t2 * t;

	float b0 = (1.0 - t) * (1.0 - t) * (1.0 - t) / 6.0;
	float b1 = (3.0 * t3 - 6.0 * t2 + 4.0) / 6.0;
	float b2 = (-3.0 * t3 + 3.0 * t2 + 3.0 * t + 1.0) / 6.0;
	float b3 = t3 / 6.0;

	return p0 * b0 + p1 * b1 + p2 * b2 + p3 * b3;
}

vec4 catmullRom3(vec4 p0, vec4 p1, vec4 p2, float t) {
	float t2 = t * t;
	float t3 = t2 * t;

	vec4 m = 0.5 * (p2 - p0);

	return (2.0*t3 - 3.0*t2 + 1.0) * p1 +
		   (t3 - 2.0*t2 + t) * m +
		   (-2.0*t3 + 3.0*t2) * p2 +
		   (t3 - t2) * m;
}

vec4 catmullRom4(vec4 p0, vec4 p1, vec4 p2, vec4 p3, float t) {
	return p1 + 0.5 * t * (p2 - p0 + t * (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3 + t * (3.0 * (p1 - p2) + p3 - p0)));
}

vec4 quadratic(sampler2D tex, vec2 uv, vec2 texelSize) {
	vec2 uv2 = uv + texelSize;
	vec2 texCoord = uv2 / texelSize;
	vec2 baseCoord = floor(texCoord - 0.5);
	vec2 f = fract(texCoord - 0.5);

	// Sample 3x3 grid centered on the interpolation point
	vec4 v00 = texture(tex, (baseCoord + vec2(-0.5, -0.5)) * texelSize);
	vec4 v10 = texture(tex, (baseCoord + vec2( 0.5, -0.5)) * texelSize);
	vec4 v20 = texture(tex, (baseCoord + vec2( 1.5, -0.5)) * texelSize);

	vec4 v01 = texture(tex, (baseCoord + vec2(-0.5,  0.5)) * texelSize);
	vec4 v11 = texture(tex, (baseCoord + vec2( 0.5,  0.5)) * texelSize);
	vec4 v21 = texture(tex, (baseCoord + vec2( 1.5,  0.5)) * texelSize);

	vec4 v02 = texture(tex, (baseCoord + vec2(-0.5,  1.5)) * texelSize);
	vec4 v12 = texture(tex, (baseCoord + vec2( 0.5,  1.5)) * texelSize);
	vec4 v22 = texture(tex, (baseCoord + vec2( 1.5,  1.5)) * texelSize);

	// Interpolate rows using quadratic B-spline
	vec4 y0 = quadratic3(v00, v10, v20, f.x);
	vec4 y1 = quadratic3(v01, v11, v21, f.x);
	vec4 y2 = quadratic3(v02, v12, v22, f.x);

	// Interpolate columns
	return quadratic3(y0, y1, y2, f.y);
}

vec4 catmullRom3x3(sampler2D tex, vec2 uv, vec2 texelSize) {
	vec2 uv2 = uv + texelSize;
	vec2 texCoord = uv2 / texelSize;
	vec2 baseCoord = floor(texCoord - 1.0);
	vec2 f = fract(texCoord - 1.0);

	// Sample 3x3 grid
	vec4 v00 = texture(tex, (baseCoord + vec2(-0.5, -0.5)) * texelSize);
	vec4 v10 = texture(tex, (baseCoord + vec2( 0.5, -0.5)) * texelSize);
	vec4 v20 = texture(tex, (baseCoord + vec2( 1.5, -0.5)) * texelSize);

	vec4 v01 = texture(tex, (baseCoord + vec2(-0.5,  0.5)) * texelSize);
	vec4 v11 = texture(tex, (baseCoord + vec2( 0.5,  0.5)) * texelSize);
	vec4 v21 = texture(tex, (baseCoord + vec2( 1.5,  0.5)) * texelSize);

	vec4 v02 = texture(tex, (baseCoord + vec2(-0.5,  1.5)) * texelSize);
	vec4 v12 = texture(tex, (baseCoord + vec2( 0.5,  1.5)) * texelSize);
	vec4 v22 = texture(tex, (baseCoord + vec2( 1.5,  1.5)) * texelSize);

	// Interpolate rows using Catmull-Rom
	vec4 y0 = catmullRom3(v00, v10, v20, f.x);
	vec4 y1 = catmullRom3(v01, v11, v21, f.x);
	vec4 y2 = catmullRom3(v02, v12, v22, f.x);

	// Interpolate columns
	return catmullRom3(y0, y1, y2, f.y);
}

vec4 bicubic(sampler2D tex, vec2 uv, vec2 texelSize) {
	vec2 uv2 = uv + texelSize;
	vec2 texCoord = uv2 / texelSize;
	vec2 baseCoord = floor(texCoord - 1.0);
	vec2 f = fract(texCoord - 1.0);

	vec4 row0 = bicubic4(
		texture(tex, (baseCoord + vec2(-0.5, -0.5)) * texelSize),
		texture(tex, (baseCoord + vec2( 0.5, -0.5)) * texelSize),
		texture(tex, (baseCoord + vec2( 1.5, -0.5)) * texelSize),
		texture(tex, (baseCoord + vec2( 2.5, -0.5)) * texelSize),
		f.x
	);

	vec4 row1 = bicubic4(
		texture(tex, (baseCoord + vec2(-0.5,  0.5)) * texelSize),
		texture(tex, (baseCoord + vec2( 0.5,  0.5)) * texelSize),
		texture(tex, (baseCoord + vec2( 1.5,  0.5)) * texelSize),
		texture(tex, (baseCoord + vec2( 2.5,  0.5)) * texelSize),
		f.x
	);

	vec4 row2 = bicubic4(
		texture(tex, (baseCoord + vec2(-0.5,  1.5)) * texelSize),
		texture(tex, (baseCoord + vec2( 0.5,  1.5)) * texelSize),
		texture(tex, (baseCoord + vec2( 1.5,  1.5)) * texelSize),
		texture(tex, (baseCoord + vec2( 2.5,  1.5)) * texelSize),
		f.x
	);

	vec4 row3 = bicubic4(
		texture(tex, (baseCoord + vec2(-0.5,  2.5)) * texelSize),
		texture(tex, (baseCoord + vec2( 0.5,  2.5)) * texelSize),
		texture(tex, (baseCoord + vec2( 1.5,  2.5)) * texelSize),
		texture(tex, (baseCoord + vec2( 2.5,  2.5)) * texelSize),
		f.x
	);

	return bicubic4(row0, row1, row2, row3, f.y);
}

vec4 catmullRom4x4(sampler2D tex, vec2 uv, vec2 texelSize) {
	vec2 uv2 = uv + texelSize;
	vec2 texCoord = uv2 / texelSize;
	vec2 baseCoord = floor(texCoord - 1.0);
	vec2 f = fract(texCoord - 1.0);

	vec4 row0 = catmullRom4(
		texture(tex, (baseCoord + vec2(-0.5, -0.5)) * texelSize),
		texture(tex, (baseCoord + vec2( 0.5, -0.5)) * texelSize),
		texture(tex, (baseCoord + vec2( 1.5, -0.5)) * texelSize),
		texture(tex, (baseCoord + vec2( 2.5, -0.5)) * texelSize),
		f.x
	);

	vec4 row1 = catmullRom4(
		texture(tex, (baseCoord + vec2(-0.5,  0.5)) * texelSize),
		texture(tex, (baseCoord + vec2( 0.5,  0.5)) * texelSize),
		texture(tex, (baseCoord + vec2( 1.5,  0.5)) * texelSize),
		texture(tex, (baseCoord + vec2( 2.5,  0.5)) * texelSize),
		f.x
	);

	vec4 row2 = catmullRom4(
		texture(tex, (baseCoord + vec2(-0.5,  1.5)) * texelSize),
		texture(tex, (baseCoord + vec2( 0.5,  1.5)) * texelSize),
		texture(tex, (baseCoord + vec2( 1.5,  1.5)) * texelSize),
		texture(tex, (baseCoord + vec2( 2.5,  1.5)) * texelSize),
		f.x
	);

	vec4 row3 = catmullRom4(
		texture(tex, (baseCoord + vec2(-0.5,  2.5)) * texelSize),
		texture(tex, (baseCoord + vec2( 0.5,  2.5)) * texelSize),
		texture(tex, (baseCoord + vec2( 1.5,  2.5)) * texelSize),
		texture(tex, (baseCoord + vec2( 2.5,  2.5)) * texelSize),
		f.x
	);

	return catmullRom4(row0, row1, row2, row3, f.y);
}

float cosineMix(float a, float b, float t) {
	float amount = (1.0 - cos(t * 3.141592653589793)) * 0.5;
	return mix(a, b, amount);
}

void main() {
	vec2 resolution = data[0].xy;
	int smoothing = int(data[3].w);
	float inputIntensity = data[1].x * 0.01;

	float intensity = 1.0;

	if (smoothing == 0) {
		ivec2 texSizeI = ivec2(textureSize(fbTex, 0));
		vec2 texSizeF = vec2(float(texSizeI.x), float(texSizeI.y));
		ivec2 coord = ivec2(floor(gl_FragCoord.xy * texSizeF / resolution));
		ivec2 clamped = clamp(coord, ivec2(0), texSizeI - ivec2(1));
		intensity = clamp(texelFetch(fbTex, clamped, 0).g, 0.0, 1.0);
	} else if (smoothing == 2) {
		// hermite (smoothstep)
		vec2 texSize = vec2(textureSize(fbTex, 0));
		vec2 texelPos = (gl_FragCoord.xy * texSize / resolution) - vec2(0.5);
		vec2 base = floor(texelPos);
		vec2 weights = fract(texelPos);
		vec2 next = base + vec2(1.0);

		ivec2 texSizeI = ivec2(textureSize(fbTex, 0));
		ivec2 minIdx = ivec2(0);
		ivec2 maxIdx = texSizeI - ivec2(1);

		ivec2 baseIdx = clamp(ivec2(base), minIdx, maxIdx);
		ivec2 nextIdx = clamp(ivec2(next), minIdx, maxIdx);

		float v00 = texelFetch(fbTex, baseIdx, 0).g;
		float v10 = texelFetch(fbTex, ivec2(nextIdx.x, baseIdx.y), 0).g;
		float v01 = texelFetch(fbTex, ivec2(baseIdx.x, nextIdx.y), 0).g;
		float v11 = texelFetch(fbTex, nextIdx, 0).g;

		vec2 smoothWeights = smoothstep(vec2(0.0), vec2(1.0), weights);
		float v0 = mix(v00, v10, smoothWeights.x);
		float v1 = mix(v01, v11, smoothWeights.x);
		intensity = clamp(mix(v0, v1, smoothWeights.y), 0.0, 1.0);
	} else if (smoothing == 3) {
		// catmull-rom 3x3 (9 taps)
		vec2 texSize = vec2(textureSize(fbTex, 0));
		vec2 texelSize = 1.0 / texSize;
		vec2 scaling = resolution / texSize;
		vec2 uv = (gl_FragCoord.xy - scaling * 0.5) / resolution;
		vec4 smp = catmullRom3x3(fbTex, uv, texelSize);
		intensity = clamp(smp.g, 0.0, 1.0);
	} else if (smoothing == 4) {
		// catmull-rom 4x4 (16 taps)
		vec2 texSize = vec2(textureSize(fbTex, 0));
		vec2 texelSize = 1.0 / texSize;
		vec2 scaling = resolution / texSize;
		vec2 uv = (gl_FragCoord.xy - scaling * 0.5) / resolution;
		vec4 smp = catmullRom4x4(fbTex, uv, texelSize);
		intensity = clamp(smp.g, 0.0, 1.0);
	} else if (smoothing == 5) {
		// b-spline 3x3 (9 taps)
		vec2 texSize = vec2(textureSize(fbTex, 0));
		vec2 texelSize = 1.0 / texSize;
		vec2 scaling = resolution / texSize;
		vec2 uv = (gl_FragCoord.xy - scaling * 0.5) / resolution;
		vec4 smp = quadratic(fbTex, uv, texelSize);
		intensity = clamp(smp.g, 0.0, 1.0);
	} else if (smoothing == 6) {
		// b-spline 4x4 (16 taps)
		vec2 texSize = vec2(textureSize(fbTex, 0));
		vec2 texelSize = 1.0 / texSize;
		vec2 scaling = resolution / texSize;
		vec2 uv = (gl_FragCoord.xy - scaling * 0.5) / resolution;
		vec4 smp = bicubic(fbTex, uv, texelSize);
		intensity = clamp(smp.g, 0.0, 1.0);
	} else {
		vec2 texSize = vec2(textureSize(fbTex, 0));
		vec2 texelPos = (gl_FragCoord.xy * texSize / resolution) - vec2(0.5, 0.5);
		vec2 base = floor(texelPos);
		vec2 weights = fract(texelPos);
		vec2 next = base + vec2(1.0, 1.0);

		ivec2 texSizeI = ivec2(textureSize(fbTex, 0));
		ivec2 minIdx = ivec2(0, 0);
		ivec2 maxIdx = texSizeI - ivec2(1, 1);
		ivec2 baseI = clamp(ivec2(base), minIdx, maxIdx);
		ivec2 nextI = clamp(ivec2(next), minIdx, maxIdx);

		float v00 = texelFetch(fbTex, baseI, 0).g;
		float v10 = texelFetch(fbTex, ivec2(nextI.x, baseI.y), 0).g;
		float v01 = texelFetch(fbTex, ivec2(baseI.x, nextI.y), 0).g;
		float v11 = texelFetch(fbTex, nextI, 0).g;

		if (smoothing == 1) {
			float v0 = mix(v00, v10, weights.x);
			float v1 = mix(v01, v11, weights.x);
			intensity = clamp(mix(v0, v1, weights.y), 0.0, 1.0);
		} else {
			float v0 = cosineMix(v00, v10, weights.x);
			float v1 = cosineMix(v01, v11, weights.x);
			intensity = clamp(cosineMix(v0, v1, weights.y), 0.0, 1.0);
		}
	}

	vec3 rdColor = vec3(intensity, intensity, intensity);

	// Blend with input texture
	if (inputIntensity > 0.0) {
		vec2 inputUv = gl_FragCoord.xy / resolution;
		vec3 inputColor = texture(inputTex, inputUv).rgb;
		rdColor = mix(rdColor, inputColor, inputIntensity);
	}

	frag = vec4(rdColor, 1.0);
}
