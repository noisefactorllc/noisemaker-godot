# Changelog

All notable changes to noisemaker-godot. Versions track `godot/addons/noisemaker/plugin.cfg`.
This is pre-1.0, WIP software — see the README's status banner.

## [Unreleased]

### Added
- **In-engine DSL→graph compiler** (`godot/addons/noisemaker/compiler/`): a complete GDScript port of
  the reference compiler — `lang/` (lexer → parser → validator → effect-registry) and `graph/`
  (expander → orchestrator) — so the addon compiles the Polymorphic DSL with **no Node/reference/
  network** at runtime. Entry point `Orchestrator.new(EffectRegistry.new()).build_graph(source)`.
- **Self-contained render path:** `tools/render_graph.gd --dsl <file>` builds the graph in-engine and
  renders it; `tools/present.gd` composes the DSL beside the rendered canvas.
- **Compiler parity gates** (`parity/check_{lex,parse,validate,expand,graph,registry}.mjs`): each stage
  diffed against the reference over the 158-DSL corpus — all **158/158** (registry 5/5 surfaces).
- **Integration docs:** addon README (`godot/addons/noisemaker/README.md`), `parity/README.md`, this
  changelog.
- Agents/points capability in the executor: MRT, procedural points/billboard deposit (`ONE,ONE`
  additive), repeat loops, ping-pong double-buffering, navierStokes, feedback.

### Changed
- Render-graph executor consolidated into a single `runtime/nm_backend.gd`.
- Documentation brought up to date (the in-engine compiler is the production graph producer; the
  reference is parity/dev tooling only).

### Known limitations
- Verified on **Apple Silicon / Metal** only.
- Rendering needs a real `RenderingDevice` (null under `--headless`) — no headless/dedicated-server rendering.
- **3D** effects (`synth3d`/`filter3d`) ship definitions but no shaders yet.
- Chaotic agent flows (and `target.dsl`) render but as a different chaos instance — see
  `docs/CHAOS-GATE.md`.
- Integration is scripting-only (no editor `NMRenderer` node yet).

## [0.1.0]
- Initial Godot 4.7 `RenderingDevice` render-graph executor and per-effect GLSL ports; 2D effect
  catalog pixel-parity against the JS/WebGL2 reference on Apple Silicon/Metal.
