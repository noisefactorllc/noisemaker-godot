#version 450
// classicNoisedeck/shapes — ported PIXEL-IDENTICALLY from the canonical WGSL:
//   shaders/effects/classicNoisedeck/shapes/wgsl/shapes.wgsl
// Generator (no input). Single render pass. Interference patterns from two
// geometric/noise primitives blended through a procedural palette.
//
// Layout effect: declares its own UBO `vec4 data[7]` (max slot 6 +1) read
// verbatim per effects/classicNoisedeck/shapes.json `uniformLayout`. The backend
// injects ONLY `#define LOOP_A_OFFSET <n>` / `#define LOOP_B_OFFSET <n>` after
// #version (graph pass `defines`); engine names are NOT #defined for layout
// effects, so the WGSL `var<private>` globals are plain file-scope vars here and
// no reserved-name collision applies.
//
// Porting notes (PORTING-GUIDE):
//  * Helpers inlined verbatim, no arithmetic reassociation.
//  * This effect's `periodicFunction` uses sin (map(sin(TAU*p),-1,1,0,1)) — it
//    DIFFERS from nm_core's cos version, so nm_core is NOT included; PI/TAU/map/
//    modulo/pcg/prng/periodicFunction are all reproduced inline as the WGSL has.
//  * pcg/prng fold variant; prng divisor float(0xffffffffu); uvec3(p) is
//    float->uint truncation (NOT a bitcast).
//  * atan2 arg order copied literally: atan2(st2.x, st2.y) -> atan(st2.x, st2.y).
//  * select(a, b, cond) -> reversed ternary  cond ? b : a.
//  * mat3x3<f32>(c0,c1,c2) -> mat3(c0,c1,c2); both column-major, M*v identical
//    (oklab matrices translate directly, no transpose).
//  * st = pos.xy / resolution.y  — DIVIDE BY HEIGHT (resolution = data[0].xy,
//    bound to screen size by the backend). gl_FragCoord is top-left, +0.5; NO
//    Y-flip. The trailing WGSL `st2 = pos.xy/resolution` is dead (unused) and
//    omitted; unused WGSL rotate2D/random are likewise omitted.
//  * Full 32-bit float throughout (PCG bit-sensitive).
//  * WGSL helper `constant()` renamed to `constantValue()` — `constant` is an MSL
//    address-space keyword; the original name compiles past glslang but fails the
//    Metal stage (matches synth/shape). Pure symbol rename, no behavior change.

layout(set = 0, binding = 0, std140) uniform Params { vec4 data[7]; };
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

// WGSL var<private> globals (set from data[] in main()).
vec2 resolution;
float time;
float seed;
bool wrap;
float loopAScale;
float loopBScale;
float speedA;
float speedB;
int paletteMode;
vec3 paletteOffset;
vec3 paletteAmp;
vec3 paletteFreq;
vec3 palettePhase;
int cyclePalette;
float rotatePalette;
float repeatPalette;
float aspectRatio;

const float PI = 3.14159265359;
const float TAU = 6.28318530718;

float modulo(float a, float b) {
    return a - b * floor(a / b);
}

float map(float value, float inMin, float inMax, float outMin, float outMax) {
    return outMin + (outMax - outMin) * (value - inMin) / (inMax - inMin);
}

uvec3 pcg(uvec3 v_in) {
    uvec3 v = v_in * 1664525u + 1013904223u;
    v.x = v.x + v.y * v.z;
    v.y = v.y + v.z * v.x;
    v.z = v.z + v.x * v.y;
    v = v ^ (v >> uvec3(16u));
    v.x = v.x + v.y * v.z;
    v.y = v.y + v.z * v.x;
    v.z = v.z + v.x * v.y;
    return v;
}

vec3 prng(vec3 p0) {
    vec3 p = p0;
    if (p.x >= 0.0) { p.x = p.x * 2.0; } else { p.x = -p.x * 2.0 + 1.0; }
    if (p.y >= 0.0) { p.y = p.y * 2.0; } else { p.y = -p.y * 2.0 + 1.0; }
    if (p.z >= 0.0) { p.z = p.z * 2.0; } else { p.z = -p.z * 2.0 + 1.0; }
    uvec3 u = pcg(uvec3(p));
    return vec3(u) / float(0xffffffffu);
}

float periodicFunction(float p) {
    float x = TAU * p;
    return map(sin(x), -1.0, 1.0, 0.0, 1.0);
}

float constantValue(vec2 st_in, float freq, float speed) {
    float x = st_in.x * freq;
    float y = st_in.y * freq;
    if (wrap) {
        x = modulo(x, freq);
        y = modulo(y, freq);
    }
    x = x + seed;
    vec3 rand = prng(vec3(floor(vec2(x, y)), seed));
    float scaledTime = periodicFunction(rand.x - time) * map(abs(speed), 0.0, 100.0, 0.0, 0.33);
    return periodicFunction(rand.y - scaledTime);
}

// ---- 3×3 quadratic interpolation ----
float quadratic3(float p0, float p1, float p2, float t) {
    float t2 = t * t;
    return p0 * 0.5 * (1.0 - t) * (1.0 - t) +
           p1 * 0.5 * (-2.0 * t2 + 2.0 * t + 1.0) +
           p2 * 0.5 * t2;
}

float catmullRom3(float p0, float p1, float p2, float t) {
    float t2 = t * t;
    float t3 = t2 * t;

    return p1 + 0.5 * t * (p2 - p0) +
           0.5 * t2 * (2.0*p0 - 5.0*p1 + 4.0*p2 - p0) +
           0.5 * t3 * (-p0 + 3.0*p1 - 3.0*p2 + p0);
}

float quadratic3x3Value(vec2 st, float freq, float speed) {
    vec2 lattice = st * freq;
    vec2 f = fract(lattice);

    float nd = 1.0 / freq;

    float v00 = constantValue(st + vec2(-nd, -nd), freq, speed);
    float v10 = constantValue(st + vec2(0.0, -nd), freq, speed);
    float v20 = constantValue(st + vec2(nd, -nd), freq, speed);

    float v01 = constantValue(st + vec2(-nd, 0.0), freq, speed);
    float v11 = constantValue(st, freq, speed);
    float v21 = constantValue(st + vec2(nd, 0.0), freq, speed);

    float v02 = constantValue(st + vec2(-nd, nd), freq, speed);
    float v12 = constantValue(st + vec2(0.0, nd), freq, speed);
    float v22 = constantValue(st + vec2(nd, nd), freq, speed);

    float y0 = quadratic3(v00, v10, v20, f.x);
    float y1 = quadratic3(v01, v11, v21, f.x);
    float y2 = quadratic3(v02, v12, v22, f.x);

    return quadratic3(y0, y1, y2, f.y);
}

float catmullRom3x3Value(vec2 st, float freq, float speed) {
    vec2 lattice = st * freq;
    vec2 f = fract(lattice);

    float nd = 1.0 / freq;

    float v00 = constantValue(st + vec2(-nd, -nd), freq, speed);
    float v10 = constantValue(st + vec2(0.0, -nd), freq, speed);
    float v20 = constantValue(st + vec2(nd, -nd), freq, speed);

    float v01 = constantValue(st + vec2(-nd, 0.0), freq, speed);
    float v11 = constantValue(st, freq, speed);
    float v21 = constantValue(st + vec2(nd, 0.0), freq, speed);

    float v02 = constantValue(st + vec2(-nd, nd), freq, speed);
    float v12 = constantValue(st + vec2(0.0, nd), freq, speed);
    float v22 = constantValue(st + vec2(nd, nd), freq, speed);

    float y0 = catmullRom3(v00, v10, v20, f.x);
    float y1 = catmullRom3(v01, v11, v21, f.x);
    float y2 = catmullRom3(v02, v12, v22, f.x);

    return catmullRom3(y0, y1, y2, f.y);
}

// ---- End 3×3 interpolation ----

float blendBicubic(float p0, float p1, float p2, float p3, float t) {
    float t2 = t * t;
    float t3 = t2 * t;

    float b0 = (1.0 - t) * (1.0 - t) * (1.0 - t) / 6.0;
    float b1 = (3.0 * t3 - 6.0 * t2 + 4.0) / 6.0;
    float b2 = (-3.0 * t3 + 3.0 * t2 + 3.0 * t + 1.0) / 6.0;
    float b3 = t3 / 6.0;

    return p0 * b0 + p1 * b1 + p2 * b2 + p3 * b3;
}

float catmullRom4(float p0, float p1, float p2, float p3, float t) {
    return p1 + 0.5 * t * (p2 - p0 + t * (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3 +
           t * (3.0 * (p1 - p2) + p3 - p0)));
}

float blendLinearOrCosine(float a, float b, float amount, int interp) {
    if (interp == 1) {
        return mix(a, b, amount);
    }
    return mix(a, b, smoothstep(0.0, 1.0, amount));
}

float bicubicValue(vec2 st, float freq, float speed) {
    float ndX = 1.0 / freq;
    float ndY = 1.0 / freq;

    float u0 = st.x - ndX;
    float u1 = st.x;
    float u2 = st.x + ndX;
    float u3 = st.x + ndX + ndX;

    float v0 = st.y - ndY;
    float v1 = st.y;
    float v2 = st.y + ndY;
    float v3 = st.y + ndY + ndY;

    float x0y0 = constantValue(vec2(u0, v0), freq, speed);
    float x0y1 = constantValue(vec2(u0, v1), freq, speed);
    float x0y2 = constantValue(vec2(u0, v2), freq, speed);
    float x0y3 = constantValue(vec2(u0, v3), freq, speed);

    float x1y0 = constantValue(vec2(u1, v0), freq, speed);
    float x1y1 = constantValue(st, freq, speed);
    float x1y2 = constantValue(vec2(u1, v2), freq, speed);
    float x1y3 = constantValue(vec2(u1, v3), freq, speed);

    float x2y0 = constantValue(vec2(u2, v0), freq, speed);
    float x2y1 = constantValue(vec2(u2, v1), freq, speed);
    float x2y2 = constantValue(vec2(u2, v2), freq, speed);
    float x2y3 = constantValue(vec2(u2, v3), freq, speed);

    float x3y0 = constantValue(vec2(u3, v0), freq, speed);
    float x3y1 = constantValue(vec2(u3, v1), freq, speed);
    float x3y2 = constantValue(vec2(u3, v2), freq, speed);
    float x3y3 = constantValue(vec2(u3, v3), freq, speed);

    vec2 uv = st * freq;

    float y0 = blendBicubic(x0y0, x1y0, x2y0, x3y0, fract(uv.x));
    float y1 = blendBicubic(x0y1, x1y1, x2y1, x3y1, fract(uv.x));
    float y2 = blendBicubic(x0y2, x1y2, x2y2, x3y2, fract(uv.x));
    float y3 = blendBicubic(x0y3, x1y3, x2y3, x3y3, fract(uv.x));

    return blendBicubic(y0, y1, y2, y3, fract(uv.y));
}

float catmullRom4x4Value(vec2 st, float freq, float speed) {
    // Neighbor Distance
    float ndX = 1.0 / freq;
    float ndY = 1.0 / freq;

    float u0 = st.x - ndX;
    float u1 = st.x;
    float u2 = st.x + ndX;
    float u3 = st.x + ndX + ndX;

    float v0 = st.y - ndY;
    float v1 = st.y;
    float v2 = st.y + ndY;
    float v3 = st.y + ndY + ndY;

    float x0y0 = constantValue(vec2(u0, v0), freq, speed);
    float x0y1 = constantValue(vec2(u0, v1), freq, speed);
    float x0y2 = constantValue(vec2(u0, v2), freq, speed);
    float x0y3 = constantValue(vec2(u0, v3), freq, speed);

    float x1y0 = constantValue(vec2(u1, v0), freq, speed);
    float x1y1 = constantValue(st, freq, speed);
    float x1y2 = constantValue(vec2(u1, v2), freq, speed);
    float x1y3 = constantValue(vec2(u1, v3), freq, speed);

    float x2y0 = constantValue(vec2(u2, v0), freq, speed);
    float x2y1 = constantValue(vec2(u2, v1), freq, speed);
    float x2y2 = constantValue(vec2(u2, v2), freq, speed);
    float x2y3 = constantValue(vec2(u2, v3), freq, speed);

    float x3y0 = constantValue(vec2(u3, v0), freq, speed);
    float x3y1 = constantValue(vec2(u3, v1), freq, speed);
    float x3y2 = constantValue(vec2(u3, v2), freq, speed);
    float x3y3 = constantValue(vec2(u3, v3), freq, speed);

    vec2 uv = st * freq;

    float y0 = catmullRom4(x0y0, x1y0, x2y0, x3y0, fract(uv.x));
    float y1 = catmullRom4(x0y1, x1y1, x2y1, x3y1, fract(uv.x));
    float y2 = catmullRom4(x0y2, x1y2, x2y2, x3y2, fract(uv.x));
    float y3 = catmullRom4(x0y3, x1y3, x2y3, x3y3, fract(uv.x));

    return catmullRom4(y0, y1, y2, y3, fract(uv.y));
}

// Simplex 2D - MIT License
vec3 mod289_3(vec3 x) {
    return x - floor(x * (1.0 / 289.0)) * 289.0;
}

vec2 mod289_2(vec2 x) {
    return x - floor(x * (1.0 / 289.0)) * 289.0;
}

vec3 permute3(vec3 x) {
    return mod289_3(((x * 34.0) + 1.0) * x);
}

float simplexValue(vec2 st_in, float freq, float s, float blend) {
    const vec4 C = vec4(
        0.211324865405187,
        0.366025403784439,
        -0.577350269189626,
        0.024390243902439
    );

    vec2 uv = vec2(st_in.x * freq, st_in.y * freq);
    uv.x = uv.x + s;

    vec2 i = floor(uv + dot(uv, C.yy));
    vec2 x0 = uv - i + dot(i, C.xx);

    vec2 i1 = (x0.x > x0.y) ? vec2(1.0, 0.0) : vec2(0.0, 1.0);
    vec2 x1 = x0 - i1 + vec2(C.x, C.x);
    vec2 x2 = x0 - vec2(1.0, 1.0) + vec2(2.0 * C.x, 2.0 * C.x);

    i = mod289_2(i);
    vec3 p = permute3(permute3(i.y + vec3(0.0, i1.y, 1.0)) + i.x + vec3(0.0, i1.x, 1.0));

    vec3 m = max(vec3(0.5) - vec3(dot(x0, x0), dot(x1, x1), dot(x2, x2)), vec3(0.0));
    m = m * m;
    m = m * m;

    vec3 x = 2.0 * fract(p * C.www) - 1.0;
    vec3 h = abs(x) - 0.5;
    vec3 ox = floor(x + 0.5);
    vec3 a0 = x - ox;

    m = m * (1.79284291400159 - 0.85373472095314 * (a0 * a0 + h * h));

    vec3 g = vec3(0.0);
    g.x = a0.x * x0.x + h.x * x0.y;
    vec2 gyz = a0.yz * vec2(x1.x, x2.x) + h.yz * vec2(x1.y, x2.y);
    g.y = gyz.x;
    g.z = gyz.y;

    float v = 130.0 * dot(m, g);
    return periodicFunction(map(v, -1.0, 1.0, 0.0, 1.0) - blend);
}

float sineNoise(vec2 st_in, float freq, float s, float blend) {
    vec2 st = st_in * freq;
    st.x = st.x + s;

    float a = blend;
    float b = blend;
    float c = 1.0 - blend;

    vec3 r1 = prng(vec3(s, s, s)) * 0.75 + vec3(0.125, 0.125, 0.125);
    vec3 r2 = prng(vec3(s + 10.0, s + 10.0, s + 10.0)) * 0.75 + vec3(0.125, 0.125, 0.125);
    float x = sin(r1.x * st.y + sin(r1.y * st.x + a) + sin(r1.z * st.x + b) + c);
    float y = sin(r2.x * st.x + sin(r2.y * st.y + b) + sin(r2.z * st.y + c) + a);
    return (x + y) * 0.5 + 0.5;
}

float value(vec2 st, float freq, int interp, float speed) {
    if (interp == 3) {
        // 3×3 Catmull-Rom (9 taps)
        return catmullRom3x3Value(st, freq, speed);
    } else if (interp == 4) {
        // 4×4 Catmull-Rom (16 taps)
        return catmullRom4x4Value(st, freq, speed);
    } else if (interp == 5) {
        // 3×3 quadratic B-spline (9 taps)
        return quadratic3x3Value(st, freq, speed);
    } else if (interp == 6) {
        // 4×4 cubic B-spline (16 taps)
        return bicubicValue(st, freq, speed);
    } else if (interp == 10) {
        // simplex
        float scaledTime = periodicFunction(time) * map(abs(speed), 0.0, 100.0, 0.0, 0.333);
        return simplexValue(st, freq, seed, scaledTime);
    } else if (interp == 11) {
        // sine
        float scaledTime = periodicFunction(time) * map(abs(speed), 0.0, 100.0, 0.0, 0.333);
        return sineNoise(st, freq, seed, scaledTime);
    }
    float x1y1 = constantValue(st, freq, speed);
    if (interp == 0) {
        return x1y1;
    }
    float ndX = 1.0 / freq;
    float ndY = 1.0 / freq;
    float x1y2 = constantValue(vec2(st.x, st.y + ndY), freq, speed);
    float x2y1 = constantValue(vec2(st.x + ndX, st.y), freq, speed);
    float x2y2 = constantValue(vec2(st.x + ndX, st.y + ndY), freq, speed);
    vec2 uv = st * freq;
    float a = blendLinearOrCosine(x1y1, x2y1, fract(uv.x), interp);
    float b = blendLinearOrCosine(x1y2, x2y2, fract(uv.x), interp);
    return blendLinearOrCosine(a, b, fract(uv.y), interp);
}

float circles(vec2 st, float freq) {
    float dist = length(st - vec2(0.5 * aspectRatio, 0.5));
    return dist * freq;
}

float rings(vec2 st, float freq) {
    float dist = length(st - vec2(0.5 * aspectRatio, 0.5));
    return cos(dist * PI * freq);
}

float diamonds(vec2 st, float freq) {
    vec2 st2 = st;
    st2 = st2 - vec2(0.5 * aspectRatio, 0.5);
    st2 = st2 * freq;
    return cos(st2.x * PI) + cos(st2.y * PI);
}

float shape(vec2 st, int sides, float blend) {
    vec2 st2 = st * 2.0 - vec2(aspectRatio, 1.0);
    float a = atan(st2.x, st2.y) + PI;
    float r = TAU / float(sides);
    return cos(floor(0.5 + a / r) * r - a) * length(st2) * blend;
}

float offset(vec2 st, float freq, int loopOffset, float speed, float seedIn) {
    if (loopOffset == 10) {
        return circles(st, freq);
    } else if (loopOffset == 20) {
        return shape(st, 3, freq * 0.5);
    } else if (loopOffset == 30) {
        return (abs(st.x - 0.5 * aspectRatio) + abs(st.y - 0.5)) * freq * 0.5;
    } else if (loopOffset >= 40 && loopOffset <= 120) {
        int sides = loopOffset / 10;
        return shape(st, sides, freq * 0.5);
    } else if (loopOffset == 200) {
        return st.x * freq * 0.5;
    } else if (loopOffset == 210) {
        return st.y * freq * 0.5;
    } else if (loopOffset >= 300 && loopOffset <= 380) {
        int idx = (loopOffset - 300) / 10;
        int interp = (idx <= 6) ? idx : (idx + 3);
        float f = (loopOffset == 300) ? map(freq, 1.0, 6.0, 1.0, 20.0) : freq;
        return 1.0 - value(st + vec2(seedIn, seedIn), f, interp, speed);
    } else if (loopOffset == 400) {
        return 1.0 - rings(st, freq);
    } else if (loopOffset == 410) {
        return 1.0 - diamonds(st, freq);
    }
    return 0.0;
}

vec3 hsv2rgb(vec3 hsv) {
    float h = fract(hsv.x);
    float s = hsv.y;
    float v = hsv.z;

    float c = v * s;
    float x = c * (1.0 - abs(modulo(h * 6.0, 2.0) - 1.0));
    float m = v - c;

    vec3 rgb = vec3(0.0);
    if (0.0 <= h && h < 1.0/6.0) {
        rgb = vec3(c, x, 0.0);
    } else if (1.0/6.0 <= h && h < 2.0/6.0) {
        rgb = vec3(x, c, 0.0);
    } else if (2.0/6.0 <= h && h < 3.0/6.0) {
        rgb = vec3(0.0, c, x);
    } else if (3.0/6.0 <= h && h < 4.0/6.0) {
        rgb = vec3(0.0, x, c);
    } else if (4.0/6.0 <= h && h < 5.0/6.0) {
        rgb = vec3(x, 0.0, c);
    } else if (5.0/6.0 <= h && h < 1.0) {
        rgb = vec3(c, 0.0, x);
    }

    return rgb + vec3(m, m, m);
}

vec3 linearToSrgb(vec3 linearColor) {
    vec3 srgb = vec3(0.0);
    for (int i = 0; i < 3; i = i + 1) {
        if (linearColor[i] <= 0.0031308) {
            srgb[i] = linearColor[i] * 12.92;
        } else {
            srgb[i] = 1.055 * pow(linearColor[i], 1.0 / 2.4) - 0.055;
        }
    }
    return srgb;
}

// oklab transform. WGSL mat3x3<f32>(col0,col1,col2) is column-major and the body
// computes M * c; GLSL mat3(col0,col1,col2) is identically column-major with M*v,
// so the columns translate directly (no transpose, unlike the HLSL port).
const mat3 fwdA = mat3(
    vec3(1.0, 1.0, 1.0),
    vec3(0.3963377774, -0.1055613458, -0.0894841775),
    vec3(0.2158037573, -0.0638541728, -1.2914855480)
);

const mat3 fwdB = mat3(
    vec3(4.0767245293, -1.2681437731, -0.0041119885),
    vec3(-3.3072168827, 2.6093323231, -0.7034763098),
    vec3(0.2307590544, -0.3411344290, 1.7068625689)
);

vec3 linear_srgb_from_oklab(vec3 c) {
    vec3 lms = fwdA * c;
    return fwdB * (lms * lms * lms);
}

vec3 pal(float t) {
    float tt = t * repeatPalette + rotatePalette * 0.01;
    vec3 color = paletteOffset + paletteAmp * cos(6.28318 * (paletteFreq * tt + palettePhase));

    if (paletteMode == 1) {
        color = hsv2rgb(color);
    } else if (paletteMode == 2) {
        color.y = color.y * -0.509 + 0.276;
        color.z = color.z * -0.509 + 0.198;
        color = linear_srgb_from_oklab(color);
        color = linearToSrgb(color);
    }

    return color;
}

void main() {
    resolution = data[0].xy;
    time = data[0].z;
    seed = data[0].w;

    wrap = data[1].x > 0.5;
    loopAScale = data[1].w;

    loopBScale = data[2].x;
    speedA = data[2].y;
    speedB = data[2].z;
    paletteMode = int(data[2].w);

    paletteOffset = data[3].xyz;
    cyclePalette = int(data[3].w);

    paletteAmp = data[4].xyz;
    rotatePalette = data[4].w;

    paletteFreq = data[5].xyz;
    repeatPalette = data[5].w;

    palettePhase = data[6].xyz;

    aspectRatio = resolution.x / resolution.y;

    vec4 color = vec4(0.0, 0.0, 1.0, 1.0);
    vec2 st = gl_FragCoord.xy / resolution.y;

    float lf1 = map(loopAScale, 1.0, 100.0, 6.0, 1.0);
    if (wrap) {
        lf1 = floor(lf1);
        if (LOOP_A_OFFSET >= 200 && LOOP_A_OFFSET < 300) {
            lf1 = lf1 * 2.0;
        }
    }
    float amp1 = map(abs(speedA), 0.0, 100.0, 0.0, 1.0);
    float t1 = 1.0;
    if (speedA < 0.0) {
        t1 = time + offset(st, lf1, LOOP_A_OFFSET, amp1, seed);
    } else if (speedA > 0.0) {
        t1 = time - offset(st, lf1, LOOP_A_OFFSET, amp1, seed);
    }

    float lf2 = map(loopBScale, 1.0, 100.0, 6.0, 1.0);
    if (wrap) {
        lf2 = floor(lf2);
        if (LOOP_B_OFFSET >= 200 && LOOP_B_OFFSET < 300) {
            lf2 = lf2 * 2.0;
        }
    }
    float amp2 = map(abs(speedB), 0.0, 100.0, 0.0, 1.0);
    float t2 = 1.0;
    if (speedB < 0.0) {
        t2 = time + offset(st, lf2, LOOP_B_OFFSET, amp2, seed + 10.0);
    } else if (speedB > 0.0) {
        t2 = time - offset(st, lf2, LOOP_B_OFFSET, amp2, seed + 10.0);
    }

    float a = periodicFunction(t1) * amp1;
    float b = periodicFunction(t2) * amp2;

    float d = abs((a + b) - 1.0);
    if (cyclePalette == -1) {
        d = d + time;
    } else if (cyclePalette == 1) {
        d = d - time;
    }
    color = vec4(pal(d), color.a);

    frag = color;
}
