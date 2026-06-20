# noisemaker-godot

A parallel port of the [Noisemaker shader engine](../noisemaker/shaders) to **Godot 4.7**.
It renders **live procedural textures from the Polymorphic DSL** through Godot's
low-level `RenderingDevice` GPGPU pipeline, aiming to be **pixel-identical** (within
float→8-bit rounding) to the JS/WebGL2 reference engine. It is the Godot sibling of
the Unity/HLSL port [`../noisemaker-hlsl`](../noisemaker-hlsl) and reuses that port's
engine-agnostic "brain" verbatim (the re-implementer specs, the golden graph exporter,
the parity comparator).

> **🚧 WIP — early development.** The full render-graph executor and the 8 Tier-1
> programs are pixel-parity on Apple Silicon (Metal). Broad effect coverage, the live
> in-engine DSL compiler, and the chaotic/agent/3D effects are staged. Treat current
> output as provisional.

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

**29 / 29 ported effects pixel-parity** on Apple M4 / Metal (28 within 1/255, SSIM ≈ 1.0;
`newton` SSIM 0.99783 at chaotic tolerance). Run the full sweep with `bash parity/sweep.sh`.

| Namespace | Parity | Effects |
|---|---|---|
| `synth` | 19 / 29 | solid, noise, cell, gradient, shape, osc2d, testPattern, pattern, perlin, bitwise, mandelbrot, julia, gabor, modPattern, curl, mandala, sacredGeometry, subdivide, newton\* |
| `filter` | 9 / 90 | blur (blurH+blurV), emboss, posterize, bc, deriv, colorspace, invert, normalMap, pixels |
| `mixer` | 1 / 14 | blendMode |
| `points`/`render`/`synth3d`/`filter3d`/`classicNoisedeck` | staged | — |

\* `newton` is a chaotic Newton-fractal: ~0.19% of pixels (isolated root-basin boundary
speckles) differ by a `df64` ULP between WebGPU and Metal FMA — the documented cross-device
limit, gated on structural SSIM.

The **8 Tier-1** programs (`solid`/`noise`/`cell`/`gradient`/`shape`/`osc2d`/`blur`/
`blendMode`) plus the expansion set exercise the full executor: pooled intermediates,
multi-pass (separable `blur` → `blurH`/`blurV` by `progName`), multi-input mixing,
compile-time defines, engine globals, both the reference-`uniformLayout` and synthesized
no-layout uniform models, and NEAREST-filtered coord-resampling (`pixels`).

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
