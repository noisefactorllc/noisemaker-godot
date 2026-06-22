# noisemaker-godot — Architecture

A parallel port of the Noisemaker shader engine to Godot 4.7 / `RenderingDevice` GLSL.
Goal: **live procedural texture from the Polymorphic DSL, pixel-identical to the JS
reference engine.** ProgramState and UI bindings are out of scope. It mirrors the
Unity/HLSL Noisemaker port structurally and reuses its engine-agnostic assets.

## The seam: the Render Graph

The JS engine compiles DSL in stages: `lex → parse → validate → expand →
allocateResources → Pipeline`. The clean architectural seam is the **Render Graph** —
the normalized graph JSON produced by `compileGraph(dsl)` (`reference/03`, `reference/04`,
`docs/GRAPH-JSON-SCHEMA.md`):

```
graph = { passes[], programs{}, textures{}, allocations{}, renderSurface, ... }
```

Everything downstream of the graph (texture pooling, double-buffering, pass execution,
presentation) is backend work; everything upstream is pure data logic. noisemaker-godot
gives the graph **two producers**:

- **(a) Live / in-engine (production)** — the GDScript compiler under
  `addons/noisemaker/compiler/` (`lang/`: lexer→parser→validator→effect-registry; `graph/`:
  expander→orchestrator). `Orchestrator.new(EffectRegistry.new()).build_graph(source)` emits the
  normalized graph with no reference/Node/network. Gated stage-by-stage against the reference
  (`parity/check_*.mjs`, **158/158**) and byte-identical to (b) — rendering either graph yields the
  same PNG.
- **(b) Golden / offline (parity only)** — `tools/export-graph.mjs` runs the *unchanged reference*
  `compileGraph` and serialises the graph to JSON. Used only to verify (a); it imports the reference
  engine from `NM_REFERENCE_ROOT` (a checkout of the Noisemaker reference repo) — no sibling assumed.

Both feed the same `nm_backend.gd` executor and the same Godot-GLSL shaders.

## Runtime — `addons/noisemaker/runtime/nm_backend.gd`

A `RenderingDevice`-based executor. **All reference effects are render-pass based**
(`reference/10`: no `type:compute` in any definition; agents/GPGPU use MRT + points
scatter + repeat loops), so we mirror the **WebGL2 GPGPU model** with fullscreen fragment
draws rather than compute dispatches.

| Reference | noisemaker-godot |
|---|---|
| `resources.js` liveness + linear-scan pool | `compiler/graph/resources.gd` (`allocate_resources`, runs inside `Orchestrator.build_graph`) + `compiler/graph/dim.gd`. Surfaces are then allocated per-texId in `nm_backend.gd::allocate_textures`. (No `texture_pool.gd`.) |
| `pipeline.js` surfaces (`o0..o7`, geo, vol) | `nm_backend.gd` allocates `global_*` surfaces as `RDTexture`s, with **ping-pong double-buffering** for state/feedback surfaces (`_pingpong`). |
| `backend.executePass` (render/MRT/points/repeat/blend) | `nm_backend.gd` — `RenderingDevice` draw lists: render, **MRT** (N-attachment), **points/billboards** (`RENDER_PRIMITIVE_POINTS`, `ONE,ONE` additive), **repeat** loops, **feedback** — all implemented. |
| fullscreen triangle VS + default present blit | `FULLSCREEN_VS` (vertex-buffer triangle) + `BLIT_FS` constants in `nm_backend.gd`. |
| per-frame uniform flow | packed `vec4 data[N]` UBO per pass (see "Uniform model"). |
| `Pipeline.render(time)` control flow | `nm_backend.gd::render(graph, normalized_time := 0.25)` — passes in order; stateful sims via `render_samples(graph, total_frames, sample_every)`. |
| host API (`getOutput`, resize) | scripting-only: `Backend.setup` / `render` / `render_samples` / `save_surface_png` + `tools/render_graph.gd` / `present.gd`. A drop-in editor `NMRenderer` node is not yet shipped. |

## Shaders — `addons/noisemaker/shaders/`

- `include/nm_core.glsl` — bit-exact shared primitives (`pcg`/`prng`/`random`/`map`/
  `periodicFunction`/`positiveModulo`, `PI`/`TAU`). Nothing per-effect-variable.
- `effects/<ns>/<prog>.glsl` — per-effect fragment ports (see PORTING-GUIDE). Shaders are
  keyed by **progName** (an effect may have several programs, e.g. `blur → blurH/blurV`).
- The fullscreen vertex stage and the present blit are built into `nm_backend.gd`.

Shaders are authored as fragment-only GLSL; the backend resolves `#include`s textually
(glslang from-source compilation does not run the resource importer), prepends the shared
vertex stage, and compiles via `rd.shader_compile_spirv_from_source`.

## Uniform model — one packed `vec4 data[N]` UBO per pass (set 0, binding 0)

Godot/Vulkan has no loose named uniforms, so every pass binds a single packed UBO.

- **Effects WITH a reference `uniformLayout`** (noise/cell/gradient/shape): the shader
  declares `Params { vec4 data[N]; }` and reads `data[i].comp` **verbatim from the WGSL**.
  The backend packs engine globals + params into the slots that layout names.
- **Effects WITHOUT one** (solid/osc2d/blur/blendMode and most filters): the backend
  **synthesizes** a layout — a fixed engine header in slots 0–2 (`resolution`, `time`,
  `aspectRatio`, `tileOffset`, `fullResolution`, `renderScale`) then each `uniform` global
  from slot 3 — and **injects** the `Params` UBO declaration plus a `#define <name>
  data[slot].comp` for every name after `#version`. The shader then uses **bare reference
  names** and ports near-verbatim from the GLSL. Same packer either way.

Compile-time defines (`NOISE_TYPE`, `LOOP_OFFSET`) are injected as integer `#define`s and
the shader is cached per (program, define-set). Input textures bind as combined
`sampler2D` at set 0, binding 1.. in `pass.inputs` order.

## Coordinates & color (parity)

- `RenderingDevice` is **top-left origin, Vulkan Y-down clip**, same as WGSL — so shaders
  port from WGSL with **no per-effect Y-flip**, and `texture_get_data` rows are top-down.
- A **single global Y-flip at present** (`nm_backend.gd::save_surface_png`) reconciles our
  uniformly-top-left pipeline to the webgl2/GLSL golden (which is bottom-left flipped to a
  top-down PNG). Because RenderingDevice keeps orientation consistent across passes
  (unlike Unity's per-render flip), this is depth-independent — the two-surface mixer
  `blendMode` needs no special handling.
- Render targets are `R16G16B16A16_SFLOAT` (rgba16f), **linear, never sRGB**. The PNG is
  quantized `round(v*255)` in GDScript (Godot's half-float `save_png` clobbers alpha, and
  we want the reference's exact quantization).

## Validation — `parity/`

- `parity/run.sh <name>` — renders the Godot candidate (`tools/render_graph.gd`,
  non-headless offscreen) and compares to the golden via `compare.py`.
- Golden images are produced by the reference GPU (webgl2, headless Chromium) via
  `parity/export-and-render.mjs` (reused from the Unity port; needs Playwright + Chrome).
- `parity/compare.py` — max-abs-diff + SSIM with per-program tolerance (reused verbatim).

**Status (2026-06-21, Apple M4/Metal):** the in-engine compiler passes all six gates
(`parity/check_{lex,parse,validate,expand,graph,registry}.mjs`) at **158/158**; the 2D + agent
catalog passes `parity/sweep.sh` (last recorded **93/93, 2 chaos-gated skips**), most within 1/255
(SSIM ≈ 1.0). The harness is how each further port gets verified — see `parity/README.md`.

## Still staged

3D volumes + raymarch + meshes (`synth3d`/`filter3d` ship definitions but **no shaders**);
same-pass read+write ping-pong for `cellularAutomata`; a drop-in editor `NMRenderer` node;
oscillator/MIDI/audio automation; tiled hi-res export. The graph model carries the fields so these
slot in without reshaping the executor. *(Done since the first cut: the live GDScript compiler, the
liveness pool, ping-pong double-buffering, and MRT/points/repeat/blend passes.)*
