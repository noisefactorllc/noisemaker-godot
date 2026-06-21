#version 450
// points/flow — program "agent" (luminosity flow-field agent update). Ported from
// glsl/agent.glsl. MRT: rewrites the 3 agent state textures. Each agent samples the
// chained input luminance (OKLab L) at its position, turns by a behavior-dependent
// rotation bias, and steps forward by a per-agent stride; positions wrap to [0,1].
//
// Layout effect: vec4 data[3] (effects/points/flow.json, uniformLayouts.agent):
//   resolution=data[0].xy, time=data[0].z, stride=data[0].w, strideDeviation=data[1].x,
//   kink=data[1].y, quantize=data[1].z, inputWeight=data[1].w, behavior=data[2].x.
//   Inputs: inputTex=1, xyzTex=2, velTex=3, rgbaTex=4. gl_FragCoord top-left — NO Y-flip.
// computeRotationBias param `time` renamed `t` so the `time` uniform #define keeps it intact.
layout(set = 0, binding = 0, std140) uniform Params { vec4 data[3]; };
#define resolution data[0].xy
#define time data[0].z
#define stride data[0].w
#define strideDeviation data[1].x
#define kink data[1].y
#define quantize data[1].z
#define inputWeight data[1].w
#define behavior data[2].x

layout(set = 0, binding = 1) uniform sampler2D inputTex;  // Source texture for luminance-based flow
layout(set = 0, binding = 2) uniform sampler2D xyzTex;    // [x, y, z, alive]
layout(set = 0, binding = 3) uniform sampler2D velTex;    // [vx, vy, rotRand, strideRand]
layout(set = 0, binding = 4) uniform sampler2D rgbaTex;   // [r, g, b, a]

layout(location = 0) out vec4 outXYZ;
layout(location = 1) out vec4 outVel;
layout(location = 2) out vec4 outRGBA;
layout(location = 0) in vec2 v_uv;

const float TAU = 6.283185307179586;
const float RIGHT_ANGLE = 1.5707963267948966;

uint hash_uint(uint s) {
	uint state = s * 747796405u + 2891336453u;
	uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
	return (word >> 22u) ^ word;
}

float hash(uint s) {
	return float(hash_uint(s)) / 4294967295.0;
}

float srgb_to_linear(float value) {
	if (value <= 0.04045) return value / 12.92;
	return pow((value + 0.055) / 1.055, 2.4);
}

float cube_root(float value) {
	if (value == 0.0) return 0.0;
	float sign_value = value >= 0.0 ? 1.0 : -1.0;
	return sign_value * pow(abs(value), 1.0 / 3.0);
}

float oklab_l(vec3 rgb) {
	float r_lin = srgb_to_linear(clamp(rgb.x, 0.0, 1.0));
	float g_lin = srgb_to_linear(clamp(rgb.y, 0.0, 1.0));
	float b_lin = srgb_to_linear(clamp(rgb.z, 0.0, 1.0));
	float l = 0.4121656120 * r_lin + 0.5362752080 * g_lin + 0.0514575653 * b_lin;
	float m = 0.2118591070 * r_lin + 0.6807189584 * g_lin + 0.1074065790 * b_lin;
	float s = 0.0883097947 * r_lin + 0.2818474174 * g_lin + 0.6302613616 * b_lin;
	return 0.2104542553 * cube_root(l) + 0.7936177850 * cube_root(m) - 0.0040720468 * cube_root(s);
}

float normalized_sine(float value) {
	return (sin(value) + 1.0) * 0.5;
}

// Compute rotation bias based on behavior mode
float computeRotationBias(int behaviorMode, float baseHeading, float rotRand, float t, int agentIndex, int totalAgents) {
	if (behaviorMode <= 0) {
		return 0.0;
	} else if (behaviorMode == 1) {
		return baseHeading;
	} else if (behaviorMode == 2) {
		return baseHeading + floor(rotRand * 4.0) * RIGHT_ANGLE;
	} else if (behaviorMode == 3) {
		return baseHeading + (rotRand - 0.5) * 0.25;
	} else if (behaviorMode == 4) {
		return rotRand * TAU;
	} else if (behaviorMode == 5) {
		int quarterSize = max(1, totalAgents / 4);
		int band = agentIndex / quarterSize;
		if (band <= 0) {
			return baseHeading;
		} else if (band == 1) {
			return baseHeading + floor(rotRand * 4.0) * RIGHT_ANGLE;
		} else if (band == 2) {
			return baseHeading + (rotRand - 0.5) * 0.25;
		} else {
			return rotRand * TAU;
		}
	} else if (behaviorMode == 10) {
		return normalized_sine((t - rotRand) * TAU);
	} else {
		return rotRand * TAU;
	}
}

void main() {
	ivec2 coord = ivec2(gl_FragCoord.xy);
	ivec2 stateSize = textureSize(xyzTex, 0);

	// Read input state from pipeline
	vec4 xyz = texelFetch(xyzTex, coord, 0);
	vec4 vel = texelFetch(velTex, coord, 0);
	vec4 rgba = texelFetch(rgbaTex, coord, 0);

	// Extract components (positions in normalized coords [0,1])
	float px = xyz.x;
	float py = xyz.y;
	float pz = xyz.z;
	float alive = xyz.w;

	// Flow-specific state stored in vel
	// vel.x, vel.y unused for flow (no velocity accumulation)
	float rotRand = vel.z;     // Per-agent rotation random [0,1] from pointsEmit
	float strideRand = vel.w;  // Per-agent stride random [-0.5, 0.5] from pointsEmit

	// If not alive, pass through unchanged
	if (alive < 0.5) {
		outXYZ = xyz;
		outVel = vel;
		outRGBA = rgba;
		return;
	}

	// Sample input texture at current position for flow direction
	ivec2 texSize = textureSize(inputTex, 0);
	ivec2 texCoord = ivec2(px * float(texSize.x), py * float(texSize.y));
	texCoord = clamp(texCoord, ivec2(0), texSize - 1);
	vec4 texel = texelFetch(inputTex, texCoord, 0);
	float inputLuma = oklab_l(texel.rgb);

	// inputWeight controls how much the input texture influences flow direction
	float weightBlend = clamp(inputWeight * 0.01, 0.0, 1.0);
	float indexValue = mix(0.5, inputLuma, weightBlend);

	// Compute rotation bias based on behavior uniform
	float baseHeading = hash(0u) * TAU;
	int behaviorMode = int(behavior);
	int totalAgents = stateSize.x * stateSize.y;
	int agentIndex = coord.x + coord.y * stateSize.x;
	float rotationBias = computeRotationBias(behaviorMode, baseHeading, rotRand, time, agentIndex, totalAgents);

	// Final angle based on input texture and kink
	float finalAngle = indexValue * TAU * kink + rotationBias;

	if (quantize > 0.5) {
		finalAngle = round(finalAngle);
	}

	// Compute actual stride in normalized coords
	// stride uniform is in 1/10th of pixels at 1024 resolution
	float scale = max(max(resolution.x, resolution.y) / 1024.0, 1.0);
	float devFactor = 1.0 + strideRand * 2.0 * strideDeviation;
	float actualStride = max(0.0001, (stride * 0.1) * scale * devFactor / max(resolution.x, resolution.y));

	// Move agent
	float newX = px + sin(finalAngle) * actualStride;
	float newY = py + cos(finalAngle) * actualStride;

	// Wrap position to [0,1]
	newX = fract(newX);
	newY = fract(newY);

	// Output updated state - attrition is handled by pointsEmit
	outXYZ = vec4(newX, newY, pz, 1.0);
	outVel = vec4(0.0, 0.0, rotRand, strideRand);
	outRGBA = rgba;
}
