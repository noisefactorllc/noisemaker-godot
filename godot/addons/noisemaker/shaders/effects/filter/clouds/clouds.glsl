#version 450
// filter/clouds — ported PIXEL-IDENTICALLY from wgsl/clouds.wgsl. Ridged multi-octave
// 2D simplex noise shaped into clouds, composited with an offset shadow onto the input.
// Single render pass (progName "clouds").
//
// No-layout effect (clouds.json has no uniformLayout): the backend SYNTHESIZES the
// Params UBO and injects `#define <name> data[slot].comp` for the engine globals
// (time, tileOffset, fullResolution used here) and the params seed/scale/speed. We use
// the bare names directly. `speed` is an int param arriving as float → cast float(speed)
// where the WGSL did f32(uniforms.speed).
//
// COORDINATE NOTE: ported from WGSL (top-left): uv = (gl_FragCoord.xy + tileOffset) /
// fullResolution, exactly as the WGSL. No per-effect Y-flip. Sampler is combined
// (texture()). textureDimensions → textureSize cast to vec2.
layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

const float CLOUDS_TAU = 6.28318530718;

// Simplex 2D - MIT License (Ashima Arts)
vec3 mod289v3(vec3 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
vec2 mod289v2(vec2 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
vec3 permute3(vec3 x) { return mod289v3(((x * 34.0) + 1.0) * x); }

float simplex2d(vec2 v) {
	vec4 C = vec4(0.211324865405187, 0.366025403784439, -0.577350269189626, 0.024390243902439);

	vec2 i = floor(v + dot(v, C.yy));
	vec2 x0 = v - i + dot(i, C.xx);
	vec2 i1;
	if (x0.x > x0.y) { i1 = vec2(1.0, 0.0); } else { i1 = vec2(0.0, 1.0); }
	vec4 x12 = x0.xyxy + C.xxzz;
	x12 = vec4(x12.xy - i1, x12.zw);

	vec2 im = mod289v2(i);
	vec3 p = permute3(permute3(im.y + vec3(0.0, i1.y, 1.0)) + im.x + vec3(0.0, i1.x, 1.0));
	vec3 m = max(0.5 - vec3(dot(x0, x0), dot(x12.xy, x12.xy), dot(x12.zw, x12.zw)), vec3(0.0));
	m = m * m;
	m = m * m;

	vec3 x = 2.0 * fract(p * C.www) - 1.0;
	vec3 h = abs(x) - 0.5;
	vec3 ox = floor(x + 0.5);
	vec3 a0 = x - ox;
	m = m * (1.79284291400159 - 0.85373472095314 * (a0 * a0 + h * h));

	vec3 g;
	g.x = a0.x * x0.x + h.x * x0.y;
	g = vec3(g.x, a0.yz * x12.xz + h.yz * x12.yw);

	return 130.0 * dot(m, g);
}

float cloudNoise(vec2 uv, float baseFreq, int octaves, float animPhase, float animSpeed) {
	float accum = 0.0;
	float totalAmp = 0.0;

	for (int i = 0; i < 8; i = i + 1) {
		if (i >= octaves) { break; }
		float freq = baseFreq * pow(2.0, float(i));
		float amp = 1.0 / pow(2.0, float(i));

		// Per-octave circular offset for morphing animation
		// Subtract initial position so offset is zero at time=0
		float octavePhase = float(i) * 2.13;
		float octaveRadius = (0.25 + float(i) * 0.08) * animSpeed;
		vec2 timeOffset = (vec2(cos(animPhase + octavePhase), sin(animPhase + octavePhase))
						- vec2(cos(octavePhase), sin(octavePhase))) * octaveRadius;

		float n = simplex2d(uv * freq + vec2(float(i) * 37.0, float(i) * 53.0) + timeOffset);
		n = n * 0.5 + 0.5;

		accum = accum + n * amp;
		totalAmp = totalAmp + amp;
	}

	return accum / totalAmp;
}

void main() {
	vec2 texSize = vec2(textureSize(inputTex, 0));
	vec2 uv = (gl_FragCoord.xy + tileOffset) / fullResolution;

	vec4 inputColor = texture(inputTex, uv);

	float aspect = fullResolution.x / fullResolution.y;
	vec2 seedOffset = vec2(seed * 17.31, seed * 23.71);

	// Animation phase (loops at 0-1 time boundary)
	float animPhase = time * CLOUDS_TAU * float(speed);
	float animSpeed = float(speed);

	vec2 cloudUV = uv * vec2(aspect, 1.0) / scale + seedOffset;

	float cloud = cloudNoise(cloudUV, 1.0, 7, animPhase, animSpeed);
	float cloudMask = smoothstep(0.45, 0.65, cloud);

	// Cloud shading: vary brightness within cloud for depth
	float cloudDepth = smoothstep(0.45, 0.85, cloud);
	float cloudBrightness = mix(0.75, 1.0, cloudDepth);

	// Shadow: sample cloud at offset (light from upper-right)
	float shadowDist = min(texSize.x, texSize.y) * 0.008;
	vec2 shadowOffset = vec2(-shadowDist, shadowDist) / texSize;
	vec2 shadowUV = (uv + shadowOffset) * vec2(aspect, 1.0) / scale + seedOffset;
	float shadowCloud = cloudNoise(shadowUV, 1.0, 7, animPhase, animSpeed);
	float shadowMask = smoothstep(0.45, 0.65, shadowCloud);

	float shadow = max(shadowMask - cloudMask, 0.0) * 0.5;

	vec3 result = inputColor.rgb * (1.0 - shadow);
	result = mix(result, vec3(cloudBrightness), cloudMask);

	frag = vec4(result, inputColor.a);
}
