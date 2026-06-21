# noisemaker-godot

A parallel port of the **Noisemaker shader engine** to **Godot 4.7**. It renders
**live procedural textures from the Polymorphic DSL** through Godot's low-level
`RenderingDevice` GPGPU pipeline, aiming to be **pixel-identical** (within float→8-bit
rounding) to the JS/WebGL2 reference engine. It is the Godot sibling of the Unity/HLSL
Noisemaker port and reuses that port's engine-agnostic "brain" verbatim (the
re-implementer specs, the golden graph exporter, the parity comparator).

> **Dev tooling needs the reference engine.** The golden-graph exporter and golden-image
> harness import the unchanged JS Noisemaker compiler/renderer. Point them at a checkout of
> the reference repo with `NM_REFERENCE_ROOT=/path/to/noisemaker` — this repo does **not**
> assume any sibling checkout. The Godot addon itself (`godot/addons/noisemaker/`) is
> self-contained and needs none of this.

> **🚧 WIP — early development.** The render-graph executor and the ported effect set are
> pixel-parity on Apple Silicon (Metal). The **agents/points capability** (MRT + procedural
> points/billboards deposit) is built and the emergent north-star `target.dsl`
> (particles → navierStokes → palette/lighting/lens) **renders end-to-end and stably**.
> The live in-engine DSL compiler and the 3D effects are still staged. Treat current output
> as provisional.
>
> **Known parity limit — the chaos gate.** Every effect is bit-exact to the reference
> *except chaotic agent flows* (and the `target.dsl` that feeds one into a fluid solver):
> those render correctly but as a *different instance* of the chaos, gated by a single
> spec-legal ~1-ULP `pow` rounding difference in Godot's shader compiler that the chaotic
> loop amplifies. Cause, effect, evidence, and repro are documented in
> [docs/CHAOS-GATE.md](docs/CHAOS-GATE.md).

## Layout

```
noisemaker-godot/
├─ README.md                 ← you are here
├─ ARCHITECTURE.md           ← how each reference subsystem maps to GDScript/Godot-GLSL
├─ PORTING-GUIDE.md          ← the WGSL → Godot-GLSL rulebook (read before porting a shader)
├─ docs/
│  ├─ IMPLEMENTATION-PLAN.md ← the phased build plan
│  └─ GRAPH-JSON-SCHEMA.md   ← the Render Graph JSON contract (exporter ↔ runtime)
├─ reference/                ← engine-agnostic re-implementer specs (01–10), copied from the Unity port
├─ tools/                    ← Node: export-graph (golden), convert-definitions — reused unchanged
├─ parity/                   ← golden-image harness + Godot candidate renderer + compare.py + programs
└─ godot/                    ← the Godot project (open in the editor)
   └─ addons/noisemaker/
      ├─ runtime/   ← RenderingDevice render-graph executor (nm_backend.gd)
      ├─ shaders/   ← nm_core include + per-effect GLSL ports
      ├─ effects/   ← effect-definition JSON consumed by the runtime
      └─ tools/     ← render_graph.gd offline candidate renderer
```

## The core idea: a shared Render Graph

The reference compiles DSL into a **Render Graph** (`passes / programs / textures /
renderSurface`). That is the seam. noisemaker-godot consumes the same normalized graph
JSON the Unity port does, produced two ways:

- **Golden / offline** — `tools/export-graph.mjs` runs the *unchanged reference*
  `compileGraph` and serialises the graph to JSON (zero graph-construction parity risk).
  Reused verbatim from the Unity port.
- **Live / in-engine** *(staged)* — a GDScript DSL frontend will compile DSL at runtime,
  validated by diffing its JSON against the golden path.

Both feed the same `nm_backend.gd` executor + Godot-GLSL shaders, so visual parity
depends only on the executor and the shaders — see [ARCHITECTURE.md](ARCHITECTURE.md).

## Why `RenderingDevice` (not `.gdshader`)

The engine needs exact `rgba16f`/`rgba32f` render targets, MRT-in-one-pass, explicit
ping-pong double-buffering, and bit-exact linear float with **no implicit sRGB**.
Godot's high-level `.gdshader` + `SubViewport` path structurally cannot meet those
(it caps at `rgba16f`, forces sRGB on viewport readback, and has no user MRT).
`RenderingDevice` (Vulkan-GLSL, `#version 450`) gives all of it. Its coordinate system
is **top-left / Vulkan Y-down clip** — identical to WGSL/D3D — so shaders are ported
**from the reference WGSL with no per-effect Y-flip**; a single global flip at present
reconciles to the webgl2 golden.

## Quick start (parity harness)

`RenderingDevice` is **null under `--headless`**, so the offline renderer runs Godot
*non-headless with an offscreen window* (the analog of Unity batchmode):

```bash
# 1. (once) regenerate effect-definition JSON + golden graph JSON
node tools/convert-definitions.mjs
node tools/export-graph.mjs --file parity/programs/noise.dsl parity/out/noise.graph.json

# 2. render the Godot candidate + compare to the golden (per program)
GODOT=/Applications/Godot.app/Contents/MacOS/Godot bash parity/run.sh noise
#   -> [PASS] noise: max-abs-diff=1.000 ... ssim=0.99996
```

## Status

**71 / 71 ported effects pixel-parity** on Apple M4 / Metal (single `bash parity/sweep.sh`
run; the large majority within 1/255, SSIM ≈ 1.0). A handful trip the strict ≤2 gate at
0.01–0.18% of pixels — each a faithful verbatim port where cross-device fp drift is amplified
through a discontinuity (`step`), contrast convolution (`edge`), or NEAREST coord-resampling
boundary tie (`uvRemap`, `distortion`) — and is **SSIM-gated** with a documented per-program
tolerance in `parity/sweep.sh`.

| Namespace | Parity | Highlights |
|---|---|---|
| `synth` | 19 / 29 | generators, df64 fractals (mandelbrot/julia/newton), value/simplex/cell/gabor/curl noise |
| `filter` | 32 / 90 | color ops, convolutions, warps, multi-pass (blur, **bloom**, celShading, outline, smooth), **feedback** |
| `mixer` | 13 / 14 | whole namespace bar `channelCombine` (3-input) |
| `classicNoisedeck` | 7 / 20 | legacy generators (noise/fractal/caustic/moodscape/shapes/noise3d/bitEffects) |
| `points`/`render`/`synth3d`/`filter3d` | staged | agents (MRT/scatter), 3D volumes/raymarch/meshes |

The expansion set exercises the full executor: pooled intermediates, multi-pass + multi-program
(separable `blur` → `blurH`/`blurV`, `bloom` → 3 programs), 2–3-input mixing, compile-time
defines, engine globals, both the reference-`uniformLayout` and synthesized no-layout uniform
models, NEAREST-filtered coord-resampling (warps), and the **multi-frame feedback/state loop**
(`feedback`: 8-frame settle with a persistent zero-initialized buffer, auto-detected). Only
same-pass read+write state (cellularAutomata) still needs ping-pong double-buffering (staged).

Each ported effect ships a Godot-GLSL fragment shader under
`godot/addons/noisemaker/shaders/effects/<ns>/<prog>.glsl`; the effect-definition JSON
is generated from the reference by `tools/convert-definitions.mjs`. The per-effect port
path is documented in [PORTING-GUIDE.md](PORTING-GUIDE.md), and the engine-agnostic
architecture (reused from the Unity port) means the remaining effects are mechanical
applications of that documented procedure.

## License

Released under the MIT License (see [LICENSE](LICENSE)). Use of the Noisemaker and Noise
Factor names in derivative products is subject to the [Trademark Policy](TRADEMARK.md).

Copyright © 2026 Noise Factor LLC
