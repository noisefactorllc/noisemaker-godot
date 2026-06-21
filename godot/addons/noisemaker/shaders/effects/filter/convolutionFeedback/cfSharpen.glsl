#version 450
// filter/convolutionFeedback program "cfSharpen" — ported from wgsl/cfSharpen.wgsl.
// Unsharp-mask sharpen pass of a 3-pass FEEDBACK effect. Reads the feedback texture
// (the effect's own prior-frame output, wired by the expander as `selfTex`→the chain's
// write surface, e.g. global_o0) and writes a sharpened copy to the intermediate
// _cfSharpened. The backend double-buffers the feedback surface and runs the 8-frame
// settle loop, so the prior-frame read is well-defined.
//
// No-layout effect (convolutionFeedback.json has NO uniformLayout): the backend
// SYNTHESIZES the Params UBO and injects `#define <name> data[slot].comp` for the params
// (sharpenRadius, sharpenAmount, blurRadius, blurAmount, intensity, resetState). The WGSL's
// `Uniforms` struct is just the reference packing; here we use the bare param names. Int
// params (sharpenRadius) arrive as float UBO components → narrow with int() at the use site,
// matching f32()/i32() of the WGSL. The pass's single input `inputTex` binds at binding 1.
//
// WGSL→GLSL: textureDimensions→textureSize; textureLoad(t,coord,0)→texelFetch(t,coord,0)
// (integer coords, no sampling — the WGSL deliberately uses textureLoad, no sampler).
// gl_FragCoord is top-left/+0.5 like @position — NO Y-flip. `amount`/`radius` are renamed to
// `sharpAmt`/`sharpRad` locals to keep the WGSL's local names distinct from injected
// param-define names (sharpenAmount/sharpenRadius are the bare param names).
layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

void main() {
	ivec2 texSize = textureSize(inputTex, 0);
	ivec2 coord = ivec2(gl_FragCoord.xy);

	vec4 center = texelFetch(inputTex, coord, 0);

	int sharpRad = int(sharpenRadius);
	float sharpAmt = sharpenAmount;

	if (sharpRad <= 0 || sharpAmt <= 0.0) {
		frag = center;
		return;
	}

	// Compute Gaussian-weighted blur for unsharp mask
	float sigma = float(sharpRad) / 2.0;
	float sigma2 = sigma * sigma;

	vec3 blurSum = vec3(0.0);
	float weightSum = 0.0;

	for (int ky = -sharpRad; ky <= sharpRad; ky = ky + 1) {
		for (int kx = -sharpRad; kx <= sharpRad; kx = kx + 1) {
			ivec2 samplePos = coord + ivec2(kx, ky);
			samplePos = clamp(samplePos, ivec2(0), texSize - ivec2(1));

			float dist2 = float(kx * kx + ky * ky);
			float weight = exp(-dist2 / (2.0 * sigma2));

			vec4 texSample = texelFetch(inputTex, samplePos, 0);
			blurSum = blurSum + texSample.rgb * weight;
			weightSum = weightSum + weight;
		}
	}

	vec3 blurred = blurSum / weightSum;

	// Unsharp mask: sharpened = original + amount * (original - blurred)
	vec3 sharpened = center.rgb + sharpAmt * (center.rgb - blurred);
	sharpened = clamp(sharpened, vec3(0.0), vec3(1.0));

	frag = vec4(sharpened, center.a);
}
