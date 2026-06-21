#version 450
// filter/lighting (program "lighting") — ported from wgsl/lighting.wgsl.
// 3D lighting for 2D textures: derives surface normals from luminosity via a 3x3
// Sobel convolution, then applies Blinn-Phong (ambient + diffuse + specular) with
// optional refraction and reflection-with-chromatic-aberration.
//
// No-layout effect: the backend synthesizes the Params UBO and injects
// `#define normalStrength data[..]`, `#define diffuseColor data[..].xyz`, etc. for
// every named uniform (colors/vec3 pack as 3 contiguous components), so we use the
// bare reference names directly. Input bound at set 0, binding 1. Dimensions come
// from textureSize (matching the WGSL textureDimensions). gl_FragCoord is
// top-left/+0.5 like the WGSL @position — NO Y-flip.
layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

float getLuminosity(vec3 color) {
	return dot(color, vec3(0.299, 0.587, 0.114));
}

// Surface normal from the luminosity height-field via 3x3 Sobel.
vec3 calculateNormal(vec2 uv, vec2 texelSize) {
	vec2 sampleSize = texelSize * smoothing;

	float sobel_x[9] = float[9](
		-1.0, 0.0, 1.0,
		-2.0, 0.0, 2.0,
		-1.0, 0.0, 1.0
	);
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
	for (int i = 0; i < 9; i++) {
		float height = getLuminosity(texture(inputTex, uv + offsets[i]).rgb);
		dx += height * sobel_x[i];
		dy += height * sobel_y[i];
	}

	dx *= normalStrength;
	dy *= normalStrength;

	return normalize(vec3(-dx, -dy, 1.0));
}

vec4 applyRefraction(vec2 uv, vec3 normal) {
	vec2 refractionOffset = normal.xy * (refraction * 0.0125);
	return texture(inputTex, uv + refractionOffset);
}

// Reflection with chromatic aberration: incident from image center, reflected off
// the surface normal, sampled per-channel with an aberration-spread offset.
vec4 applyReflection(vec2 uv, vec3 normal) {
	vec3 incident = vec3(normalize(uv - 0.5), 100.0);
	vec3 reflectionVec = reflect(incident, normal);
	vec2 reflectionOffset = reflectionVec.xy * (reflection * 0.00005);

	vec2 redOffset = reflectionOffset * (1.0 + aberration * 0.0075);
	vec2 greenOffset = reflectionOffset;
	vec2 blueOffset = reflectionOffset * (1.0 - aberration * 0.0075);

	float redChannel = texture(inputTex, uv + redOffset).r;
	float greenChannel = texture(inputTex, uv + greenOffset).g;
	float blueChannel = texture(inputTex, uv + blueOffset).b;
	float alphaChannel = texture(inputTex, uv + reflectionOffset).a;

	return vec4(redChannel, greenChannel, blueChannel, alphaChannel);
}

void main() {
	vec2 texSize = vec2(textureSize(inputTex, 0));
	vec2 uv = gl_FragCoord.xy / texSize;
	vec2 texelSize = 1.0 / texSize;

	vec4 origColor = texture(inputTex, uv);

	vec3 normal = calculateNormal(uv, texelSize);

	vec3 lightDir = normalize(lightDirection);
	vec3 viewDir = vec3(0.0, 0.0, 1.0);

	// Ambient
	vec3 ambient = ambientColor * origColor.rgb;

	// Diffuse (Lambertian)
	float diffuseFactor = max(dot(normal, lightDir), 0.0);
	vec3 diffuse = diffuseColor * diffuseFactor * origColor.rgb;

	// Specular (Blinn-Phong)
	vec3 halfDir = normalize(lightDir + viewDir);
	float specAngle = max(dot(halfDir, normal), 0.0);
	float specularFactor = pow(specAngle, shininess);
	vec3 specular = specularColor * specularFactor * specularIntensity;

	vec3 litColor = ambient + diffuse + specular;
	vec4 workingColor = vec4(litColor, origColor.a);

	if (refraction > 0.0) {
		vec4 refractedColor = applyRefraction(uv, normal);
		workingColor = mix(workingColor, refractedColor, refraction / 100.0);
	}

	if (reflection > 0.0 || aberration > 0.0) {
		vec4 reflectedColor = applyReflection(uv, normal);
		workingColor = mix(workingColor, reflectedColor, reflection / 100.0);
	}

	frag = workingColor;
}
