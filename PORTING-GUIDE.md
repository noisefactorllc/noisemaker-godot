# Noisemaker → Godot-GLSL Shader Porting Guide

The rulebook for porting a Noisemaker effect shader to Godot `RenderingDevice` GLSL
**pixel-identically**. Derived from the reference specs (`reference/07`, `reference/08`)
and validated against the 8 Tier-1 ports. Every rule here is a parity requirement, not a
style preference.

## Golden rules

1. **Port from the WGSL source, not the GLSL.** WGSL is top-left / D3D-oriented, exactly
   like Godot's Vulkan `RenderingDevice`. Porting from WGSL means **no per-effect Y-flip**
   (the runtime applies one global flip at present). Use the matching HLSL port
   (`../noisemaker-hlsl/.../Shaders/Effects/<ns>/<Name>.hlsl`) as a cross-check — it is
   already a correct WGSL→top-left port. Use the reference GLSL only to disambiguate.
2. **Port helpers verbatim, per effect.** `pcg`/`prng`/`random`/`map`/`periodicFunction`/
   `positiveModulo` (and `PI`/`TAU`) are the *only* shared primitives, in
   `include/nm_core.glsl`. Everything else — `rotate2D`, distance metrics, `smin`, `shape`,
   color conversions, noise variants — is frequently **different between effects despite
   identical names**. Copy each effect's own version inline. ⚠️ Some effects redefine even
   the "shared" ones: `synth/shape`'s `periodicFunction` uses `sin`, not `nm_core`'s `cos`
   — inline the effect's version under a renamed symbol when it differs. Likewise full-
   precision `PI`/`TAU` (`3.141592653589793`) when an effect's WGSL uses them.
3. **Do not simplify or reassociate arithmetic.** The references contain deliberately
   redundant expressions (e.g. `catmullRom3`'s partially-cancelling terms). Reproduce them
   literally.
4. **Full 32-bit float only.** Never `mediump`/`lowp`. PCG and `floatBitsToUint(fract(s))`
   are bit-sensitive. `RenderingDevice` does not force relaxed precision.

## Shader skeleton

Two shapes, by whether the effect has a reference `uniformLayout` (check
`addons/noisemaker/effects/<ns>/<func>.json`).

**Layout effect** (declares its own UBO, reads `data[]` verbatim from WGSL):
```glsl
#version 450
#include "include/nm_core.glsl"
layout(set = 0, binding = 0, std140) uniform Params { vec4 data[N]; };   // N = max slot + 1
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;
// ... per-effect helpers (inlined verbatim) ...
void main() { /* read data[i].comp exactly as the WGSL; gl_FragCoord for position; frag = ...; */ }
```

**No-layout effect** (backend injects the UBO + `#define`s; use bare reference names):
```glsl
#version 450
#include "include/nm_core.glsl"            // omit if it uses no shared primitives
layout(set = 0, binding = 1) uniform sampler2D inputTex;   // inputs only, binding 1.. in pass.inputs order
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;
// ... helpers ...
void main() { /* use bare names: resolution, time, st, radiusX, mode, ... ; frag = ...; */ }
```
Do **not** declare a `Params` UBO or any `uniform`/`#define` for params or engine globals
in a no-layout shader — the backend synthesizes the layout and injects them. Available
bare engine names: `resolution`, `time`, `aspectRatio`, `tileOffset`, `fullResolution`,
`renderScale`. Param names are the `uniform` fields in the effect's `<func>.json` globals.

## Translation table (WGSL → Godot-GLSL)

| Concept | WGSL | Godot GLSL (`#version 450`) | Notes |
|---|---|---|---|
| vectors | `vecN<f32>`,`vecN<i32>`,`vecN<u32>` | `vecN`,`ivecN`,`uvecN` | |
| scalars | `f32`,`i32`,`u32` | `float`,`int`,`uint` | |
| bindings | `var<uniform> u : T` | (injected / `data[]` UBO) | no loose uniforms in Vulkan |
| typed local | `let x = …;` / `var x = …;` | `float x = …;` (explicit type) | GLSL has no inference |
| select | `select(a, b, cond)` | `cond ? b : a` | **operands reversed** |
| float bits→uint | `bitcast<u32>(f)` | `floatBitsToUint(f)` | bit reinterpret (jitter) |
| uint bits→float | `bitcast<f32>(u)` | `uintBitsToFloat(u)` | |
| float→uint | `vec3<u32>(p)`,`u32(f)` | `uvec3(p)`,`uint(f)` | **truncation**, not a bit-cast |
| uint→float | `f32(u)`,`f32(0xffffffffu)` | `float(u)`,`float(0xffffffffu)` | round-to-nearest |
| atan2 | `atan2(a, b)` | `atan(a, b)` | **copy arg order literally** |
| float mod | `modulo(a,b)` / `a - b*floor(a/b)` | `mod(a, b)` | GLSL `mod` == that identity |
| matrix | `mat2x2<f32>(a,b,c,d)` | `mat2(a,b,c,d)` | both column-major; `M*v` same |
| texture size | `textureDimensions(t, 0)` | `textureSize(t, 0)` | returns `ivec2` → cast to `vec2` |
| sample | `textureSample(t, s, uv)` | `texture(t, uv)` | combined `sampler2D`, linear, clamp |
| frag coord | `@builtin(position) position` | `gl_FragCoord` | top-left, +0.5 — **no flip** |
| out color | `-> @location(0) vec4<f32>` (return) | `frag` (`out vec4`) | assign instead of return |
| switch | `switch x { case 0:{…} default:{…} }` | if/else-if chain | safest |
| loop | `for (var i=…; i<=n; i++)` | `for (int i=…; i<=n; i++)` | keep bounds inclusive exactly |

## Coordinate & sampling parity

- `st = (gl_FragCoord.xy + tileOffset) / fullResolution.y` — **divide by HEIGHT (.y)** for
  most synths (x then spans `[0, aspect]`); filters divide by the **input texture size**
  (`textureSize`). Match the WGSL exactly.
- `gl_FragCoord` is top-left in Godot/Vulkan (matches WGSL). **Never add a per-effect
  Y-flip.** If a WGSL shader contains an explicit flip (e.g. `res.y - position.y`),
  **drop it** — our pipeline + the single present flip already handle orientation (see
  `synth/osc2d`).
- Samplers are linear + clamp-to-edge by default. `texture(t, uv)` with uv outside `[0,1]`
  clamps; match the reference's wrap where it tiles.

## Compile-time defines

`NOISE_TYPE`, `LOOP_OFFSET`, `LOOP_A_OFFSET`, … are injected by the runtime as integer
`#define`s (from the graph pass's `defines`). Keep them as **bare identifiers** in the
shader (`if (NOISE_TYPE == 3) {…}`); do not declare or hardcode them. When a helper takes
an `int` parameter, narrow at the call site (`int(NOISE_TYPE)`) — value is always integral.

## macOS / Metal gotchas

- Godot cross-compiles SPIR-V→MSL on macOS. A function or variable named for an **MSL
  keyword** compiles past glslang but fails the Metal stage and the pass draws nothing.
  Seen: WGSL helper `constant()` → rename to `constantValue()` (`synth/shape`). (`point`
  is *not* a GLSL reserved word and is fine.)
- `RenderingDevice` is null under `--headless`; the parity harness runs Godot non-headless
  with an offscreen window.

## Multi-program effects

An effect with several programs (e.g. `filter/blur` → `blurH`, `blurV`) ships one
`<progName>.glsl` per program; the runtime routes by the graph pass's `progName`. The
effect-definition JSON (and its synthesized layout) is shared across the programs.

## Per-effect checklist

1. Identify layout vs no-layout from `effects/<ns>/<func>.json`. Pick the skeleton.
2. Port the WGSL body verbatim (helpers inline, no arithmetic changes), applying the table.
3. Drop any explicit Y-flip; use `gl_FragCoord`.
4. Write `addons/noisemaker/shaders/effects/<ns>/<progName>.glsl`.
5. Verify: `GODOT=… bash parity/run.sh <name>` → `[PASS]` (max-abs-diff ≤ 2, SSIM ≥ 0.98).
   Loosen tolerance only for genuinely chaotic effects (feedback/agents), and **log** it.
