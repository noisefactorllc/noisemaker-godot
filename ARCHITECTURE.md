# noisemaker-godot — Architecture

A parallel port of the Noisemaker shader engine (`../noisemaker/shaders`) to Godot 4.7 /
`RenderingDevice` GLSL. Goal: **live procedural texture from the Polymorphic DSL,
pixel-identical to the JS reference engine.** ProgramState and UI bindings are out of
scope. It mirrors the Unity port (`../noisemaker-hlsl`) structurally and reuses its
engine-agnostic assets.

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

- **(a) Golden / offline** — `tools/export-graph.mjs` runs the *unchanged reference*
  `compileGraph` and serialises the graph to JSON. Zero parity risk (it is the reference
  code). Reused verbatim from the Unity port (it only needs the sibling `../noisemaker`).
- **(b) Live / in-engine** *(staged)* — a GDScript port of the DSL frontend under
  `addons/noisemaker/compiler/`, validated by diffing its JSON against (a).

Both feed the same `nm_backend.gd` executor and the same Godot-GLSL shaders.

## Runtime — `addons/noisemaker/runtime/nm_backend.gd`

A `RenderingDevice`-based executor. **All reference effects are render-pass based**
(`reference/10`: no `type:compute` in any definition; agents/GPGPU use MRT + points
scatter + repeat loops), so we mirror the **WebGL2 GPGPU model** with fullscreen fragment
draws rather than compute dispatches.

| Reference | noisemaker-godot |
|---|---|
| `resources.js` liveness + linear-scan pool | *(staged — `dim.gd`/`texture_pool.gd`)*. Tier-1 allocates per-texId directly; `screen`/`auto` dims resolved, full Dim rules pending. |
| `pipeline.js` surfaces (`o0..o7`, geo, vol) | `nm_backend.gd` allocates `global_*` surfaces as `RDTexture`s; double-buffering staged (Tier-1 DAGs need none). |
| `backend.executePass` (render/MRT/points/repeat/blend) | `nm_backend.gd` — `RenderingDevice` draw lists. Render ✓; MRT/points/repeat/blend staged. |
| fullscreen triangle VS + default present blit | `FULLSCREEN_VS` (vertex-buffer triangle) + `BLIT_FS` constants in `nm_backend.gd`. |
| per-frame uniform flow | packed `vec4 data[N]` UBO per pass (see "Uniform model"). |
| `Pipeline.render(time)` control flow | `nm_backend.gd::render(graph, time)` — passes in order; normalized 0..1 time. |
| host API (`getOutput`, resize) | `tools/render_graph.gd` (offline); an editor `NMRenderer` node is staged. |

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

**Status:** 8/8 Tier-1 verified pixel-identical on Apple M4/Metal (max-abs-diff 1,
SSIM ≈ 1.0). The harness is how each further port gets verified.

## Out of scope for the first cut (staged)

Full Dim resolution + liveness texture pool; double-buffered state/feedback surfaces;
MRT / points-scatter / repeat-loop passes (agents); 3D volumes + raymarch + meshes; the
live GDScript DSL compiler; oscillator/MIDI/audio automation; tiled hi-res export. The
graph model carries the fields so these slot in without reshaping the executor.
