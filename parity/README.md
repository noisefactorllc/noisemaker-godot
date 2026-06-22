# Parity harness

How noisemaker-godot is verified against the JS/WebGL2 reference engine. Two independent layers:

1. **Pixel parity** — render the Godot candidate and diff it against a reference GPU golden.
2. **Compiler parity** — diff the in-engine GDScript compiler's output against the reference compiler,
   stage by stage (the "the DSL builds the same graph" test).

> The reference engine is needed here (and only here). Point the tooling at a checkout with
> `NM_REFERENCE_ROOT=/path/to/noisemaker`; this repo assumes no sibling checkout. `GODOT` is the
> Godot 4.7 binary. The **addon itself needs none of this** — see `../godot/addons/noisemaker/README.md`.

## 1. Pixel parity

The candidate must render **non-headless** (RenderingDevice is null under `--headless`); the harness
runs Godot with an off-screen window (`--position 5000,5000`).

```bash
# one program: render the Godot candidate + compare to the golden
NM_REFERENCE_ROOT=/path/to/noisemaker GODOT=/path/to/Godot bash parity/run.sh noise
#   -> [PASS] noise: max-abs-diff=1.000 ... ssim=0.99996

# the whole catalog (per-program tolerance map inside; last recorded 93/93, 2 chaos-gated skips)
NM_REFERENCE_ROOT=... GODOT=... bash parity/sweep.sh

# stateful sims (navierStokes, feedback): sample a 30 s / 5 s evolution, not a frozen frame
NM_REFERENCE_ROOT=... GODOT=... bash parity/run_samples.sh navierStokes
```

Pieces:
- `export-and-render.mjs` — renders the reference GPU **golden** PNG (WebGL2, headless Chromium via
  Playwright + system Chrome) at a fixed size/seed/time; also writes the golden graph JSON.
- `../tools/export-graph.mjs` — the reference `compileGraph` serialized to graph JSON (the `--graph`
  input to the candidate renderer).
- `../godot/addons/noisemaker/tools/render_graph.gd --graph <json>` — the Godot **candidate** PNG.
- `compare.py` — max-abs-diff + SSIM with a per-program tolerance (`sweep.sh` holds the map).

Adding a golden: write `parity/programs/<name>.dsl`, then
`node ../tools/export-graph.mjs --file parity/programs/<name>.dsl parity/out/<name>.graph.json` and
`SHADE_HEADLESS=1 node parity/export-and-render.mjs parity/programs/<name>.dsl parity/out --size 256 --time 0.25 --backend webgl2`.

## 2. Compiler parity (in-engine DSL → graph)

Six gates verify the GDScript compiler stage by stage against the reference. Each runs a reference
**oracle** (Node) and a Godot **candidate** dump (headless — these are pure logic, no RenderingDevice),
then deep-compares the two (key-order-insensitive, with a tight numeric epsilon for float
serialization). Only the oracle needs `NM_REFERENCE_ROOT`.

```bash
NM_REFERENCE_ROOT=/path/to/noisemaker GODOT=/path/to/Godot node parity/check_lex.mjs       # tokens
NM_REFERENCE_ROOT=... GODOT=... node parity/check_parse.mjs                                 # AST
NM_REFERENCE_ROOT=... GODOT=... node parity/check_validate.mjs                              # validated plan
NM_REFERENCE_ROOT=... GODOT=... node parity/check_expand.mjs                                # render passes
NM_REFERENCE_ROOT=... GODOT=... node parity/check_graph.mjs                                 # normalized graph
NM_REFERENCE_ROOT=... GODOT=... node parity/check_registry.mjs                              # effect registry
#   -> e.g. "GRAPH PARITY: 158/158 pass"
```

Corpus: **158 DSL programs** (`parity/programs/` 148 + `parity/corpus/` 10). All six gates pass
158/158 (registry: ops 182/182, enums, aliases, 544 effect keys — 5/5 surfaces). The candidate dumps
are the `_*_dump.gd` scripts under `../godot/addons/noisemaker/compiler/`; the oracles are
`../tools/dump-*.mjs`.

Because the in-engine graph is byte-identical to the reference's, rendering the candidate via
`render_graph.gd --dsl <file>` (the self-contained path) produces the **same PNG** as rendering the
reference's `--graph <json>`.

See also `../docs/GRAPH-JSON-SCHEMA.md` (the graph contract) and `../docs/CHAOS-GATE.md` (the one
documented cross-backend parity limit).
