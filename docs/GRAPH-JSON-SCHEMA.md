# Render Graph JSON Schema (the GDScript runtime ↔ producer contract)

This is the **normalized** graph format that both producers emit and the `nm_backend.gd`
RenderingDevice executor consumes. It is the reference `compileGraph` output (`reference/03`,
`reference/04`) with Maps serialized as objects and a few convenience fields added so the runtime
never has to re-derive them from program-id string encodings.

In-engine, this is the value returned by `Orchestrator.new(EffectRegistry.new()).build_graph(source)`
(a GDScript `Dictionary`); the offline exporter writes the same shape as JSON.

```jsonc
{
  "id": "abc123",                  // hashSource(dsl)
  "source": "search synth\nnoise().write(o0)\nrender(o0)",
  "renderSurface": "o0",           // surface presented to screen / output (or null)

  "passes": [ /* Pass[] in execution order */ ],

  // allocations: virtual pooled texId -> physical slot id. global_ surfaces are NOT here.
  "allocations": { "node_0_out": "phys_0" },

  // textures: texId -> TextureSpec. Holds pooled + effect-declared textures (incl. chain-scoped
  // global_<name>_chain_N state textures). NOTE: user surfaces global_o0..o7 are double-buffered
  // and intentionally have NO entry here — the backend creates them on demand.
  "textures": {
    "node_0_out":              { "width": "screen", "height": "screen", "format": "rgba16f",
                                 "usage": ["render","sample","copySrc","copyDst"] },
    "global_ca_state_chain_0": { "width": { "screenDivide": "stateSize" }, "height": { "screenDivide": "stateSize" },
                                 "format": "rgba16f", "usage": ["render","sample","copySrc","copyDst"] }
  },

  // programs: program-id -> { uniformLayout, defines }. The backend does NOT read shader source
  // from here — it resolves the GLSL file by (namespace, func, progName). Kept for traceability /
  // golden diff. For the in-engine compiler this is usually just { "blit": {...} } (shaders live in
  // files, not inline).
  "programs": { "blit": { "uniformLayout": {}, "defines": {} } }
}
```

## Pass (normalized)

```jsonc
{
  "id": "node_0_pass_0",
  "passType": "effect",            // "effect" | "blit"

  // --- shader resolution ---
  "namespace": "synth",            // = pass.effectNamespace (null for blit)
  "func": "noise",                 // = pass.effectFunc ("blit" for blit)
  "progName": "noise",             // bare program basename
  "program": "node_0_noise",       // internal program id (node-prefixed, define-suffixed; "blit" for blit)
  // -> the backend loads shaders/effects/<namespace>/<func>/<progName>.glsl
  "defines": { "NOISE_TYPE": 10, "LOOP_OFFSET": 300 },  // compile-time int consts, baked into the shader

  // --- pass wiring (from reference Pass) ---
  "inputs":  { "inputTex": "node_0_out" },   // samplerName -> texId | "none"
  "outputs": { "fragColor": "global_o0" },   // attachment -> texId. Keys are the shader's fragment
                                             // OUT-variable names (color / fragColor / outRGBA / outVel
                                             // / outXYZ …), one per MRT attachment.
  "uniforms":     { "scaleX": 75, "seed": 1 },     // name -> literal value
  "uniformSpecs": { "scaleX": { "min": 1, "max": 100 } },

  // --- optional execution modifiers (present only when set) ---
  "drawMode": "points",            // scatter pass -> RENDER_PRIMITIVE_POINTS
  "count": 4096,                   // or
  "countUniform": "stateSize",     // dynamic count from a uniform (count = value*value for points)
  "drawBuffers": 2,                // MRT attachment count
  "blend": true,                   // additive deposit -> RDPipelineColorBlendStateAttachment ONE,ONE
  "repeat": "iterations",          // int or uniform-name: run pass N times/frame
  "clear": null,

  // --- metadata ---
  "effectKey": "synth.noise",      // namespace-qualified op key (null for blit)
  "nodeId": "node_0",
  "stepIndex": 0,
  "inheritsVolumeSize": false,
  "scopedParams": null             // { origParam: scopedParam } when present
}
```

Blit passes use `"passType":"blit"`, `"func":"blit"`, `"program":"blit"`, `"namespace":null`,
`"effectKey":null`, `inputs:{src:...}`, `outputs:{color:...}`, empty uniforms.

## TextureSpec & dimensions (`reference/04 §9`)

```jsonc
{ "width": <Dim>, "height": <Dim>, "depth"?: <Dim>, "is3D"?: bool,
  "format"?: "rgba16f", "usage": ["render","sample","copySrc","copyDst"] }
```
`usage` is always present (`["storage","sample","copySrc","copyDst"]` for `is3D` specs). `Dim` is one
of: a number; `"screen"`/`"auto"`; a percent string `"6.25%"`; or an object
`{param, paramDefault?, multiply?, power?, default?}` | `{screenDivide, default?}` | `{scale, clamp?}`.
Resolve with the exact rounding rules in `reference/04 §9` (`floor` for param/percent/scale, `round`
for screenDivide, always `max(1, …)`).

## texId conventions

- `global_<name>` — a global surface. User surfaces `o0..o7` (and `geo*`/`vol*`) are double-buffered
  (a `RDTexture` read/write pair, swapped within and across frames) and excluded from `textures{}`.
  Chain-scoped state textures (`global_<name>_chain_N`) DO carry a `TextureSpec`.
- `phys_N` — a pooled physical slot (from the `compiler/graph/resources.gd` liveness allocator).
- everything else (e.g. `node_0_out`) — a virtual pooled texId mapped via `allocations` to a `phys_N`.

## Formats (Godot `RenderingDevice`)

`rgba16f`/`rgba16float` → `DATA_FORMAT_R16G16B16A16_SFLOAT`. `rgba32f` →
`DATA_FORMAT_R32G32B32A32_SFLOAT`. `rgba8`/`rgba8unorm` → `DATA_FORMAT_R8G8B8A8_UNORM`. All targets are
**linear, never sRGB**; readback is quantized `round(v*255)` to 8-bit (see ARCHITECTURE "Coordinates & color").

## Producers

- **Live (production):** the GDScript `Orchestrator` (`compiler/graph/orchestrator.gd`) emits this
  shape via `_normalize_graph()` after running lex→parse→validate→expand→allocate_resources in-engine.
- **Golden (parity only):** `tools/export-graph.mjs` runs the unchanged reference `compileGraph`, then
  the same `normalizeGraph` (Maps→objects, adds `passType/namespace/func/progName/program/defines`).

Both produce byte-identical normalized JSON for the same DSL (modulo `compiledAt`), which is the
in-engine compiler's parity test — `parity/check_graph.mjs` (158/158).
