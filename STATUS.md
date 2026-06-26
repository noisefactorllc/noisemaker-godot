# noisemaker-godot — status & parity

*Last verified 2026-06-21 on Apple M4 / Metal. The sources of truth are `parity/sweep.sh` and
`parity/check_*.mjs`.*

This file holds the detailed coverage and parity numbers. For what the project is and how to use it,
see the [README](README.md).

## Coverage

**182 effect definitions** and ~184 GLSL shaders across 8 namespaces.

| Namespace | Definitions | Shaders | State |
|---|---|---|---|
| `synth` | 29 | 33 | renders (generators, df64 fractals, value/simplex/cell/gabor/curl noise) |
| `filter` | 90 | 105 | renders (color ops, convolutions, warps, multi-pass, feedback) |
| `mixer` | 14 | 14 | renders (whole namespace) |
| `classicNoisedeck` | 20 | 18 | renders (legacy generators) |
| `points` / `render` | 10 / 11 | 2 / 12 | renders — agents (MRT/scatter); chaotic flows chaos-gated |
| `synth3d` / `filter3d` | 7 / 1 | 0 / 0 | **staged** (definitions only — 3D volumes/raymarch/meshes) |

## Parity

- **In-engine compiler:** 158/158 across all six gates (lex / parse / validate / expand / graph) plus
  full registry parity (ops 182/182, enums, aliases, 544 effect keys) vs the reference.
- **2D effects + agents (single-frame, `parity/sweep.sh`):** 93/93 pass, 2 chaos-gated skips. Most
  land within 1/255 (SSIM ≈ 1.0); ~13 are SSIM-gated with documented per-program tolerances
  (resampling / discontinuity-boundary drift).
- **Stateful sims (navierStokes):** pixel-parity via 30 s timed sampling (`parity/run_samples.sh`),
  SSIM ≥ 0.999 in the stable regime.
- **Live blaster corpus:** 4/5 renderable real programs at parity; 1 chaos-gated (reactionDiffusion).

Two compilers emit **byte-identical** render graphs: the in-engine GDScript compiler (production) and
the reference `compileGraph` via `tools/export-graph.mjs` (used only to verify the in-engine one).
Rendering either graph produces the same PNG.

## Known limits

- **The chaos gate.** Every effect is bit-exact to the reference *except chaotic agent flows* (and
  `target.dsl`, which feeds one into a fluid solver): those render correctly but as a *different
  instance* of the chaos, gated by a single spec-legal ~1-ULP `pow` rounding difference in Godot's
  shader compiler that the chaotic loop amplifies. A second, milder class (~13 effects) drifts
  ≤1–2 LSB on <0.2 % of pixels at resampling / discontinuity boundaries and is SSIM-gated. Cause,
  evidence, and repro: [docs/CHAOS-GATE.md](docs/CHAOS-GATE.md).
- **3D is staged:** `synth3d` / `filter3d` ship definitions but **0 shaders** yet.
- **Platform:** verified on Apple Silicon / Metal only; rendering needs a window (no `--headless`).

## Why `RenderingDevice` (not `.gdshader`)

The engine needs exact `rgba16f` / `rgba32f` render targets, MRT-in-one-pass, explicit ping-pong
double-buffering, and bit-exact linear float with **no implicit sRGB**. Godot's high-level
`.gdshader` + `SubViewport` path structurally cannot meet those (it caps at `rgba16f`, forces sRGB on
viewport readback, and has no user MRT). `RenderingDevice` (Vulkan-GLSL, `#version 450`) provides all
of it. Its coordinate system is top-left / Vulkan Y-down clip — identical to WGSL/D3D — so shaders
port from the reference WGSL with no per-effect Y-flip; a single global flip at present reconciles to
the WebGL2 golden.
