#version 450
// synth/ca — cellular-automata display/render pass, ported from
// cellularAutomata/wgsl/ca.wgsl (top-left origin = Godot/Vulkan, no Y-flip).
// Reads the CA state buffer and upscales it to output resolution with selectable
// smoothing (0 nearest, 1 bilinear, 2 cosine, 3 catmull-rom 3x3, 4 catmull-rom 4x4,
// 5 b-spline 3x3, 6 b-spline 4x4). Mono output (reads the .g channel).
//
// Layout effect: vec4 data[2] (effects/synth/cellularAutomata.json, uniformLayouts.ca):
//   resolution = data[0].xy, smoothing = int(data[1].y). (time = data[0].z unused.)
// gl_FragCoord top-left, +0.5 pixel-centered, no Y-flip.
// Only fbTex is used (binding 1). The render graph lists four inputs
// (fbTex/prevFrameTex/bufTex/tex) but the shader samples ONLY fbTex; the backend
// binds samplers by name and the SPIR-V compiler strips unused ones, so declaring
// any other sampler would break uniform-set creation. The WGSL `mySampler` folds
// into the combined sampler2D fbTex (NEAREST, no mipmaps — LOD always 0, so
// textureSampleLevel(...,0.0) -> plain texture()).
layout(set = 0, binding = 0, std140) uniform Params { vec4 data[2]; };
layout(set = 0, binding = 1) uniform sampler2D fbTex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

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

vec4 quadraticSample(sampler2D tex, vec2 uv, vec2 texelSize) {
	// Match GLSL: offset uv by one texel to accommodate texel centering
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

vec4 catmullRom3x3Sample(sampler2D tex, vec2 uv, vec2 texelSize) {
	// Match GLSL: offset uv by one texel to accommodate texel centering
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

vec4 bicubicSample(sampler2D tex, vec2 uv, vec2 texelSize) {
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

vec4 catmullRom4x4Sample(sampler2D tex, vec2 uv, vec2 texelSize) {
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
	int smoothing = int(data[1].y);

	float state = 0.0;
	if (smoothing == 0) {
		// constant - use texelFetch for exact nearest-neighbor sampling
		ivec2 texSizeI = ivec2(textureSize(fbTex, 0));
		vec2 texSizeF = vec2(float(texSizeI.x), float(texSizeI.y));
		ivec2 pixelCoord = ivec2(floor(gl_FragCoord.xy * texSizeF / resolution));
		state = texelFetch(fbTex, clamp(pixelCoord, ivec2(0), texSizeI - ivec2(1)), 0).g;
	} else if (smoothing == 3) {
		// catmull-rom 3x3 (9 taps)
		vec2 texSize = vec2(textureSize(fbTex, 0));
		vec2 texelSize = 1.0 / texSize;
		vec2 scaling = resolution / texSize;
		vec2 uv = (gl_FragCoord.xy - scaling * 0.5) / resolution;
		state = catmullRom3x3Sample(fbTex, uv, texelSize).g;
	} else if (smoothing == 4) {
		// catmull-rom 4x4 (16 taps)
		vec2 texSize = vec2(textureSize(fbTex, 0));
		vec2 texelSize = 1.0 / texSize;
		vec2 scaling = resolution / texSize;
		vec2 uv = (gl_FragCoord.xy - scaling * 0.5) / resolution;
		state = catmullRom4x4Sample(fbTex, uv, texelSize).g;
	} else if (smoothing == 5) {
		// b-spline 3x3 (9 taps)
		vec2 texSize = vec2(textureSize(fbTex, 0));
		vec2 texelSize = 1.0 / texSize;
		vec2 scaling = resolution / texSize;
		vec2 uv = (gl_FragCoord.xy - scaling * 0.5) / resolution;
		state = quadraticSample(fbTex, uv, texelSize).g;
	} else if (smoothing == 6) {
		// b-spline 4x4 (16 taps)
		vec2 texSize = vec2(textureSize(fbTex, 0));
		vec2 texelSize = 1.0 / texSize;
		vec2 scaling = resolution / texSize;
		vec2 uv = (gl_FragCoord.xy - scaling * 0.5) / resolution;
		state = bicubicSample(fbTex, uv, texelSize).g;
	} else {
		// linear-style smoothing — sample texel centres explicitly to avoid seams.
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
			state = mix(v0, v1, weights.y);
		} else {
			float v0 = cosineMix(v00, v10, weights.x);
			float v1 = cosineMix(v01, v11, weights.x);
			state = cosineMix(v0, v1, weights.y);
		}
	}

	// Mono output only
	float intensity = clamp(state, 0.0, 1.0);
	frag = vec4(intensity, intensity, intensity, 1.0);
}
