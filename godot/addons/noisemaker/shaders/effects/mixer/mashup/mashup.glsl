#version 450
// mixer/mashup — ported PIXEL-IDENTICALLY from wgsl/mashup.glsl. Luminance-band
// router: the control input (`source`) is posterized by luminosity into `layers`
// equal bands and each band routes to its layerN_tex source. Darkest band -> layer0,
// brightest -> layer(layers-1). `smoothness` feathers each band boundary; bands whose
// layer source is unwired (layerN_active == 0) fall back to the control input.
// Starter effect (no chain input) — output size comes from the packed resolution.
//
// Layout effect (DECLARED uniformLayout, like synth/remap): the backend packs the
// Params UBO from the JSON uniformLayout. data[3]:
//   slot 0: layers=x, smoothness=y, resolution=zw
//   slot 1: layer0_active..layer3_active (xyzw)
//   slot 2: layer4_active..layer7_active (xyzw)
// Active flags are packed as f32 (0.0/1.0) by the expander's colorModeUniform path
// (1 when the layerN_tex surface is wired, 0 when "none"); threshold at 0.5 like remap.
// gl_FragCoord top-left — NO Y-flip (matches the other surface-sampling shaders).
layout(set = 0, binding = 0, std140) uniform Params { vec4 data[3]; };
#define layers     int(data[0].x)
#define smoothness data[0].y
#define resolution data[0].zw
layout(set = 0, binding = 1) uniform sampler2D source;
layout(set = 0, binding = 2) uniform sampler2D layer0_tex;
layout(set = 0, binding = 3) uniform sampler2D layer1_tex;
layout(set = 0, binding = 4) uniform sampler2D layer2_tex;
layout(set = 0, binding = 5) uniform sampler2D layer3_tex;
layout(set = 0, binding = 6) uniform sampler2D layer4_tex;
layout(set = 0, binding = 7) uniform sampler2D layer5_tex;
layout(set = 0, binding = 8) uniform sampler2D layer6_tex;
layout(set = 0, binding = 9) uniform sampler2D layer7_tex;
layout(location = 0) out vec4 fragColor;
layout(location = 0) in vec2 v_uv;

#define MAX_LAYERS 8

// RGB -> luminosity (shared codebase weights).
float getLuminosity(vec3 color) {
	return dot(color, vec3(0.299, 0.587, 0.114));
}

vec4 sampleLayer(int i, vec2 uv) {
	if (i == 0) return texture(layer0_tex, uv);
	if (i == 1) return texture(layer1_tex, uv);
	if (i == 2) return texture(layer2_tex, uv);
	if (i == 3) return texture(layer3_tex, uv);
	if (i == 4) return texture(layer4_tex, uv);
	if (i == 5) return texture(layer5_tex, uv);
	if (i == 6) return texture(layer6_tex, uv);
	return texture(layer7_tex, uv);
}

// Active flags are packed as f32 (0.0 / 1.0); threshold at 0.5 like remap.
float layerActive(int i) {
	if (i == 0) return data[1].x;
	if (i == 1) return data[1].y;
	if (i == 2) return data[1].z;
	if (i == 3) return data[1].w;
	if (i == 4) return data[2].x;
	if (i == 5) return data[2].y;
	if (i == 6) return data[2].z;
	return data[2].w;
}

// Band-boundary weight: 0 below the boundary, 1 above, with a symmetric
// smoothstep feather of half-width `smoothness`. smoothness <= 0 is a hard step.
float bandWeight(float lum, float boundary) {
	if (smoothness <= 0.0) return step(boundary, lum);
	return smoothstep(boundary - smoothness, boundary + smoothness, lum);
}

void main() {
	vec2 uv = gl_FragCoord.xy / resolution;
	vec4 controlColor = texture(source, uv);
	float lum = getLuminosity(controlColor.rgb);

	int n = clamp(layers, 2, MAX_LAYERS);

	// Base = darkest band's source (or the control input when unwired).
	vec4 result = (layerActive(0) >= 0.5) ? sampleLayer(0, uv) : controlColor;

	// Each subsequent boundary at k/n cross-fades toward that band's source.
	for (int k = 1; k < MAX_LAYERS; k++) {
		if (k >= n) break;
		vec4 src = (layerActive(k) >= 0.5) ? sampleLayer(k, uv) : controlColor;
		float boundary = float(k) / float(n);
		float w = bandWeight(lum, boundary);
		result = mix(result, src, w);
	}

	fragColor = result;
}
