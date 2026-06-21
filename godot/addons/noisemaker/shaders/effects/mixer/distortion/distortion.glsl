#version 450
// mixer/distortion — ported from wgsl/distortion.wgsl. Displace / refract / reflect
// between two surfaces using Sobel normals; `tex` warps the sample coord of the
// target via coord-resampling (NEAREST backend fetches the enclosing texel).
// No-layout effect: backend injects the Params UBO + `#define mode …`/`mapSource …`/
// `intensity …`/`wrap …`/`smoothing …`/`aberration …`/`antialias …`, used as bare
// names. Two inputs (pass.inputs order): inputTex = A (binding 1), tex = B (binding 2).
//
// Parity notes:
//  * uv = gl_FragCoord.xy / textureDimensions(inputTex,0); texelSize = 1/dims. No
//    tileOffset (the WGSL adds none). gl_FragCoord is top-left in Godot/Vulkan — no
//    Y-flip.
//  * wrapCoords mirror branch: the reference GLSL (golden source) uses GLSL `mod`
//    (floor-based) for `st % vec2(2.0)`, which is what `mod` already does in GLSL —
//    matched here (the HLSL port reaches the same nm_mod/floor conclusion).
//  * dpdx/dpdy -> dFdx/dFdy. reflect()/normalize()/length()/clamp()/fract() are direct.
//  * Helpers are this effect's OWN copies, ported verbatim; arithmetic unchanged.
//
// Parity tolerance: this effect chains a Sobel normal (calculateNormal sums 9
// samples of the map) into a NEAREST-fetched coord resample. The map/target
// synths (noise, gradient) already drift ~1 LSB between the WebGL2 golden and
// Godot/Metal; the Sobel amplifies that drift, and at ~7/65536 pixels it nudges
// the warped coord across a texel boundary so NEAREST returns the adjacent texel
// (worst case 11/255 where the gradient is steep). SSIM 0.99999, mean-abs-diff
// 0.19 — structurally identical; the gate is run at max-abs-diff <= 12 to absorb
// these isolated boundary flips (see PORTING-GUIDE "fp-sensitive ... log it").
layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(set = 0, binding = 2) uniform sampler2D tex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

#define DIST_PI 3.14159265359
#define DIST_TAU 6.28318530718

// Convert RGB to luminosity
float getLuminosity(vec3 color) {
	return dot(color, vec3(0.299, 0.587, 0.114));
}

// Calculate surface normal from height map using Sobel convolution
vec3 calculateNormal(vec2 uv, vec2 texelSize, bool useInputTex) {
	// Apply smoothing to texel size for smoother normals
	vec2 sampleSize = texelSize * smoothing;

	// Sobel X kernel
	float sobel_x[9] = float[9](
		-1.0, 0.0, 1.0,
		-2.0, 0.0, 2.0,
		-1.0, 0.0, 1.0
	);

	// Sobel Y kernel
	float sobel_y[9] = float[9](
		-1.0, -2.0, -1.0,
		 0.0,  0.0,  0.0,
		 1.0,  2.0,  1.0
	);

	vec2 offsets[9] = vec2[9](
		vec2(-sampleSize.x, -sampleSize.y),
		vec2(0.0, -sampleSize.y),
		vec2(sampleSize.x, -sampleSize.y),
		vec2(-sampleSize.x, 0.0),
		vec2(0.0, 0.0),
		vec2(sampleSize.x, 0.0),
		vec2(-sampleSize.x, sampleSize.y),
		vec2(0.0, sampleSize.y),
		vec2(sampleSize.x, sampleSize.y)
	);

	float dx = 0.0;
	float dy = 0.0;

	for (int i = 0; i < 9; i = i + 1) {
		vec3 texSample;
		if (useInputTex) {
			texSample = texture(inputTex, uv + offsets[i]).rgb;
		} else {
			texSample = texture(tex, uv + offsets[i]).rgb;
		}
		float height = getLuminosity(texSample);
		dx += height * sobel_x[i];
		dy += height * sobel_y[i];
	}

	// Scale gradients by intensity
	float normalStrength = intensity * 0.1;
	dx *= normalStrength;
	dy *= normalStrength;

	// Construct normal from gradients
	vec3 normal = normalize(vec3(-dx, -dy, 1.0));

	return normal;
}

// Apply wrap mode to coordinates
vec2 wrapCoords(vec2 st_in) {
	vec2 st = st_in;
	int wrapMode = int(wrap);
	if (wrapMode == 0) {
		// mirror
		st = abs(mod(st, vec2(2.0)) - vec2(1.0));
		st = vec2(1.0) - st;
	} else if (wrapMode == 1) {
		// repeat
		st = fract(st);
	} else if (wrapMode == 2) {
		// clamp
		st = clamp(st, vec2(0.0), vec2(1.0));
	}
	return st;
}

// Displacement effect based on color luminosity
vec4 applyDisplacement(vec2 uv, bool useInputTexAsMap) {
	vec4 mapColor;
	if (useInputTexAsMap) {
		mapColor = texture(inputTex, uv);
	} else {
		mapColor = texture(tex, uv);
	}

	float len = length(mapColor.rgb);

	vec2 offset;
	offset.x = cos(len * DIST_TAU) * (intensity * 0.001);
	offset.y = sin(len * DIST_TAU) * (intensity * 0.001);

	vec2 displacedUV = wrapCoords(uv + offset);

	if (int(antialias) != 0) {
		vec2 dx = dFdx(displacedUV);
		vec2 dy = dFdy(displacedUV);
		vec4 col = vec4(0.0);
		if (useInputTexAsMap) {
			col += texture(tex, displacedUV + dx * -0.375 + dy * -0.125);
			col += texture(tex, displacedUV + dx *  0.125 + dy * -0.375);
			col += texture(tex, displacedUV + dx *  0.375 + dy *  0.125);
			col += texture(tex, displacedUV + dx * -0.125 + dy *  0.375);
		} else {
			col += texture(inputTex, displacedUV + dx * -0.375 + dy * -0.125);
			col += texture(inputTex, displacedUV + dx *  0.125 + dy * -0.375);
			col += texture(inputTex, displacedUV + dx *  0.375 + dy *  0.125);
			col += texture(inputTex, displacedUV + dx * -0.125 + dy *  0.375);
		}
		return col * 0.25;
	} else if (useInputTexAsMap) {
		return texture(tex, displacedUV);
	} else {
		return texture(inputTex, displacedUV);
	}
}

// Refraction effect based on surface normal
vec4 applyRefraction(vec2 uv, vec2 texelSize, bool useInputTexAsMap) {
	vec3 normal = calculateNormal(uv, texelSize, useInputTexAsMap);
	vec2 refractionOffset = normal.xy * (intensity * 0.0125);
	vec2 refractedUV = wrapCoords(uv + refractionOffset);

	if (int(antialias) != 0) {
		vec2 dx = dFdx(refractedUV);
		vec2 dy = dFdy(refractedUV);
		vec4 col = vec4(0.0);
		if (useInputTexAsMap) {
			col += texture(tex, refractedUV + dx * -0.375 + dy * -0.125);
			col += texture(tex, refractedUV + dx *  0.125 + dy * -0.375);
			col += texture(tex, refractedUV + dx *  0.375 + dy *  0.125);
			col += texture(tex, refractedUV + dx * -0.125 + dy *  0.375);
		} else {
			col += texture(inputTex, refractedUV + dx * -0.375 + dy * -0.125);
			col += texture(inputTex, refractedUV + dx *  0.125 + dy * -0.375);
			col += texture(inputTex, refractedUV + dx *  0.375 + dy *  0.125);
			col += texture(inputTex, refractedUV + dx * -0.125 + dy *  0.375);
		}
		return col * 0.25;
	} else if (useInputTexAsMap) {
		return texture(tex, refractedUV);
	} else {
		return texture(inputTex, refractedUV);
	}
}

// Reflection effect with chromatic aberration
vec4 applyReflection(vec2 uv, vec2 texelSize, bool useInputTexAsMap) {
	vec3 normal = calculateNormal(uv, texelSize, useInputTexAsMap);

	// Calculate incident vector for reflection, from center of image
	vec3 incident = vec3(normalize(uv - vec2(0.5)), 100.0);

	// Calculate reflection vector
	vec3 reflectionVec = reflect(incident, normal);

	// Convert to 2D texture offset
	vec2 reflectionOffset = reflectionVec.xy * (intensity * 0.00005);

	// Apply chromatic aberration
	vec2 redOffset = reflectionOffset * (1.0 + aberration * 0.0075);
	vec2 greenOffset = reflectionOffset;
	vec2 blueOffset = reflectionOffset * (1.0 - aberration * 0.0075);

	vec2 redUV = wrapCoords(uv + redOffset);
	vec2 greenUV = wrapCoords(uv + greenOffset);
	vec2 blueUV = wrapCoords(uv + blueOffset);
	vec2 alphaUV = wrapCoords(uv + reflectionOffset);

	if (int(antialias) != 0) {
		vec2 dx = dFdx(greenUV);
		vec2 dy = dFdy(greenUV);
		vec2 o1 = dx * -0.375 + dy * -0.125;
		vec2 o2 = dx *  0.125 + dy * -0.375;
		vec2 o3 = dx *  0.375 + dy *  0.125;
		vec2 o4 = dx * -0.125 + dy *  0.375;

		float r = 0.0;
		float g = 0.0;
		float b = 0.0;
		float a = 0.0;

		if (useInputTexAsMap) {
			r += texture(tex, redUV + o1).r;
			r += texture(tex, redUV + o2).r;
			r += texture(tex, redUV + o3).r;
			r += texture(tex, redUV + o4).r;
			g += texture(tex, greenUV + o1).g;
			g += texture(tex, greenUV + o2).g;
			g += texture(tex, greenUV + o3).g;
			g += texture(tex, greenUV + o4).g;
			b += texture(tex, blueUV + o1).b;
			b += texture(tex, blueUV + o2).b;
			b += texture(tex, blueUV + o3).b;
			b += texture(tex, blueUV + o4).b;
			a += texture(tex, alphaUV + o1).a;
			a += texture(tex, alphaUV + o2).a;
			a += texture(tex, alphaUV + o3).a;
			a += texture(tex, alphaUV + o4).a;
		} else {
			r += texture(inputTex, redUV + o1).r;
			r += texture(inputTex, redUV + o2).r;
			r += texture(inputTex, redUV + o3).r;
			r += texture(inputTex, redUV + o4).r;
			g += texture(inputTex, greenUV + o1).g;
			g += texture(inputTex, greenUV + o2).g;
			g += texture(inputTex, greenUV + o3).g;
			g += texture(inputTex, greenUV + o4).g;
			b += texture(inputTex, blueUV + o1).b;
			b += texture(inputTex, blueUV + o2).b;
			b += texture(inputTex, blueUV + o3).b;
			b += texture(inputTex, blueUV + o4).b;
			a += texture(inputTex, alphaUV + o1).a;
			a += texture(inputTex, alphaUV + o2).a;
			a += texture(inputTex, alphaUV + o3).a;
			a += texture(inputTex, alphaUV + o4).a;
		}

		return vec4(r, g, b, a) * 0.25;
	}

	float redChannel;
	float greenChannel;
	float blueChannel;
	float alphaChannel;

	if (useInputTexAsMap) {
		redChannel = texture(tex, redUV).r;
		greenChannel = texture(tex, greenUV).g;
		blueChannel = texture(tex, blueUV).b;
		alphaChannel = texture(tex, alphaUV).a;
	} else {
		redChannel = texture(inputTex, redUV).r;
		greenChannel = texture(inputTex, greenUV).g;
		blueChannel = texture(inputTex, blueUV).b;
		alphaChannel = texture(inputTex, alphaUV).a;
	}

	return vec4(redChannel, greenChannel, blueChannel, alphaChannel);
}

void main() {
	vec2 dims = vec2(textureSize(inputTex, 0));
	vec2 uv = gl_FragCoord.xy / dims;
	vec2 texelSize = 1.0 / dims;

	vec4 color = vec4(0.0);

	// Determine which texture is the map source and which is the target.
	// mapSource: 0 = inputTex (A), 1 = tex (B)
	bool useInputTexAsMap = int(mapSource) == 0;

	int distMode = int(mode);
	if (distMode == 0) {
		// Displacement
		color = applyDisplacement(uv, useInputTexAsMap);
	} else if (distMode == 1) {
		// Refraction
		color = applyRefraction(uv, texelSize, useInputTexAsMap);
	} else if (distMode == 2) {
		// Reflection
		color = applyReflection(uv, texelSize, useInputTexAsMap);
	}

	frag = color;
}
