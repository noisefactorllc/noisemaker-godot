#version 450
// synth/cellularAutomata — program "caFb" (the update / feedback pass). Ported from
// wgsl/caFb.wgsl. Advances the ping-pong state buffer one CA generation: counts the
// Moore neighbourhood with texelFetch (integer coords — no filtering), applies the
// preset born/survive ruleset, and seeds a random board when the buffer is empty
// (all four channels zero) or resetState. Layout effect: vec4 data[7]
// (effects/synth/cellularAutomata.json, uniformLayouts.caFb).
//
// Inputs (pass.inputs order): bufTex = binding 1 (the read buffer, integer-fetched),
// tex = binding 2 (optional previous-frame input for luminance perturbation; bound to
// a black texture when "none"). gl_FragCoord is top-left/+0.5 like the WGSL @position
// — NO Y-flip (single global flip at present). The state grid is sub-resolution
// (screenDivide), so all geometry uses textureSize(bufTex), never the screen.
//
// NOTE on pinned-time parity: at the pinned capture time deltaTime == 0, so the final
// mix() collapses to currentState — the board freezes at the frame-0 random seed. The
// rule evaluation is still ported verbatim (correctness off the pinned path + the
// shader compiles whole).
layout(set = 0, binding = 0, std140) uniform Params { vec4 data[7]; };
layout(set = 0, binding = 1) uniform sampler2D bufTex;
layout(set = 0, binding = 2) uniform sampler2D tex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

float map(float value, float inMin, float inMax, float outMin, float outMax) {
	return outMin + (outMax - outMin) * (value - inMin) / (inMax - inMin);
}

float lum(vec3 color) {
	return 0.2126 * color.r + 0.7152 * color.g + 0.0722 * color.b;
}

float random(vec2 st) {
	return fract(sin(dot(st, vec2(12.9898, 78.233))) * 43758.5453123);
}

// Born rule by preset (Moore neighbour count n). Mirrors caFb.wgsl shouldBeBorn.
bool shouldBeBorn(int n, int ruleIndex) {
	bool should = false;
	if (ruleIndex == 0 || ruleIndex == 5 || ruleIndex == 8) {
		should = n == 3;                                       // Classic Life, Life w/o Death, Maze: B3
	} else if (ruleIndex == 1 || ruleIndex == 11 || ruleIndex == 16) {
		should = n == 3 || n == 6;                             // Highlife, 2x2, Waffles: B36
	} else if (ruleIndex == 2) {
		should = n == 2;                                       // Seeds: B2
	} else if (ruleIndex == 3) {
		should = n == 3 || n == 8;                             // Coral: B38
	} else if (ruleIndex == 4) {
		should = n == 3 || n == 6 || n == 7 || n == 8;         // Day & Night: B3678
	} else if (ruleIndex == 6) {
		should = n == 1 || n == 3 || n == 5 || n == 7;         // Replicator: B1357
	} else if (ruleIndex == 7) {
		should = n == 3 || n == 5 || n == 7;                   // Amoeba: B357
	} else if (ruleIndex == 9) {
		should = n == 2 || n == 5;                             // Glider Walk: B25
	} else if (ruleIndex == 10) {
		should = n == 3 || n >= 5;                             // Diamoeba: B35678
	} else if (ruleIndex == 12) {
		should = n == 3 || n == 6 || n == 8;                   // Morley: B368
	} else if (ruleIndex == 13) {
		should = n == 4 || n == 6 || n == 7 || n == 8;         // Anneal: B4678
	} else if (ruleIndex == 14) {
		should = n == 3 || n == 4;                             // 34 Life: B34
	} else if (ruleIndex == 15) {
		should = n == 3 || n == 6 || n == 8;                   // Simple Replicator: B368
	} else if (ruleIndex == 17) {
		should = n == 3 || n == 7;                             // Pond Life: B37
	}
	return should;
}

// Survive rule by preset. Mirrors caFb.wgsl shouldSurvive (incl. the current<0.5 gate).
bool shouldSurvive(int n, float current, int ruleIndex) {
	bool should = false;
	if (ruleIndex == 0 || ruleIndex == 1 || ruleIndex == 3 || ruleIndex == 17) {
		should = n == 2 || n == 3;                             // Classic Life, Highlife, Coral, Pond Life: S23
	} else if (ruleIndex == 2) {
		should = false;                                        // Seeds: no survival
	} else if (ruleIndex == 4) {
		should = n == 3 || n == 4 || n == 6 || n == 7 || n == 8; // Day & Night: S34678
	} else if (ruleIndex == 5) {
		should = true;                                         // Life w/o Death: S012345678
	} else if (ruleIndex == 6) {
		should = n == 1 || n == 3 || n == 5 || n == 7;         // Replicator: S1357
	} else if (ruleIndex == 7) {
		should = n == 1 || n == 3 || n == 5 || n == 8;         // Amoeba: S1358
	} else if (ruleIndex == 8) {
		should = n >= 1 && n <= 5;                             // Maze: S12345
	} else if (ruleIndex == 9) {
		should = n == 4;                                       // Glider Walk: S4
	} else if (ruleIndex == 10) {
		should = n >= 5;                                       // Diamoeba: S5678
	} else if (ruleIndex == 11) {
		should = n == 1 || n == 2 || n == 5;                   // 2x2: S125
	} else if (ruleIndex == 12 || ruleIndex == 16) {
		should = n == 2 || n == 4 || n == 5;                   // Morley, Waffles: S245
	} else if (ruleIndex == 13) {
		should = n == 3 || n >= 5;                             // Anneal: S35678
	} else if (ruleIndex == 14) {
		should = n == 3 || n == 4;                             // 34 Life: S34
	} else if (ruleIndex == 15) {
		should = n == 1 || n == 2 || n == 5 || n >= 7;         // Simple Replicator: S12578
	}
	if (current < 0.5) { should = false; }
	return should;
}

bool shouldBeBornCustom(int n, vec4 bornMask0, vec4 bornMask1, float bornMask2) {
	if (n == 0) { return bornMask0.x > 0.5; }
	else if (n == 1) { return bornMask0.y > 0.5; }
	else if (n == 2) { return bornMask0.z > 0.5; }
	else if (n == 3) { return bornMask0.w > 0.5; }
	else if (n == 4) { return bornMask1.x > 0.5; }
	else if (n == 5) { return bornMask1.y > 0.5; }
	else if (n == 6) { return bornMask1.z > 0.5; }
	else if (n == 7) { return bornMask1.w > 0.5; }
	else if (n == 8) { return bornMask2 > 0.5; }
	return false;
}

bool shouldSurviveCustom(int n, float current, vec3 surviveMask0, vec4 surviveMask1, vec2 surviveMask2) {
	bool should = false;
	if (n == 0) { should = surviveMask0.x > 0.5; }
	else if (n == 1) { should = surviveMask0.y > 0.5; }
	else if (n == 2) { should = surviveMask0.z > 0.5; }
	else if (n == 3) { should = surviveMask1.x > 0.5; }
	else if (n == 4) { should = surviveMask1.y > 0.5; }
	else if (n == 5) { should = surviveMask1.z > 0.5; }
	else if (n == 6) { should = surviveMask1.w > 0.5; }
	else if (n == 7) { should = surviveMask2.x > 0.5; }
	else if (n == 8) { should = surviveMask2.y > 0.5; }
	if (current < 0.5) { should = false; }
	return should;
}

ivec2 clampCoord(ivec2 p, ivec2 size) {
	int cx = clamp(p.x, 0, size.x - 1);
	int cy = clamp(p.y, 0, size.y - 1);
	return ivec2(cx, cy);
}

// Fetch a single cell value with integer coords to avoid any filtering.
float cellAt(ivec2 p, ivec2 size) {
	ivec2 pc = clampCoord(p, size);
	return texelFetch(bufTex, pc, 0).r;
}

// Count Moore-neighbourhood alive cells around the base pixel.
int countNeighbors(ivec2 base, ivec2 size) {
	int count = 0;
	for (int dy = -1; dy <= 1; dy++) {
		for (int dx = -1; dx <= 1; dx++) {
			if (dx == 0 && dy == 0) { continue; }
			float n = cellAt(base + ivec2(dx, dy), size);
			count += int(n > 0.5);
		}
	}
	return count;
}

void main() {
	vec2 texSize = vec2(textureSize(bufTex, 0));
	ivec2 texSizeI = textureSize(bufTex, 0);
	vec2 uv = gl_FragCoord.xy / texSize;

	float deltaTime = data[0].y;
	int seed = int(data[0].z);
	bool resetState = data[0].w > 0.5;
	int ruleIndex = int(data[1].x);
	float speed = data[1].y;
	float weight = data[1].z;
	bool useCustom = data[1].w > 0.5;

	vec4 bornMask0 = data[2];
	vec4 bornMask1 = data[3];
	float bornMask2 = data[4].x;
	vec3 surviveMask0 = data[4].yzw;
	vec4 surviveMask1 = data[5];
	vec2 surviveMask2 = data[6].xy;
	int source = int(data[6].z);

	// Sample all 4 channels to detect a truly-empty buffer (first load / reset).
	ivec2 base = ivec2(int(gl_FragCoord.x), int(gl_FragCoord.y));
	vec4 bufState = texelFetch(bufTex, clampCoord(base, texSizeI), 0);
	float state = bufState.r;
	bool bufferIsEmpty = (bufState.r == 0.0 && bufState.g == 0.0 && bufState.b == 0.0 && bufState.a == 0.0);

	// Previous-frame luminance perturbation (sampled before any early return for
	// uniform control flow; only applied when weight > 0).
	vec3 prevFrame = texture(tex, uv).rgb;
	float prevLum = lum(prevFrame);

	if (resetState || bufferIsEmpty) {
		float r = random(uv + vec2(float(seed), float(seed)));
		float alive = step(0.5, r);
		frag = vec4(alive, alive, alive, 1.0);
		return;
	}

	int neighbors = countNeighbors(base, texSizeI);

	float newState = state;

	if (useCustom) {
		if (shouldBeBornCustom(neighbors, bornMask0, bornMask1, bornMask2)) {
			newState = 1.0;
		} else if (shouldSurviveCustom(neighbors, state, surviveMask0, surviveMask1, surviveMask2)) {
			newState = 1.0;
		} else {
			newState = 0.0;
		}
	} else {
		if (shouldBeBorn(neighbors, ruleIndex)) {
			newState = 1.0;
		} else if (shouldSurvive(neighbors, state, ruleIndex)) {
			newState = 1.0;
		} else {
			newState = 0.0;
		}
	}

	if (weight > 0.0) {
		newState = mix(newState, prevLum, weight * 0.01);
	}

	// speed is a BPM-style knob remapped to a stable integration step.
	float animSpeed = map(speed, 1.0, 100.0, 0.1, 100.0);
	vec4 currentState = vec4(state, state, state, 1.0);
	vec4 nextState = vec4(newState, newState, newState, 1.0);
	frag = mix(currentState, nextState, min(1.0, deltaTime * animSpeed));
}
