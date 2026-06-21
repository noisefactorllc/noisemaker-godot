# Noisemaker → Godot Port — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A structural port of the Noisemaker shader engine (the Noisemaker reference engine) to **Godot 4.7**, mirroring the existing Unity/HLSL port: live procedural texture from the Polymorphic DSL, rendered through Godot's low-level `RenderingDevice` GPGPU pipeline, **tolerance-parity** to the JS/WebGL2 reference.

**Architecture:** The seam is the **Render Graph JSON** (`compileGraph(dsl) → {passes, programs, textures, renderSurface}`). Two producers: (a) golden/offline — the *unchanged* reference JS via reused Node `tools/export-graph.mjs`; (b) live/in-engine — a staged GDScript DSL frontend. Both feed one GDScript executor over `RenderingDevice` (rgba16f/32f targets, MRT, points scatter, ping-pong) + per-effect Vulkan-GLSL shader ports derived from the canonical WGSL, cross-checked against the existing HLSL ports.

**Tech Stack:** Godot 4.7 (standard build, installed at `/Applications/Godot.app/Contents/MacOS/Godot`), GDScript, Godot RenderingDevice GLSL (`#version 450`, `#[compute]`/`#[vertex]`/`#[fragment]` stage hints), Node 26 (reused reference tooling, no new deps), Python 3 + numpy/pillow (reused `compare.py`).

**Key constraints (proven during research):**
- `RenderingDevice` is **null under `--headless`** → all GPU work + the parity harness run Godot **non-headless with an offscreen window** (`--position 5000,5000`), the analog of Unity batchmode. Verified working on this M4.
- RenderingDevice GLSL is **top-left origin / Vulkan Y-down clip** = same as WGSL/D3D → **port from WGSL, no per-effect Y-flip**, no readback flip (`texture_get_data` is top-down).
- `*_SFLOAT`/`*_UNORM` formats store bits **as-is, linear, no implicit sRGB**. Use `DATA_FORMAT_R16G16B16A16_SFLOAT` (rgba16f) / `R32G32B32A32_SFLOAT` (rgba32f).
- Cross-device bit-exactness is impossible (MoltenVK/Metal vs WebGL2) → target **SSIM ≥ 0.98, max-abs-diff ≤ 1–2/255**, same as the Unity port.
- GDScript `float` = IEEE double = JS Number → CPU-side constant-folding matches the reference's double folding natively.

**Reused engine-agnostic assets (copied/symlinked, NOT re-authored):** `reference/01–10` specs, `tools/export-graph.mjs`, `tools/convert-definitions.mjs`, `parity/compare.py`, `parity/programs/*.dsl`, `docs/GRAPH-JSON-SCHEMA.md`.

**Source-of-truth to translate from:** for each runtime module, the matching the HLSL port's `Runtime/*.cs` (C#) + the cited `reference/NN` spec. For each shader, the reference `shaders/effects/<ns>/<name>/wgsl/*.wgsl` cross-checked against the HLSL port's `Shaders/Effects/<ns>/*.hlsl`.

---

## File Structure

```
noisemaker-godot/
├─ README.md                      # project overview (mirror hlsl README)
├─ ARCHITECTURE.md                # the validated design (mirror hlsl ARCHITECTURE)
├─ PORTING-GUIDE.md               # WGSL → Godot-GLSL rulebook (mirror hlsl PORTING-GUIDE)
├─ docs/
│  ├─ IMPLEMENTATION-PLAN.md      # this file
│  └─ GRAPH-JSON-SCHEMA.md        # reused, Godot formats noted
├─ reference/                     # COPIED 01–10 specs (the shared brain)
├─ tools/                         # REUSED Node scripts (retargeted output dir)
│  ├─ export-graph.mjs            # symlink/copy of hlsl tool
│  ├─ convert-definitions.mjs     # copy, output → godot/addons/noisemaker/effects
│  └─ package.json
├─ parity/
│  ├─ compare.py                  # COPIED verbatim
│  ├─ programs/*.dsl              # COPIED (8 Tier-1)
│  ├─ render-candidate.gd         # NEW: Godot offscreen renderer → candidate.png
│  ├─ run.sh                      # NEW: golden(node) → candidate(godot) → compare(py)
│  └─ out/                        # generated artifacts (gitignored)
└─ godot/                         # the Godot project (open this in the editor)
   ├─ project.godot
   └─ addons/noisemaker/
      ├─ plugin.cfg
      ├─ runtime/                 # GDScript executor over RenderingDevice
      │  ├─ render_graph.gd       # graph model (Pass/Program/TextureSpec/RenderGraph)
      │  ├─ graph_loader.gd       # JSON → RenderGraph (port of GraphLoader.cs)
      │  ├─ dim.gd                # Dim resolution (reference/04 §9 rounding)
      │  ├─ texture_pool.gd       # liveness pool (port of TexturePool.cs)
      │  ├─ surface_manager.gd    # double-buffered o0..o7 + state surfaces
      │  ├─ rd_backend.gd         # RenderingDevice pass executor (render/MRT/points/repeat/blend)
      │  ├─ uniform_binder.gd     # per-frame uniform UBO packing
      │  ├─ pipeline.gd           # frame loop (skip/repeat/present, 0..1 time)
      │  └─ nm_renderer.gd        # host node (Node2D) — Output as Texture2DRD
      ├─ compiler/                # STAGED GDScript DSL frontend (Phase 6)
      ├─ shaders/
      │  ├─ include/
      │  │  ├─ nm_core.glsl       # PCG/prng/random/nm_mod/map/periodicFunction
      │  │  └─ nm_fullscreen.glsl # fullscreen-triangle VS + engine-uniform unpack + coord helpers
      │  ├─ nm_blit.glsl          # present/copy pass
      │  └─ effects/<ns>/<Effect>.glsl   # per-effect fragment ports
      └─ effects/<ns>/<func>.json # effect-definition JSON (generated by convert-definitions)
```

---

## Phase 0 — Scaffold & reuse wiring

### Task 0.1: Create project skeleton + copy agnostic assets
**Files:** create the tree above (empty dirs + copied assets).
- [ ] Copy the HLSL port's `reference/` → `reference/` (verbatim; engine-agnostic brain).
- [ ] Copy `tools/{export-graph.mjs,convert-definitions.mjs,package.json}`; edit `convert-definitions.mjs` output root → `godot/addons/noisemaker/effects`. Edit nothing in `export-graph.mjs` (it's reference-driven).
- [ ] Copy `parity/{compare.py,programs/*.dsl}` verbatim.
- [ ] Copy `docs/GRAPH-JSON-SCHEMA.md`; append a "Godot formats" note (`rgba16f`→`R16G16B16A16_SFLOAT`, `rgba32f`→`R32G32B32A32_SFLOAT`, `rgba8`→`R8G8B8A8_UNORM`, all linear).
- [ ] Write `godot/project.godot` (name `noisemaker-godot`, `forward_plus`, autoload none) and `godot/addons/noisemaker/plugin.cfg`.
- [ ] Write `.gitignore` (`.godot/`, `parity/out/`, `node_modules/`).
- [ ] **Verify:** `Godot --path godot --headless --quit` imports the project clean (exit 0).
- [ ] **Commit** `scaffold: project tree + reused agnostic assets` (omit Co-Authored-By per project convention).

### Task 0.2: Verify the reused Node tooling runs against the reference
- [ ] Run `NM_REFERENCE_ROOT=/path/to/noisemaker node tools/export-graph.mjs parity/programs/solid.dsl parity/out/solid.graph.json` from `noisemaker-godot/`.
- [ ] **Verify:** `solid.graph.json` exists and matches `docs/GRAPH-JSON-SCHEMA.md` (one effect pass + blit, `renderSurface:"o0"`, a `global_o0` texture spec).
- [ ] Run `node tools/convert-definitions.mjs` → populates `godot/addons/noisemaker/effects/<ns>/*.json`. Spot-check `synth/solid.json` and `synth/noise.json` against their `definition.js`.
- [ ] **Commit** `tools: verify golden graph + effect-definition JSON generation`.

---

## Phase 1 — Golden assets (the "failing test")

### Task 1.1: Produce golden graph JSON + golden PNG for all 8 Tier-1 programs
**Files:** `parity/out/<name>.graph.json`, `parity/out/<name>.golden.png`.
- [ ] For each `parity/programs/*.dsl`, run `node parity/export-and-render.mjs <prog> parity/out --size 256 --time 0.25 --backend webgl2` (copy `export-and-render.mjs` from hlsl; it reuses the vendored shade-mcp Playwright harness in `$NM_REFERENCE_ROOT/vendor`). If Playwright/Chrome is unavailable, fall back to exporting graph JSON only and source golden PNGs from the hlsl port's existing `parity/out` if present.
- [ ] **Verify:** 8 `*.golden.png` (256×256) + 8 `*.graph.json` exist. These are the ground truth; the Godot candidate must match them.
- [ ] **Commit** `parity: golden graph JSON + golden PNGs for Tier-1`.

---

## Phase 2 — Shared GLSL includes + the simplest end-to-end pass

### Task 2.1: Author `nm_core.glsl` (bit-exact shared primitives)
**Files:** create `godot/addons/noisemaker/shaders/include/nm_core.glsl`.
Translate from the HLSL port's `Shaders/Include/NMCore.hlsl` (HLSL→GLSL: `asuint`→`floatBitsToUint`, `(uint3)v`→`uvec3(v)`, `float3`→`vec3`). Contents: `pcg(uvec3)`, `prng(vec3)`, `random(vec2)`, `nm_mod(float,float)`, `nm_positiveModulo(int,int)`, `map(...)`, `periodicFunction(float)`. PCG divisor literal `4294967295.0`.
- [ ] **Verify (unit, GPU):** write a throwaway compute shader that runs `pcg(uvec3(1u,2u,3u))` and `prng(vec3(0.5,0.25,0.0))`, read back, and compare to values printed from the reference JS `pcg`/`prng` for the same inputs. Must match bit-for-bit (integers) / within 1 ULP (float).
- [ ] **Commit** `shaders: nm_core.glsl shared primitives + GPU parity check`.

### Task 2.2: Author `nm_fullscreen.glsl` (VS + engine uniforms + coord helpers)
**Files:** create `godot/addons/noisemaker/shaders/include/nm_fullscreen.glsl`.
- [ ] Fullscreen-triangle vertex stage from `gl_VertexIndex` (3 verts, top-left UV). Engine uniform UBO `layout(set=0,binding=0,std140) uniform Engine { vec4 data[...]; }` matching the reference packing (`resolution`,`time`,`aspectRatio`,`tileOffset`,`fullResolution`,`renderScale`). `NM_FragCoord` (top-left, +0.5). `st = (NM_GlobalCoord + tileOffset) / fullResolution.y` (divide by **height**).
- [ ] **Verify:** compiles via `rd.shader_compile_spirv_from_source` with no error (checked in the harness bring-up below).

### Task 2.3: Bring up the minimal executor end-to-end on `solid`
**Files:** create `godot/addons/noisemaker/runtime/{render_graph.gd,graph_loader.gd,dim.gd,rd_backend.gd,uniform_binder.gd}` (minimal forms), `shaders/effects/synth/solid.glsl`, `parity/render-candidate.gd`.
This is the highest-risk integration — do it with the simplest effect. Translate `solid.wgsl` (premultiplied `vec4(color*alpha, alpha)`).
- [ ] `render-candidate.gd` (a `SceneTree` script): `create_local_rendering_device()` → load `solid.graph.json` → resolve one effect pass into an `R16G16B16A16_SFLOAT` framebuffer (256×256) → run blit/present → `texture_get_data` → `Image.save_png(candidate.png)` → `quit()`.
- [ ] **Verify (parity gate):** `Godot --path godot parity/render-candidate.gd --position 5000,5000 ... ` produces `solid.candidate.png`; then `python parity/compare.py parity/out/solid.golden.png parity/out/solid.candidate.png --name synth/solid --tolerance 2 --ssim-min 0.98` exits 0. Solid is a flat `#3399E6`-ish fill → must be near-exact.
- [ ] **Commit** `runtime: minimal RenderingDevice executor — solid renders pixel-parity`.

---

## Phase 3 — Full runtime executor

Translate each module from its `Runtime/*.cs` counterpart + cited spec. Each task: port → bring up via an existing or new Tier-1 graph → confirm no regression on `solid`, then on the effect that exercises the feature.

### Task 3.1: `dim.gd` — dimension resolution
- [ ] Port `Graph/Dim.cs` + `reference/04 §9`: number / `"screen"` / `"auto"` / percent / `{param}` / `{screenDivide}` / `{scale}`. **floor** for param/percent/scale, **round** for screenDivide, always `max(1,·)`.
- [ ] **Verify:** unit asserts for each Dim variant against reference values. **Commit.**

### Task 3.2: `texture_pool.gd` — liveness allocator
- [ ] Port `Graph/TexturePool.cs` + `reference/04 §1`: insertion-ordered linear-scan; `phys_N` numbering matches reference. **Verify** the `blur.graph.json` allocations map 1:1 to reference `allocations`. **Commit.**

### Task 3.3: `surface_manager.gd` — double-buffered surfaces
- [ ] Port `Pipeline/SurfaceManager.cs` + `reference/04 §10`: `o0..o7`/state surfaces as RT pairs, the 3-tier swap/persist predicate, `isStateSurface` (case-sensitive substring tests). All RTs `R16G16B16A16_SFLOAT` linear. **Verify** via a feedback program later; for now unit-test the predicate + swap order. **Commit.**

### Task 3.4: `rd_backend.gd` — full pass executor
- [ ] Extend Task 2.3's backend to cover: MRT (multi-attachment framebuffer, `drawBuffers`), `drawMode:"points"` (`RENDER_PRIMITIVE_POINTS`, `count`/`countUniform`), `blend:true` (additive one-one pipeline color-blend state), `repeat` (run pass N times with ping-pong). Cache pipelines by (shader, fb-format, blend, primitive).
- [ ] **Verify:** unit-level — a 2-attachment MRT test writes two known colors, both read back correct (extends the Phase-(-1) feasibility probe). **Commit.**

### Task 3.5: `uniform_binder.gd` + `pipeline.gd` + `nm_renderer.gd`
- [ ] `uniform_binder.gd`: pack per-pass uniforms into a std140 UBO matching each effect's `uniformLayout` (vec4 slots); engine globals into the Engine UBO. Booleans as `1.0/0.0` tested `>0.5`; ints as truncated floats. Compile-time defines (`NOISE_TYPE`,`LOOP_OFFSET`) injected as GLSL `#define` before SPIR-V compile (recompile-on-change, cached).
- [ ] `pipeline.gd`: port `Pipeline/NMPipeline.cs` frame loop — execute passes in order, skip/repeat/present, normalized 0..1 time, 8 settle frames for state.
- [ ] `nm_renderer.gd`: host `Node2D`; `Output` exposed as a `Texture2DRD` for on-screen/material display; `set_uniform`/`resize` host API.
- [ ] **Verify:** `solid` still parity-passes through the full pipeline. **Commit** `runtime: full executor (MRT/points/blend/repeat + frame loop)`.

---

## Phase 4 — Tier-1 effect ports → verify parity

Per-effect procedure (the templated unit; see PORTING-GUIDE.md): for `<ns>/<effect>`:
1. Read `$NM_REFERENCE_ROOT/shaders/effects/<ns>/<effect>/wgsl/<prog>.wgsl` (canonical) and the matching HLSL port's `Shaders/Effects/<ns>/<Effect>.hlsl` (cross-check).
2. Write `godot/addons/noisemaker/shaders/effects/<ns>/<Effect>.glsl`: `#[fragment] #version 450`, `#include` nm_core/nm_fullscreen, port the body verbatim (helpers per-effect, no arithmetic simplification, full f32). Apply the WGSL→GLSL table from PORTING-GUIDE (`select(b,a,c)`→`c?a:b`, `bitcast<u32>`→`floatBitsToUint`, `vecN<f32>`→`vecN`, etc.).
3. The effect-definition JSON already exists (Phase 0.2).
4. **Parity gate:** `parity/run.sh <ns>/<effect>` → compare candidate vs golden via `compare.py`. Must pass tolerance before moving on.

- [ ] Task 4.1: `synth/noise` (the big one — PCG value/simplex/sine machinery; `NOISE_TYPE`/`LOOP_OFFSET` defines). Parity-gate against `noise.golden.png`.
- [ ] Task 4.2: `synth/cell` (note HLSL reserved-word `point` lesson — avoid in GLSL too where relevant). Gate vs `cell.golden.png`.
- [ ] Task 4.3: `synth/gradient` (directional — also the Y-orientation sanity check). Gate vs `gradient.golden.png`.
- [ ] Task 4.4: `synth/shape` (SDF). Gate vs `shape.golden.png`.
- [ ] Task 4.5: `synth/osc2d` (oscillator). Gate vs `osc2d.golden.png`.
- [ ] Task 4.6: `filter/blur` (multi-pass separable H/V — exercises pooled intermediates + filter input sampling). Gate vs `blur.golden.png`.
- [ ] Task 4.7: `mixer/blendMode` (two-surface o0→o1 — exercises multi-input + the depth-parity Y reconciliation the Unity port hit). Gate vs `blendMode.golden.png`.
- [ ] **Verify (milestone):** all **8/8 Tier-1 parity-pass** (`parity/run.sh` loops green). This is the approved milestone. **Commit** per effect.

---

## Phase 5 — Expand coverage (templated)

Apply the Phase-4 per-effect procedure across namespaces, parity-gating each. Parallelizable across independent effects. Order by leverage/risk:
- [ ] 5.1 Remaining `synth` generators (deterministic, single-pass — highest parity yield).
- [ ] 5.2 `filter` (90) — bulk of the library; many single-pass.
- [ ] 5.3 `mixer` (14) — two-input.
- [ ] 5.4 `classicNoisedeck` (20).
- [ ] 5.5 `points` (10 — agents: MRT state + points deposit + diffuse), `synth3d`/`filter3d`/`render` (3D volume atlas + raymarch, OBJ meshes) — hardest; stage last, loosen tolerance for chaotic sims.
- [ ] Track coverage in README (namespace N/total), mirroring the hlsl README. **Log** any effect skipped/over-tolerance — never silently.

---

## Phase 6 — Live GDScript DSL compiler (staged)

Only after the golden-JSON runtime is proven. Port `reference/01–03` to GDScript under `compiler/` (lexer→parser→validator→expander→resources), emitting the same normalized graph JSON. Validate by diffing its JSON against the golden `export-graph.mjs` output for `parity/programs/*` + the hlsl `parity/corpus/*` (byte-identical modulo `compiledAt`). Constant-fold in GDScript `float` (double) — matches the JS reference natively.
- [ ] 6.1 lexer + parser → AST (port `reference/01`). Diff AST shape on corpus.
- [ ] 6.2 validator (port `reference/02`; temp-index allocation order is parity-critical).
- [ ] 6.3 expander + resources (port `reference/03`,`04`). Diff normalized JSON vs golden.
- [ ] 6.4 wire into `nm_renderer.gd` so `set_dsl(src)` compiles live in-engine.

---

## Self-Review notes
- **Spec coverage:** runtime (ref 04) → Phase 3; shader translation (ref 07/08) → Phases 2/4/5; golden seam (ref 03/04 + tools) → Phases 0/1; live compiler (ref 01–03) → Phase 6; parity harness → Phases 1–4. Covered.
- **Test-first:** golden assets (Phase 1) precede any candidate render; every effect has a parity gate before it's "done."
- **Riskiest-first:** the RD integration is brought up on `solid` (Task 2.3) before any complex effect; MRT/points/blend each get a feature-exercising gate.
- **Naming consistency:** module/file names fixed in File Structure; GDScript snake_case files, `RenderGraph`/`Pass`/`TextureSpec` class names mirror the C# model.
```
