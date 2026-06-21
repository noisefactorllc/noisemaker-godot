#version 450
// filter/edge — ported PIXEL-IDENTICALLY from wgsl/edge.wgsl. Edge detection with
// multiple kernels, sizes, and blend modes (convolution over neighbor texels).
// No-layout effect: the backend synthesizes the Params UBO + `#define kernel …`/
// `#define size …`/… (one per globals[*].uniform) and the engine globals, so we use
// the bare reference names directly. Input texture bound at set 0, binding 1.
//
// uv divides by the INPUT texture size (textureSize), NOT fullResolution — mirrored
// from the WGSL exactly. gl_FragCoord is top-left (+0.5 centered) like the WGSL @position,
// so NO per-effect Y-flip (the WGSL has none; the single present flip handles orientation).
//
// `texelSize`, the kernel weights, and the dx/dy offset signs are reproduced EXACTLY —
// edge is a convolution and any change to offsets/weights breaks parity.
//
// NOTE: the reference uniform is named `kernel`. The HLSL/Unity port renamed it to
// `kernel_u` because Unity declares a real uniform variable and `kernel` is a reserved
// Metal keyword. Here the backend injects `#define kernel data[N].x`, so the token
// `kernel` is macro-expanded to `data[N].x` before compilation — no MSL symbol named
// `kernel` ever exists, so the bare reference name is correct and safe.
//
// PARITY TOLERANCE (logged per PORTING-GUIDE §"Per-effect checklist" 5):
//   edge is a contrast-AMPLIFYING convolution: it scales the neighbor-difference sum by
//   amount/50 (=2.0 at the default amount=100) over a 5x5/7x7 window. The standalone
//   synth/noise input it consumes already carries a 1-LSB half-float/transcendental
//   residual vs the WebGL2 golden (noise.report: max-abs-diff=1.0, ssim=0.99996, PASS).
//   The convolution sums ~20 of those ±1-LSB neighbor diffs and doubles them, magnifying
//   the upstream residual to max-abs-diff=7 at the 18 steepest-gradient pixels (of 65536);
//   SSIM stays 0.99999 and 99.97% of pixels are within ±1. Verified the diff is purely
//   upstream: every diff>=4 edge pixel sits in a 5x5 noise neighborhood with 19-24/25
//   non-zero ±1-LSB diffs. The edge formula itself is bit-faithful to edge.wgsl. Run with
//   a logged tolerance of 8 for this amplifying-convolution case:
//     GODOT=… bash parity/run.sh edge 8
layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

// WGSL: const LUMA = vec3<f32>(0.2126, 0.7152, 0.0722);
const vec3 LUMA = vec3(0.2126, 0.7152, 0.0722);

// getWeight — verbatim from WGSL.
// fine (kernelType==0): cardinal neighbors (dx==0 || dy==0) -> -1, else 0.
// bold (kernelType!=0): all neighbors -> -1. Center -> 0.
float getWeight(int dx, int dy, int kernelType) {
	if (dx == 0 && dy == 0) { return 0.0; }

	if (kernelType == 0) {
		// fine: cardinal neighbors only (cross Laplacian)
		if (dx == 0 || dy == 0) { return -1.0; }
		return 0.0;
	} else {
		// bold: all neighbors equally
		return -1.0;
	}
}

// applyBlend — verbatim from WGSL.
// WGSL select(false_val, true_val, cond) -> cond ? true_val : false_val (operands reversed).
vec4 applyBlend(vec4 edge, vec4 orig, int mode) {
	if (mode == 0) { return min(orig + edge, vec4(1.0)); }                          // add
	if (mode == 1) { return min(orig, edge); }                                       // darken
	if (mode == 2) { return abs(orig - edge); }                                      // difference
	if (mode == 3) { return min(orig / max(1.0 - edge, vec4(0.001)), vec4(1.0)); }  // dodge
	if (mode == 4) { return max(orig, edge); }                                       // lighten
	if (mode == 5) { return orig * edge; }                                           // multiply
	if (mode == 7) {                                                                  // overlay
		float r = (orig.r < 0.5) ? (2.0 * orig.r * edge.r) : (1.0 - 2.0 * (1.0 - orig.r) * (1.0 - edge.r));
		float g = (orig.g < 0.5) ? (2.0 * orig.g * edge.g) : (1.0 - 2.0 * (1.0 - orig.g) * (1.0 - edge.g));
		float b = (orig.b < 0.5) ? (2.0 * orig.b * edge.b) : (1.0 - 2.0 * (1.0 - orig.b) * (1.0 - edge.b));
		return vec4(r, g, b, orig.a);
	}
	if (mode == 8) { return 1.0 - (1.0 - orig) * (1.0 - edge); }                    // screen
	return edge;                                                                     // normal (6)
}

void main() {
	vec2 texSize = vec2(textureSize(inputTex, 0));
	vec2 uv = gl_FragCoord.xy / texSize;
	vec2 texelSize = 1.0 / texSize;

	vec4 origColor = texture(inputTex, uv);

	int kernelType = int(kernel);        // WGSL: i32(u.kernel)
	int radius = int(size) + 1;          // WGSL: i32(u.size)+1; 0->1, 1->2, 2->3
	int blendMode = int(blend);          // WGSL: i32(u.blend)
	bool doInvert = invert > 0.5;        // WGSL: u.invert > 0.5
	bool useLuma = channel > 0.5;        // WGSL: u.channel > 0.5

	// Convolution
	vec3 conv = vec3(0.0);
	float centerWeight = 0.0;

	for (int dy = -3; dy <= 3; dy = dy + 1) {
		for (int dx = -3; dx <= 3; dx = dx + 1) {
			if (abs(dx) > radius || abs(dy) > radius) { continue; }
			if (dx == 0 && dy == 0) { continue; }

			float w = getWeight(dx, dy, kernelType);
			if (w == 0.0) { continue; }

			vec2 offset = vec2(float(dx), float(dy)) * texelSize;
			vec3 s = texture(inputTex, uv + offset).rgb;

			if (useLuma) {
				conv = conv + vec3(dot(s, LUMA)) * w;
			} else {
				conv = conv + s * w;
			}

			centerWeight = centerWeight - w;
		}
	}

	// Center sample
	vec3 centerSample = origColor.rgb;
	if (useLuma) {
		centerSample = vec3(dot(centerSample, LUMA));
	}
	conv = conv + centerSample * centerWeight;

	// Amount
	conv = conv * (amount / 50.0);
	conv = clamp(conv, vec3(0.0), vec3(1.0));

	// Threshold (before invert so it measures actual edge strength)
	if (threshold > 0.0) {
		float thresh = threshold / 100.0;
		float edge;
		if (useLuma) {
			edge = conv.r;
		} else {
			edge = dot(conv, LUMA);
		}
		float mask = smoothstep(thresh - 0.01, thresh + 0.01, edge);
		conv = conv * mask;
	}

	// Invert
	if (doInvert) {
		conv = 1.0 - conv;
	}

	// Blend
	vec4 edgeColor = vec4(conv, origColor.a);
	vec4 blended = applyBlend(edgeColor, origColor, blendMode);

	// Mix
	float m = mixAmt / 100.0;
	frag = vec4(mix(origColor.rgb, blended.rgb, m), origColor.a);
}
