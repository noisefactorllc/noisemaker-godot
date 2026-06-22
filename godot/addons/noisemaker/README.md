# Noisemaker (Godot addon)

Live procedural textures from the Noisemaker **Polymorphic DSL**, compiled to a render graph and
executed on Godot's low-level `RenderingDevice` — aiming to be pixel-identical to the JS/WebGL2
reference engine. The addon is **self-contained**: it compiles the DSL **and** renders it with no
Node.js, no reference engine, and no network.

> **🚧 WIP — early development.** Verified on Apple Silicon (Metal) only; treat output as
> provisional. **Read "Requirements" before integrating — the defaults will not "just work"**
> (you need a real `RenderingDevice`, i.e. a window — see below).

> This README is for **integrators** (using the addon). Contributors porting shaders or engine code
> should read the repo's `ARCHITECTURE.md`, `PORTING-GUIDE.md`, and `parity/` — none of which you
> need to *use* the addon.

## Requirements

- **Godot 4.7**, renderer **Forward+** (the project sets `renderer/rendering_method="forward_plus"`).
- **A real `RenderingDevice`.** The executor renders through a local `RenderingDevice`, which is
  **`null` under `--headless`**. So: **rendering needs a window** — there is no dedicated-server /
  headless / CI rendering. For offscreen rendering, run with a window positioned off-screen
  (e.g. `--position 5000,5000`), the way the bundled `tools/render_graph.gd` does.
- **GPU:** Vulkan-class device with `rgba16f` / `rgba32f` render targets and compute. Render targets
  are **linear, non-sRGB**; output is quantized to 8-bit RGBA with no sRGB curve (matching the
  reference's `round(v*255)`), top-down (a single global Y-flip is already applied at readback).
- **Platform:** verified on **Apple Silicon / Metal** only. Other platforms/drivers are expected to
  work (it is pipeline-agnostic) but are **not yet verified**.
- **No external input.** The addon is output-only — there is no texture/camera/video/audio input
  (the `media`-style effects are definition-only stubs). The **3D** namespaces (`synth3d`,
  `filter3d`) ship effect definitions but **no shaders yet**, so 3D effects render nothing.

## Installation

1. Copy the `addons/noisemaker/` folder into your project's `res://addons/`.
2. *Project Settings ▸ Plugins ▸* enable **Noisemaker**.

Enabling the plugin currently registers **no editor nodes** — it exists so the addon is a
well-formed, enableable plugin. **Integration is scripting-only today**: you instantiate the
compiler + backend from your own GDScript (below). A drop-in `NMRenderer` node is not yet shipped.

## Getting started

The pieces: an `EffectRegistry` (loads the bundled effect definitions), the `Orchestrator` (compiles
a DSL string to a normalized render graph, fully in-engine), and the `Backend` (executes the graph on
a `RenderingDevice`).

```gdscript
const EffectRegistry := preload("res://addons/noisemaker/compiler/lang/effect_registry.gd")
const Orchestrator   := preload("res://addons/noisemaker/compiler/graph/orchestrator.gd")
const Backend        := preload("res://addons/noisemaker/runtime/nm_backend.gd")

func render_dsl_to_texture(dsl: String, size := 512) -> ImageTexture:
    # RenderingDevice is null under --headless → this must run with a window.
    var rd := RenderingServer.create_local_rendering_device()
    if rd == null:
        push_error("RenderingDevice unavailable (run non-headless, with a window)")
        return null

    var reg := EffectRegistry.new()
    reg.load_all()                                  # load the bundled effect definitions (once)
    var graph = Orchestrator.new(reg).build_graph(dsl)   # DSL → normalized render graph, in-engine

    var backend := Backend.new()
    backend.setup(rd, "res://addons/noisemaker", Vector2i(size, size))
    var img: Image = backend.render_samples(graph, 1, 1)[0]   # render one frame, return the Image
    return ImageTexture.create_from_image(img)
```

```gdscript
# Example: a static generator onto a TextureRect.
$TextureRect.texture = render_dsl_to_texture(
    "search synth\nnoise(scaleX: 60, scaleY: 60, seed: 1).write(o0)\nrender(o0)")
```

**Write a PNG** instead of getting a texture — render at an explicit normalized time and save:

```gdscript
backend.setup(rd, "res://addons/noisemaker", Vector2i(512, 512))
backend.render(graph, 0.25)                 # render normalized time 0..1 (default 0.25)
backend.save_surface_png("user://out.png")  # → true on success
```

**Stateful sims** (navierStokes, feedback, cellularAutomata, agent flows) evolve over many frames —
render a *sequence* and take the frame you want. `render_samples(graph, total_frames, sample_every)`
steps the sim at 60 fps and returns the frames where `frame % sample_every == 0`:

```gdscript
# 30 seconds of evolution (1800 frames), keep only the final frame:
var frames := backend.render_samples(graph, 1800, 1800)   # → Array[Image] of length 1
var final_img: Image = frames[0]
```

> A no-reference command-line path is also bundled: `tools/render_graph.gd --dsl <file.dsl> --out
> <file.png>` renders a `.dsl` to a PNG, and `tools/present.gd` composes the DSL beside the canvas.
> Both must run non-headless (`--position 5000,5000`).

## Host API

`EffectRegistry` (`compiler/lang/effect_registry.gd`):

| Member | Purpose |
|---|---|
| `load_all() -> void` | Load the bundled effect-definition JSON (`effects/**/*.json`). Call once. |
| `get_op(name) / get_effect(name)` | Lookup used by the compiler; you normally don't call these. |

`Orchestrator` (`compiler/graph/orchestrator.gd`), constructed with an `EffectRegistry`:

| Member | Purpose |
|---|---|
| `build_graph(source: String, options := {}) -> Dictionary` | Compile a DSL string to the normalized render graph (lex→parse→validate→expand→normalize), fully in-engine. |

`Backend` (`runtime/nm_backend.gd`):

| Member | Purpose |
|---|---|
| `setup(rd: RenderingDevice, addon_dir: String, screen: Vector2i) -> void` | Initialize against a RenderingDevice; `addon_dir` is `"res://addons/noisemaker"`; `screen` is the render resolution. |
| `render(graph: Dictionary, normalized_time := 0.25) -> void` | Render one frame at normalized time 0..1. Updates internal state; read the result via `save_surface_png`. |
| `render_samples(graph, total_frames: int, sample_every: int) -> Array[Image]` | Step `total_frames` at 60 fps; return an `Image` at each `frame % sample_every == 0`. The general way to get pixels (single frame: `render_samples(g, 1, 1)`). |
| `save_surface_png(path: String) -> bool` | Write the current render surface to a PNG (8-bit RGBA). |
| `render_surface_tex: String` | The surface presented (e.g. `"global_o1"`); set by the graph's `renderSurface`. |

The result is **8-bit RGBA, linear (no sRGB), top-down**. Convert with
`ImageTexture.create_from_image(img)` and use it on any material / `TextureRect`.

## Performance & cost

Performance is **not** optimized. Cost knobs, roughly in order:

- **Render resolution** (`setup(... Vector2i(w, h))`) dominates raymarch/fluid/feedback effects.
  Start low (256²) and scale up.
- **Particle / agent effects** (`points*`, `flow`) scale with `stateSize²` (capped at 2048 ⇒ up to
  ~4.2M agents). Keep `stateSize` modest.
- **Stateful sims** cost ~one full graph execution **per frame** — `render_samples(g, 1800, …)` for a
  30 s evolution runs the graph 1800 times. Render only as many frames as you need.
- Each `Backend` owns GPU resources sized by resolution, surface count, and `stateSize`.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `RD_NULL` / `null` from `create_local_rendering_device()` / blank | Running `--headless` (or no window) | Run with a window; for offscreen use `--position 5000,5000`. |
| Compile errors in the Output log, nothing renders | Invalid DSL (the compiler `push_error`s and bails) | Fix the DSL; every program needs a `search` directive and a `write(oN)` / `render(oN)`. |
| A stateful sim looks frozen / under-developed | Only one frame rendered | Use `render_samples(graph, N, …)` with enough frames (60 = 1 s). |
| A 3D effect (`synth3d`/`filter3d`) renders nothing | 3D shaders are staged (definitions only) | Not yet supported. |
| Chaotic agent flow / `target.dsl` differs from the reference | The documented chaos gate (~1-ULP `pow`) | Expected — see the repo's `docs/CHAOS-GATE.md`; it renders, just as a different chaos instance. |

## How it works

DSL → **in-engine compiler** (`Orchestrator.build_graph`: lexer → parser → validator →
effect-registry → expander → orchestrator/normalize, all under `compiler/`) → a normalized **Render
Graph** (`passes / programs / textures / renderSurface`) → `nm_backend.gd` executes the passes on
`RenderingDevice` (fullscreen blits, MRT, points/billboard deposit, ping-pong double-buffering,
repeat loops) into linear `rgba16f`/`rgba32f` surfaces, then presents the render surface. The compiler
is parity-verified 158/158 against the reference; see the repo's `ARCHITECTURE.md` and
`docs/GRAPH-JSON-SCHEMA.md`.

## License

MIT — see the repo `LICENSE`. Use of the Noisemaker / Noise Factor names is subject to the repo's
Trademark Policy.
