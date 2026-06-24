#version 450
// mixer/focusBlur — ported from glsl/focusBlur.glsl. Focus blur (depth of field):
// reconstructs a faux depth buffer from luminance to drive a 64-sample golden-angle
// spiral disk blur whose radius grows with distance from the focal plane. No-layout
// effect: backend injects the Params UBO + `#define depthSource …`/`focalDistance …`/
// `aperture …`/`sampleBias …`. Two inputs (pass.inputs order): inputTex (binding 1),
// tex (binding 2).
// NOTE: helper param `resolution` collides with the injected engine name — renamed
// to `res` (pure symbol rename, matches the HLSL port's `resolutionDims`).
layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(set = 0, binding = 2) uniform sampler2D tex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

// Convert RGB to luminosity for depth estimation
float getLuminosity(vec3 color) {
	return dot(color, vec3(0.2126, 0.7152, 0.0722));
}

// Compute blur factor based on depth distance from focal plane
float computeBlurFactor(float depth) {
	float focalPlane = focalDistance * 0.01;
	float blur = abs(depth - focalPlane) * aperture;
	return clamp(blur, 0.0, 1.0);
}

// Golden-angle spiral disk blur. sceneTex is the texture being blurred; the depth
// proxy is the OTHER input's luminance. 64 flat-weighted samples spread over a disk
// whose radius = computeBlurFactor(depth) * sampleBias.
const float GOLDEN = 2.399963;

// Apply depth of field blur using inputTex as depth, tex as scene
vec4 applyFocusBlurAB(vec2 uv, vec2 res) {
	// Sample depth texture and compute luminosity as depth proxy
	vec4 depthSample = texture(inputTex, uv);
	float depth = getLuminosity(depthSample.rgb);

	// Calculate blur radius based on distance from focal plane
	float blurRadius = computeBlurFactor(depth) * sampleBias;

	vec4 color = vec4(0.0);
	for (int i = 0; i < 64; i++) {
		float r = sqrt(float(i) / 64.0);
		float theta = float(i) * GOLDEN;
		vec2 offset = vec2(cos(theta), sin(theta)) * r * blurRadius / res;
		color += texture(tex, uv + offset);
	}

	return color / 64.0;
}

// Apply depth of field blur using tex as depth, inputTex as scene
vec4 applyFocusBlurBA(vec2 uv, vec2 res) {
	// Sample depth texture and compute luminosity as depth proxy
	vec4 depthSample = texture(tex, uv);
	float depth = getLuminosity(depthSample.rgb);

	// Calculate blur radius based on distance from focal plane
	float blurRadius = computeBlurFactor(depth) * sampleBias;

	vec4 color = vec4(0.0);
	for (int i = 0; i < 64; i++) {
		float r = sqrt(float(i) / 64.0);
		float theta = float(i) * GOLDEN;
		vec2 offset = vec2(cos(theta), sin(theta)) * r * blurRadius / res;
		color += texture(inputTex, uv + offset);
	}

	return color / 64.0;
}

void main() {
	vec2 dims = vec2(textureSize(inputTex, 0));
	vec2 uv = gl_FragCoord.xy / dims;

	vec4 color;

	// depthSource: 0 = use inputTex (A) as depth map, blur tex (B)
	//              1 = use tex (B) as depth map, blur inputTex (A)
	if (int(depthSource) == 0) {
		color = applyFocusBlurAB(uv, dims);
	} else {
		color = applyFocusBlurBA(uv, dims);
	}

	// Preserve maximum alpha from both sources
	float alpha1 = texture(inputTex, uv).a;
	float alpha2 = texture(tex, uv).a;
	color.a = max(alpha1, alpha2);

	frag = color;
}
