# noisemaker-godot

> Run **Noisemaker**'s procedural visuals inside **Godot 4**.

## What is this?

**Noisemaker** is a procedural visual engine. You write tiny text programs — chains of
effects — and it renders live, animated GPU textures:

```
search synth, filter
noise(scaleX: 60).bloom().write(o0)
render(o0)
```

That little language is Noisemaker's **DSL** (a domain-specific language for visuals). The original
engine runs in the browser at [noisedeck.app](https://noisedeck.app).

**noisemaker-godot** runs that same engine *inside Godot 4* — the same programs and the same ~180
effects, rendered on Godot's own GPU pipeline. Use it to make textures, materials, and animated
backgrounds from code, with no image files.

It is **self-contained**: the addon compiles the DSL and renders it entirely in Godot — no internet,
no Node.js, no separate engine to install.

## What you can do with it

- **Generate animated textures** from a short program — noise, gradients, patterns, color grades,
  blurs, warps.
- **Run simulations on the GPU** — particle/agent systems (flocking, slime/physarum, diffusion) and
  fluid (navier–stokes).
- **Use the result anywhere a texture goes** — materials, `TextureRect`, shaders, backgrounds.
- **Render a `.dsl` file straight to a PNG** from the command line.

## Requirements

- **Godot 4.7**, **Forward+** renderer.
- A **window** (a real GPU). Rendering uses Godot's low-level `RenderingDevice`, which is `null`
  under `--headless` — so there is no dedicated-server / CI rendering.
- Verified on **Apple Silicon / Metal**.

## Install

1. Copy `godot/addons/noisemaker/` into your project's `res://addons/`.
2. **Project Settings ▸ Plugins** ▸ enable **Noisemaker**.

That is everything needed to render. Full integration docs (host API, troubleshooting) live in the
**[addon README](godot/addons/noisemaker/README.md)**.

## Your first render

```gdscript
const EffectRegistry := preload("res://addons/noisemaker/compiler/lang/effect_registry.gd")
const Orchestrator   := preload("res://addons/noisemaker/compiler/graph/orchestrator.gd")
const Backend        := preload("res://addons/noisemaker/runtime/nm_backend.gd")

var rd := RenderingServer.create_local_rendering_device()
var reg := EffectRegistry.new(); reg.load_all()
var graph = Orchestrator.new(reg).build_graph(
    "search synth\nnoise(scaleX: 60).write(o0)\nrender(o0)")

var backend := Backend.new()
backend.setup(rd, "res://addons/noisemaker", Vector2i(512, 512))
var img: Image = backend.render_samples(graph, 1, 1)[0]   # one frame
var tex := ImageTexture.create_from_image(img)            # → any material / TextureRect
```

**Every DSL program** has the same shape: name the namespaces it uses (`search synth, filter`),
chain effects, write the result to an output surface (`.write(o0)`), then pick one to show
(`render(o0)`).

Render a `.dsl` file to a PNG from the command line:

```bash
GODOT=/Applications/Godot.app/Contents/MacOS/Godot
$GODOT --path godot --script res://addons/noisemaker/tools/render_graph.gd \
       --position 5000,5000 -- --dsl parity/programs/noise.dsl --out /tmp/noise.png --size 256
```

## What works today

- The **whole 2D effect catalog** (~180 effects: noise, filters, mixers, classic generators)
  **renders**, and is **pixel-identical to the web reference** within 8-bit rounding.
- **Particle/agent sims and fluid (navier–stokes)** render and match the reference.
- **Chaotic** particle-and-fluid programs render correctly, but as a *different instance* of the same
  chaos — they match in look and behavior, not pixel-for-pixel (tiny GPU rounding differences get
  amplified by feedback).
- **3D effects are staged** — their definitions ship, the shaders don't yet.

Coverage table, parity numbers, and the full "chaos" explanation: **[STATUS.md](STATUS.md)** and
**[docs/CHAOS-GATE.md](docs/CHAOS-GATE.md)**.

## How it works

Noisemaker turns a DSL program into a **render graph** — a normalized list of GPU passes. That graph
is the shared seam every Noisemaker port targets. noisemaker-godot ports the whole compiler to
GDScript (so it runs in-engine) and executes the graph on Godot's `RenderingDevice`.

→ **[ARCHITECTURE.md](ARCHITECTURE.md)** (how it maps onto Godot) ·
**[PORTING-GUIDE.md](PORTING-GUIDE.md)** (porting a shader).

## Contributing

The addon needs nothing external. The **dev/parity tooling**, however, compares Godot's output
against the reference engine, so it needs a checkout of it via `NM_REFERENCE_ROOT`:

```bash
NM_REFERENCE_ROOT=/path/to/noisemaker GODOT=/path/to/Godot bash parity/run.sh noise
#   -> [PASS] noise: max-abs-diff=1.000 ... ssim=0.99996
```

→ **[parity/README.md](parity/README.md)** (test harness) · **[STATUS.md](STATUS.md)** (coverage +
gate results) · `reference/01–10` (engine specs shared across all Noisemaker ports).

## Repo layout

```
godot/addons/noisemaker/   the addon — copy this into res://addons/ (compiler + runtime + shaders + effects)
parity/                    golden-image test harness + DSL programs
tools/                     Node dev tooling (reference graph export, codegen)
reference/                 engine specs shared across all Noisemaker ports
ARCHITECTURE.md  PORTING-GUIDE.md  docs/   design, porting rules, platform notes
STATUS.md                  coverage table, parity results, known limits
```

## License

MIT (see [LICENSE](LICENSE)). Use of the Noisemaker and Noise Factor names in derivative products is
subject to the [Trademark Policy](TRADEMARK.md).

Copyright © 2026 Noise Factor LLC
