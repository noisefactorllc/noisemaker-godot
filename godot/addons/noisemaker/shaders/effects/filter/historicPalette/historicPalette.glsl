#version 450
// filter/historicPalette — ported PIXEL-IDENTICALLY from wgsl/historicPalette.wgsl. Maps
// luminance to one of 21 five-color historical-art palettes (dark→light), with smoothstep
// transitions and a wrap-around seam blend. Single render pass (progName "historicPalette").
//
// No-layout effect (historicPalette.json has NO uniformLayout despite the WGSL reading a
// packed `uniforms.data[]`): the backend SYNTHESIZES the Params UBO and injects
// `#define <name> data[slot].comp`. The injected names are the JSON `uniform` fields, in
// declaration order: paletteIndex (NOTE: JSON key is "index" but uniform is "paletteIndex"),
// rotation, offset, repeat, alpha, smoothness; engine `time` is also injected. We therefore
// use the BARE macro names and do NOT declare our own data[] UBO.
//
// RESERVED-NAME NOTE: paletteIndex/rotation/offset/repeat/alpha/smoothness/time are all
// injected macros. The WGSL's `let offset = uniforms.data[..]` reader lines are dropped;
// we read the macros directly at the use sites. rotation/paletteIndex are captured into
// real int locals (matching the WGSL's i32() truncation) before use.
//
// COORDINATE NOTE: ported from WGSL (top-left): uv = gl_FragCoord.xy / textureSize. No flip.
layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

const int PALETTE_COUNT = 21;

// 21 palettes x 5 colors (color1=darkest .. color5=lightest), flat-indexed PAL[idx*5 + k].
const vec3 PAL[105] = vec3[105](
	// 0: Aboriginal Australian Dot Painting
	vec3(0.165, 0.102, 0.039), vec3(0.914, 0.769, 0.416), vec3(0.627, 0.322, 0.176), vec3(0.957, 0.894, 0.843), vec3(0.545, 0.271, 0.075),
	// 1: Abstract Expressionism
	vec3(0.306, 0.204, 0.180), vec3(0.827, 0.184, 0.184), vec3(0.980, 0.980, 0.980), vec3(0.098, 0.463, 0.824), vec3(0.976, 0.659, 0.145),
	// 2: Art Deco
	vec3(0.039, 0.039, 0.039), vec3(0.831, 0.686, 0.216), vec3(0.173, 0.373, 0.435), vec3(0.961, 0.961, 0.863), vec3(0.769, 0.118, 0.227),
	// 3: Art Nouveau
	vec3(0.361, 0.514, 0.455), vec3(0.659, 0.776, 0.525), vec3(0.957, 0.894, 0.757), vec3(0.910, 0.706, 0.627), vec3(0.608, 0.494, 0.741),
	// 4: Bauhaus
	vec3(0.102, 0.102, 0.102), vec3(0.969, 0.925, 0.075), vec3(0.059, 0.278, 0.686), vec3(1.000, 1.000, 1.000), vec3(0.890, 0.118, 0.141),
	// 5: Prehistoric Cave Art
	vec3(0.173, 0.094, 0.063), vec3(0.871, 0.722, 0.529), vec3(0.545, 0.271, 0.075), vec3(0.961, 0.902, 0.827), vec3(0.824, 0.412, 0.118),
	// 6: Chinese Ink Painting
	vec3(0.102, 0.102, 0.102), vec3(0.290, 0.290, 0.290), vec3(0.502, 0.502, 0.502), vec3(0.749, 0.749, 0.749), vec3(0.961, 0.961, 0.941),
	// 7: Dutch Golden Age
	vec3(0.290, 0.055, 0.055), vec3(0.553, 0.431, 0.388), vec3(0.243, 0.149, 0.137), vec3(0.831, 0.647, 0.455), vec3(0.106, 0.369, 0.125),
	// 8: Fauvism
	vec3(0.482, 0.176, 0.149), vec3(0.361, 0.294, 0.600), vec3(0.290, 0.486, 0.349), vec3(0.957, 0.635, 0.380), vec3(1.000, 0.420, 0.208),
	// 9: Impressionism
	vec3(0.722, 0.651, 0.851), vec3(0.769, 0.910, 0.761), vec3(0.910, 0.769, 0.627), vec3(0.902, 0.835, 0.722), vec3(0.659, 0.847, 0.918),
	// 10: Indian Miniature Painting
	vec3(0.082, 0.263, 0.376), vec3(0.118, 0.518, 0.286), vec3(0.769, 0.118, 0.227), vec3(0.953, 0.612, 0.071), vec3(0.988, 0.953, 0.812),
	// 11: Islamic Geometric Art
	vec3(0.000, 0.306, 0.537), vec3(0.000, 0.549, 0.549), vec3(0.831, 0.686, 0.216), vec3(0.545, 0.000, 0.000), vec3(0.973, 0.973, 0.941),
	// 12: West African Kente Cloth
	vec3(0.000, 0.000, 0.000), vec3(0.000, 0.322, 0.647), vec3(0.808, 0.067, 0.149), vec3(0.000, 0.620, 0.286), vec3(0.992, 0.725, 0.075),
	// 13: Maori Ta Moko & Carving
	vec3(0.173, 0.094, 0.063), vec3(0.824, 0.706, 0.549), vec3(0.396, 0.263, 0.129), vec3(0.961, 0.961, 0.863), vec3(0.545, 0.271, 0.075),
	// 14: Mexican Muralism
	vec3(0.004, 0.341, 0.608), vec3(0.847, 0.263, 0.082), vec3(0.337, 0.545, 0.184), vec3(0.365, 0.251, 0.216), vec3(0.976, 0.659, 0.145),
	// 15: Minimalism
	vec3(0.259, 0.259, 0.259), vec3(0.620, 0.620, 0.620), vec3(0.110, 0.110, 0.110), vec3(0.878, 0.878, 0.878), vec3(0.961, 0.961, 0.961),
	// 16: Persian Miniature
	vec3(0.608, 0.349, 0.714), vec3(0.086, 0.627, 0.522), vec3(0.906, 0.298, 0.235), vec3(0.953, 0.612, 0.071), vec3(0.925, 0.941, 0.945),
	// 17: Pop Art
	vec3(0.914, 0.118, 0.388), vec3(1.000, 0.922, 0.231), vec3(0.161, 0.475, 1.000), vec3(1.000, 0.090, 0.267), vec3(0.000, 0.902, 0.463),
	// 18: Renaissance
	vec3(0.184, 0.310, 0.184), vec3(0.545, 0.455, 0.333), vec3(0.545, 0.000, 0.000), vec3(0.855, 0.647, 0.125), vec3(0.098, 0.098, 0.439),
	// 19: Surrealism
	vec3(0.216, 0.278, 0.310), vec3(0.961, 0.486, 0.000), vec3(0.290, 0.078, 0.549), vec3(1.000, 0.878, 0.510), vec3(0.000, 0.412, 0.361),
	// 20: Japanese Ukiyo-e
	vec3(0.118, 0.302, 0.545), vec3(0.910, 0.698, 0.596), vec3(0.176, 0.314, 0.086), vec3(0.957, 0.910, 0.757), vec3(0.769, 0.118, 0.227)
);

// Get color from palette based on luminance and smoothness
vec3 sampleHistoricPalette(int idx, float lum, float smoothAmount) {
	vec3 color1 = PAL[idx * 5 + 0];
	vec3 color2 = PAL[idx * 5 + 1];
	vec3 color3 = PAL[idx * 5 + 2];
	vec3 color4 = PAL[idx * 5 + 3];
	vec3 color5 = PAL[idx * 5 + 4];

	// Define the 5 luminance thresholds (equal subdivisions)
	float t1 = 0.2;
	float t2 = 0.4;
	float t3 = 0.6;
	float t4 = 0.8;

	// Calculate blend width based on smoothness (0 = hard edge, 1 = full blend)
	// Maximum blend width is 0.1 (half the distance between thresholds)
	float blendWidth = smoothAmount * 0.1;

	// Calculate blend factors at each threshold using smoothstep
	float b1 = smoothstep(t1 - blendWidth, t1 + blendWidth, lum);
	float b2 = smoothstep(t2 - blendWidth, t2 + blendWidth, lum);
	float b3 = smoothstep(t3 - blendWidth, t3 + blendWidth, lum);
	float b4 = smoothstep(t4 - blendWidth, t4 + blendWidth, lum);

	// Cascade the blends: start with color1, blend toward each successive color
	vec3 result = mix(color1, color2, b1);
	result = mix(result, color3, b2);
	result = mix(result, color4, b3);
	result = mix(result, color5, b4);

	// Wrap-around blend: smooth the seam between color5 and color1
	if (blendWidth > 0.0) {
		// Signed cyclic distance from the wrap boundary (t=0 == t=1)
		float dd;
		if (lum > 0.5) {
			dd = lum - 1.0;
		} else {
			dd = lum;
		}
		// Interpolation factor: 0 = color5, 1 = color1
		float wrapFactor = smoothstep(-blendWidth, blendWidth, dd);
		vec3 wrapColor = mix(color5, color1, wrapFactor);
		// Mask: 1.0 at wrap point, fading to 0.0 at edge of zone
		float wrapMask = 1.0 - smoothstep(0.0, blendWidth, abs(dd));
		result = mix(result, wrapColor, wrapMask);
	}

	return result;
}

void main() {
	// Calculate UV from position
	vec2 texSize = vec2(textureSize(inputTex, 0));
	vec2 uv = gl_FragCoord.xy / texSize;

	// Get input color
	vec4 inputColor = texture(inputTex, uv);

	// Get uniforms (injected macros; capture int-typed ones to match WGSL i32() truncation)
	int paletteIdx = int(paletteIndex);
	int rotationMode = int(rotation);

	// Clamp palette index to valid range
	int idx = clamp(paletteIdx, 0, PALETTE_COUNT - 1);

	// Calculate luminance
	float lum = dot(inputColor.rgb, vec3(0.299, 0.587, 0.114));

	// Apply palette modifiers: repeat, offset, and rotation (animation)
	// Scale lum to [0, 0.9999] so that fract() never hits an exact integer boundary
	float t = lum * (1.0 - 1e-4) * repeat + offset * 0.01;
	if (rotationMode == -1) {
		t = t + time;
	} else if (rotationMode == 1) {
		t = t - time;
	}
	t = fract(t);

	// Get palette entry and sample color
	vec3 paletteColor = sampleHistoricPalette(idx, t, smoothness);

	// Blend between original and palette color based on alpha
	vec3 blendedColor = mix(inputColor.rgb, paletteColor, alpha);

	frag = vec4(blendedColor, inputColor.a);
}
