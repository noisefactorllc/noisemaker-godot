# The Chaos Gate — why chaotic agent flows aren't bit-parity on this port

**TL;DR.** Every effect in this port is bit-for-bit identical to the reference (`max-diff 0`)
**except one class: chaotic agent flows** (`points/flow`, and the north-star `target.dsl` that
feeds it into navierStokes). Those render correctly, deterministically, and stay bounded — but
they're a *different instance* of the chaos, not a pixel match (full-chain SSIM 0.5–0.73 over the
30 s / 5 s sampling). The cause is a **single `pow`**: a spec-legal ~1-ULP rounding difference in
Godot's shader-compiler that a chaotic feedback loop amplifies into a different particle field.
This is not a port bug — the shader is byte-identical to the Unity/HLSL port, which gets the
same target byte-identical. It is the engine's transcendental codegen, which is not reachable from
the addon, shader, driver, or environment.

This is the project's existing **"continuous solvers diverge cross-backend"** principle (already
documented for `reactionDiffusion`, see `reference/08-math-primitives-parity.md`) confirmed for the
chaotic *agent flow*, now pinned to one operation.

---

## Cause — one transcendental, rounded differently (and legally)

The agent flow (`shaders/effects/points/flow/agent.glsl`) steers each agent by the **OKLab
lightness** of the field sampled at the agent's position:

```glsl
inputLuma  = oklab_l(texel.rgb);                  // texel = field at the agent's position
indexValue = mix(0.5, inputLuma, inputWeight*.01);
finalAngle = indexValue * TAU * kink + rotRand * TAU;
newPos     = fract(pos + vec2(sin(finalAngle), cos(finalAngle)) * stride);
```

`oklab_l` calls `pow(x, 2.4)` (sRGB→linear) and `pow(x, 1.0/3.0)` (cube root). **A non-integer power
is not multiplication** — you can't multiply a value "2.4 times." It's a transcendental, lowered by
the hardware to `exp2(y · log2(x))`. The GLSL ES and Metal specifications **do not require**
`pow`/`exp2`/`log2` to be correctly rounded; they permit a few ULP of error. So two conformant
compilers may each emit a perfectly legal `pow` that disagree in the last bit.

That is exactly what happens. Godot lowers the shader `GLSL → SPIR-V (glslang) → MSL
(spirv-cross / native-Metal RD)`. The reference golden is `GLSL-ES → MSL` via ANGLE (WebGL2). These
two `pow` lowerings differ by ~1 ULP (~`1e-8`). Demonstration of the magnitude (two spec-legal
float32 lowerings of the same `pow`):

```
pow(0.42, 2.4):  correctly-rounded 0.124680422   vs   exp2/log2-in-f32 0.124680430   → ~1 ULP
```

Confirmed to be **toolchain, not driver**: identical result on **both** Godot RenderingDevice
backends — `--rendering-driver vulkan` (MoltenVK) **and** `--rendering-driver metal` (native
Metal 4.0). The difference is baked in at glslang/spirv-cross, upstream of the driver.

## Effect — a chaotic loop amplifies 1 ULP into a different world

The flow is a textbook chaotic dynamical system. Every frame, for all `stateSize²` (e.g. 1024² ≈
1 M) agents:

> position → **sample the field** → **oklab** → turn → step → **`fract()` wrap** → repeat

The ~1-ULP oklab delta is amplified **×(TAU·kink ≈ 34)** into the steering angle, then forced through
**two discontinuities** each frame:

1. **`fract()` position wrap** — discontinuous at integers; a sub-ULP nudge can flip an agent from
   one edge of the field to the other.
2. **integer-texel `texelFetch`** of the field at `ivec2(pos * texSize)` — near a texel boundary, a
   sub-ULP nudge changes *which texel* is read, flipping the agent's next turn.

Over ~300 frames the divergence snowballs from `1e-8` to a visibly different agent field. The
particle output `o0` reaches **SSIM ≈ 0.88** (raw points) / **0.94** (after `blur`). The target then
feeds `o0` into a chaotic navierStokes solver, which amplifies it to the **full-chain 0.5–0.73**.

It is a *different instance of the same chaos* — the literal Lorenz "a butterfly's wingbeat" problem:
perturb a chaotic sim in the 9th decimal and you get a different-but-equally-valid outcome. Same
algorithm, same palette, same dynamics, same *kind* of structure; different exact pixels.

## Evidence — the divergence is pinned to that one `pow`

A reproducible isolation chain (all DSLs live in `parity/corpus/programs/`, harness in `parity/`):

| Test DSL                | What it isolates                                                              | Result                |
| ----------------------- | ----------------------------------------------------------------------------- | --------------------- |
| `agentsSpawn.dsl`       | spawn + point/billboard rasterization + additive deposit + diffuse + blend (no flow → bit-exact integer-hash spawn positions) | **BIT-EXACT, max-diff 0** |
| `navTargetParams.dsl`   | navierStokes at the target's exact params (speed 145 / iter 40 / bSpline4x4), static input | **6/6, ssim 0.9996**  |
| `agentsNoOklab.dsl`     | the flow with `inputWeight:0` — oklab dropped from the trajectory (constant `indexValue`), `sin`/`cos`/`fract`/everything else intact | **BIT-EXACT, max-diff 0** |
| `agentsPoints.dsl`      | the flow with oklab active (`inputWeight:100`)                                 | **ssim 0.88**         |

The *only* difference between the last two rows is whether oklab's `pow` touches the steering math.
That pins the entire divergence to that one transcendental.

**Ruled out** as the cause — every one produced *byte-identical* output to baseline, so none of them
is the mechanism:

- `precise` qualifier, both *outside* and *inside* `oklab_l` (kills any fused-multiply-add /
  reassociation in the matrix math — it's not the arithmetic, it's the transcendental)
- explicit `sin`/`cos` argument reduction to `[0,TAU)`
- rewriting `pow(x,y)` as `exp2(y*log2(x))`
- `MVK_CONFIG_FAST_MATH_ENABLED=0`
- both RenderingDevice drivers (MoltenVK and native Metal)

## Scope — exactly one class of effect; everything else is bit-exact

Affected: **chaotic agent flows only** (`points/flow`; the `target.dsl` north-star through it).

Bit-exact (`max-diff 0`, verified): all 93 isolated effects in `parity/sweep.sh`, the navierStokes
solver in isolation, the entire deposit / diffuse / blend path, agent spawn, all non-chaotic
stateful sims at their stable regimes.

**The target is stable, not broken.** Blown-out (pure-white) pixels hold at ~0.5–1 % of the frame,
in line with the golden's ~0–0.8 %; mean brightness stays bounded and oscillates with the loop
rather than climbing. The over-deposit / white-out that an unfixed Metal build would show is
prevented by two fixes ported from the Unity/HLSL port (commit abb9578):

- **density-cull precision** — `fract(particleID·GR)` loses float32 precision at ~1 M agents
  (step ~0.06 near 6.5e5 → quantizes to ~16 buckets → Metal over-deposits ~8× vs ANGLE). A hi/lo
  split keeps the products small so `fract` stays exact (`render/points*/deposit.vert.glsl`).
- **nav input clamp to [0,1]** — bounds the HDR particle-field surface this pipeline hands
  navierStokes, so dye injection can't saturate (`synth/navierStokes/nsSplat.glsl`, `ns.glsl`).

## Why three.js / babylon / hlsl match but Godot can't

- **three.js, babylon** get this exact target *byte-identical* — because they **are** WebGL2/ANGLE,
  the same compiler as the golden, so their `pow` produces the same bits.
- **The Unity/HLSL port** matched on Unity/Metal — its HLSL→Metal `pow` happens to align with ANGLE's.
  Its `Flow.hlsl` oklab is byte-identical to this port's, and its *only* fixes for this target were
  the frac-cull + nav-clamp above (which this port also applies).
- **Godot** is the outlier: its GLSL→SPIR-V→Metal `pow` rounds that one bit its own (legal) way.

## What would close it (engine-level — out of port scope)

The fix is not in the addon, the shader, the driver, or the environment. It would require either:

- a glslang / spirv-cross `pow` lowering that matches Metal's native `metal::pow`, or
- forcing precise transcendentals in Godot's Metal shader compile (MTLCompileOptions precision).

Until then, chaotic agent flows are **SSIM-divergent by design**, in the same documented class as
`reactionDiffusion` — faithful, stable, and correct, but a different instance of the chaos.

## Reproduce

```bash
GODOT=/Applications/Godot.app/Contents/MacOS/Godot

# 1. spawn/raster/deposit are bit-exact (no flow):
SHADE_HEADLESS=1 node parity/export-and-render.mjs parity/corpus/programs/agentsSpawn.dsl \
    parity/out --size 256 --backend webgl2 --run-seconds 10 --sample-every 5
$GODOT --rendering-driver metal --path godot --script res://addons/noisemaker/tools/render_graph.gd \
    --position 5000,5000 -- --graph parity/out/agentsSpawn.graph.json \
    --out parity/out/agentsSpawn.candidate.png --size 256 --run-seconds 10 --sample-every 5
# → max-diff 0.000, ssim 1.00000

# 2. nav at target params is bit-exact (static input):  navTargetParams.dsl  → 6/6 ssim 0.9996
# 3. flow WITHOUT oklab is bit-exact:                    agentsNoOklab.dsl    → max-diff 0
# 4. flow WITH oklab diverges (the gate):                agentsPoints.dsl     → ssim 0.88
#    (drive each with run_samples.sh / export-and-render.mjs as in steps 1)
```
