# noisemaker-godot

A parallel port of the **Noisemaker shader engine** to **Godot 4.7**. It compiles the
**Polymorphic DSL** to a render graph and executes it on Godot's low-level `RenderingDevice`
GPGPU pipeline to produce live procedural textures — aiming to be **pixel-identical** (within
float→8-bit rounding) to the JS/WebGL2 reference engine. It is the Godot sibling of the
Unity/HLSL Noisemaker port and reuses that port's engine-agnostic "brain" (the re-implementer
specs and the parity comparator).

> **The addon is self-contained at runtime.** `godot/addons/noisemaker/` compiles the DSL to a
> render graph **and** executes it on the GPU with **no Node.js, no reference engine, and no
> network** — the whole compiler is ported to GDScript (`compiler/lang` + `compiler/graph`).
> The reference engine is needed **only** by the parity/dev tooling under `tools/` and `parity/`
> (point it there with `NM_REFERENCE_ROOT=/path/to/noisemaker`; this repo assumes no sibling
> checkout). If you just want to *use* the addon, you need none of that — see
> **[godot/addons/noisemaker/README.md](godot/addons/noisemaker/README.md)**.

> **🚧 WIP — early development.** The render-graph executor, the ported 2D effect catalog, and
> the agents/points capability (MRT + procedural points/billboards deposit) render and are
> pixel-parity on Apple Silicon (Metal). The **in-engine GDScript DSL→graph compiler is complete
> and parity-verified** (158/158 across lex/parse/validate/expand/graph + full registry parity vs
> the reference). Genuinely **staged**: the 3D effects (`synth3d`/`filter3d` ship definitions but
> no shaders yet) and a drop-in editor node (integration is scripting-only today). Treat current
> output as provisional; verified on Apple Silicon/Metal only.
>
> **Known parity limit — the chaos gate.** Every effect is bit-exact to the reference *except
> chaotic agent flows* (and the `target.dsl` that feeds one into a fluid solver): those render
> correctly but as a *different instance* of the chaos, gated by a single spec-legal ~1-ULP `pow`
> rounding difference in Godot's shader compiler that the chaotic loop amplifies. A second, milder
> class (~13 effects) drifts ≤1–2 LSB on <0.2% of pixels at resampling/discontinuity boundaries and
> is SSIM-gated. Cause, effect, evidence, and repro: [docs/CHAOS-GATE.md](docs/CHAOS-GATE.md).

## Use it in your Godot project

Full integration docs (Requirements, Installation, Host API, Troubleshooting) live in the addon
README — **[godot/addons/noisemaker/README.md](godot/addons/noisemaker/README.md)**. The short
version:

1. Copy `godot/addons/noisemaker/` into your project's `res://addons/`.
2. *Project Settings ▸ Plugins ▸* enable **Noisemaker** (Godot **4.7**, **Forward+**).
3. Compile a DSL and render it — entirely in-engine, no reference required:

```gdscript
# Requires a real RenderingDevice → run with a window (it is null under --headless).
const EffectRegistry := preload("res://addons/noisemaker/compiler/lang/effect_registry.gd")
const Orchestrator   := preload("res://addons/noisemaker/compiler/graph/orchestrator.gd")
const Backend        := preload("res://addons/noisemaker/runtime/nm_backend.gd")

var rd := RenderingServer.create_local_rendering_device()
var reg := EffectRegistry.new(); reg.load_all()
var graph = Orchestrator.new(reg).build_graph("search synth\nnoise(scaleX: 60).write(o0)\nrender(o0)")

var backend := Backend.new()
backend.setup(rd, "res://addons/noisemaker", Vector2i(512, 512))
var img: Image = backend.render_samples(graph, 1, 1)[0]   # one frame; for stateful sims pass more
var tex := ImageTexture.create_from_image(img)            # → use on any material / TextureRect
```

Or render a `.dsl` file to a PNG from the command line (the self-contained production path):

```bash
GODOT=/Applications/Godot.app/Contents/MacOS/Godot
$GODOT --path godot --script res://addons/noisemaker/tools/render_graph.gd \
       --position 5000,5000 -- --dsl parity/programs/noise.dsl --out /tmp/noise.png --size 256
```

`tools/present.gd` is a companion that composes the DSL source beside the rendered canvas (used for
the flagship `target.dsl` demo).

## Why `RenderingDevice` (not `.gdshader`)

The engine needs exact `rgba16f`/`rgba32f` render targets, MRT-in-one-pass, explicit ping-pong
double-buffering, and bit-exact linear float with **no implicit sRGB**. Godot's high-level
`.gdshader` + `SubViewport` path structurally cannot meet those (it caps at `rgba16f`, forces sRGB
on viewport readback, and has no user MRT). `RenderingDevice` (Vulkan-GLSL, `#version 450`) gives
all of it. Its coordinate system is **top-left / Vulkan Y-down clip** — identical to WGSL/D3D — so
shaders are ported **from the reference WGSL with no per-effect Y-flip**; a single global flip at
present reconciles to the webgl2 golden.

A consequence integrators should know: the executor needs a **real `RenderingDevice`**, which is
**null under `--headless`** — so rendering needs a window (no dedicated-server/CI rendering). See
the addon README's Requirements.

## The compiler: DSL → render graph, in-engine

The reference compiles DSL into a normalized **Render Graph** (`passes / programs / textures /
renderSurface`). That graph is the engine-agnostic seam, and noisemaker-godot now produces it two
ways that emit byte-identical graphs:

- **In-engine (production)** — the GDScript compiler under `godot/addons/noisemaker/compiler/`
  (`lang/`: lexer→parser→validator→effect-registry; `graph/`: expander→orchestrator). Entry point:
  `Orchestrator.new(EffectRegistry.new()).build_graph(source)`. No reference, no Node, no network.
- **Golden / offline (parity only)** — `tools/export-graph.mjs` runs the *unchanged reference*
  `compileGraph` and serialises the graph to JSON. Used only to verify the in-engine compiler.

Both feed the same `runtime/nm_backend.gd` executor + Godot-GLSL shaders. The in-engine compiler is
gated stage-by-stage against the reference by `parity/check_{lex,parse,validate,expand,graph,registry}.mjs`
(**all 158/158** over the 158-DSL corpus; registry **5/5** surfaces) — and rendering the in-engine
graph is byte-identical (same PNG) to rendering the reference's graph. See
[ARCHITECTURE.md](ARCHITECTURE.md) and [docs/GRAPH-JSON-SCHEMA.md](docs/GRAPH-JSON-SCHEMA.md).

## Status

*As of 2026-06-21 (Apple M4 / Metal). `parity/sweep.sh` + `parity/check_*.mjs` are the sources of truth.*

- **Catalog:** **182 effect definitions** (`godot/addons/noisemaker/effects/`) and ~184 GLSL shaders
  across all 8 namespaces.
- **In-engine compiler:** **158/158** across all six gates (lex/parse/validate/expand/graph) plus
  full registry parity (ops 182/182, enums, aliases, 544 effect keys) vs the reference.
- **2D effects + agents (single-frame pixel-parity, `parity/sweep.sh`):** last recorded **93/93 pass,
  2 chaos-gated skips**. Most land within 1/255 (SSIM ≈ 1.0); ~13 are SSIM-gated with documented
  per-program tolerances (resampling/discontinuity boundary drift).
- **Stateful sims (navierStokes):** pixel-parity via 30 s timed-sampling (`parity/run_samples.sh`),
  SSIM ≥ 0.999 in the stable regime.
- **Live blaster corpus:** 4/5 renderable real programs at parity; 1 chaos-gated (reactionDiffusion).
- **Staged:** 3D (`synth3d`/`filter3d` ship definitions but **0 shaders**), a drop-in editor node,
  and same-pass ping-pong for `cellularAutomata`.

| Namespace | Definitions | Shaders | State |
|---|---|---|---|
| `synth` | 29 | 33 | renders (generators, df64 fractals, value/simplex/cell/gabor/curl noise) |
| `filter` | 90 | 105 | renders (color ops, convolutions, warps, multi-pass, feedback) |
| `mixer` | 14 | 14 | renders (whole namespace) |
| `classicNoisedeck` | 20 | 18 | renders (legacy generators) |
| `points` / `render` | 10 / 11 | 2 / 12 | renders — agents (MRT/scatter); chaotic flows chaos-gated |
| `synth3d` / `filter3d` | 7 / 1 | 0 / 0 | **staged** (definitions only — 3D volumes/raymarch/meshes) |

## For contributors

The integration story above is all most users need. Building/porting the engine is a separate
concern that **does** use the reference:

- **[ARCHITECTURE.md](ARCHITECTURE.md)** — how each reference subsystem maps to GDScript/Godot-GLSL.
- **[PORTING-GUIDE.md](PORTING-GUIDE.md)** — the WGSL → Godot-GLSL rulebook (read before porting a shader).
- **[docs/GRAPH-JSON-SCHEMA.md](docs/GRAPH-JSON-SCHEMA.md)** — the render-graph contract (compiler ↔ runtime).
- **[docs/CHAOS-GATE.md](docs/CHAOS-GATE.md)** — the documented cross-backend parity limit.
- **[parity/README.md](parity/README.md)** — the pixel harness + the six in-engine compiler gates.
- **`reference/01–10`** — engine-agnostic re-implementer specs, shared with the Unity/HLSL port.

The parity/dev tooling needs the reference engine (`NM_REFERENCE_ROOT=/path/to/noisemaker`). Quick
contributor loop (renders a Godot candidate and compares to the reference golden):

```bash
node tools/convert-definitions.mjs   # (once) regenerate effect JSON — already shipped
node tools/export-graph.mjs --file parity/programs/noise.dsl parity/out/noise.graph.json
NM_REFERENCE_ROOT=/path/to/noisemaker GODOT=/path/to/Godot bash parity/run.sh noise
#   -> [PASS] noise: max-abs-diff=1.000 ... ssim=0.99996
```

Verify the in-engine compiler against the reference (these gates run `--headless`; only the oracle
needs `NM_REFERENCE_ROOT`):

```bash
NM_REFERENCE_ROOT=/path/to/noisemaker GODOT=/path/to/Godot node parity/check_graph.mjs
#   -> GRAPH PARITY: 158/158 pass
```

### Layout

```
noisemaker-godot/
├─ README.md                        ← you are here (project overview + integrator quickstart)
├─ ARCHITECTURE.md / PORTING-GUIDE.md   ← contributor design + shader-port rulebook
├─ docs/      ← GRAPH-JSON-SCHEMA, CHAOS-GATE, IMPLEMENTATION-PLAN
├─ reference/ ← engine-agnostic specs (01–10), shared with the Unity port
├─ tools/     ← Node parity/dev tooling: export-graph (golden), convert-definitions
├─ parity/    ← golden-image harness + compiler gates + compare.py + programs (see parity/README.md)
└─ godot/addons/noisemaker/         ← the self-contained addon (copy this into res://addons/)
   ├─ README.md   ← integration docs (Requirements / Install / Host API / Troubleshooting)
   ├─ compiler/   ← in-engine DSL→graph compiler (lang/ + graph/)
   ├─ runtime/    ← RenderingDevice render-graph executor (nm_backend.gd)
   ├─ shaders/    ← nm_core include + per-effect GLSL ports
   ├─ effects/    ← effect-definition JSON consumed by the compiler/runtime
   └─ tools/      ← render_graph.gd (offline renderer) + present.gd (DSL+canvas demo)
```

## License

Released under the MIT License (see [LICENSE](LICENSE)). Use of the Noisemaker and Noise Factor
names in derivative products is subject to the [Trademark Policy](TRADEMARK.md).

Copyright © 2026 Noise Factor LLC
