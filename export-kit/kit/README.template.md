# {{NM_PROGRAM_NAME}}

A Godot 4 project exported from Noisedeck. It carries your program as a plain text file and compiles
it inside Godot with the Noisemaker addon. Nothing is pre-baked, and it fetches nothing at runtime.

## Run it

1. Unzip this folder anywhere.
2. Open `project.godot` in **Godot 4.7** or newer, with the **Forward+** renderer.
3. Press **Play**.

The project reads `res://program.dsl` and compiles it in-engine. It renders a sequence of frames.
It then plays the sampled stills in a loop in the window.

### Godot has to have a real GPU device

Noisemaker for Godot renders through a local `RenderingDevice`. That object is `null` under
`--headless`, and it is also `null` under the OpenGL driver (`--rendering-driver opengl3`) even with
a window open. Both cases fail with `RenderingDevice unavailable`, and neither is a setting you can
change: `RenderingDevice` is a Vulkan / Metal / D3D12 abstraction.

So this project needs a window and a Forward+ device. There is no headless, dedicated-server, or CI
rendering. To render without a visible window, position it offscreen (see **Still images**).

## What's inside

| Path | What it is |
| --- | --- |
| `project.godot` | The Godot project. Open this. |
| `main.tscn` / `main.gd` | The scene that boots, and the script that compiles and plays your program. |
| `addons/noisemaker/tools/render_graph.gd` | A command line renderer that writes a PNG offline (see **Still images**); ships with the addon. |
| `program.dsl` | Your program's source, exactly as Noisedeck had it. |
| `noisedeck-export.json` | What was exported, when, against which engine build. |
| `addons/noisemaker/` | The Noisemaker addon. Present if you kept **include engine code** checked. |
| `shaders/` | Reference copies of the GLSL behind your effects. Present if you kept **include shader code** checked. |
| `LICENSES/` | Licenses for everything shipped here. |

The addon renders from its own shader copies under `addons/noisemaker/shaders/`. The top level
`shaders/` folder is there to read, not to edit: changing a file in it changes nothing.

Some of those effects open with `#include "include/nm_core.glsl"`, a shared header holding the
hashing, PRNG and mapping primitives they have in common. It travels with them: you get it at
`shaders/include/nm_core.glsl` whenever **include shader code** is on, and the addon carries its own
copy at `addons/noisemaker/shaders/include/nm_core.glsl`.

## The engine

If you kept **include engine code** checked, the port is at `addons/noisemaker/`. Press Play to run it offline.

If the addon is already installed, you only need `program.dsl`, plus `shaders/` if you kept
**include shader code** checked.

Without `addons/noisemaker/`, the project fails to load its preloads.
Get the port from <https://github.com/noisefactorllc/noisemaker-for-godot>.
Copy its `godot/addons/noisemaker/` into this folder under the same name.
The project then runs as described above.

Enabling the plugin under **Project Settings > Plugins** is optional here: this project preloads the
addon's scripts by path and never asks the editor for a node. That is the port's integration surface
in general. It is scripting only and registers no editor nodes, so using Noisemaker in a project of
your own means calling the compiler and backend from GDScript the way `main.gd` does.
`addons/noisemaker/README.md` documents that API.

Noisedeck exported this program against Noisemaker `{{NM_ENGINE_VERSION}}`. The Godot port is a
second implementation of that engine rather than the same code, and it is still early: expect small
differences from what the app showed you, and treat anything you render here as provisional.

## Editing it

`main.gd` holds the two numbers worth touching:

```gdscript
const SIZE := 512
const FRAMES := 1800
```

`SIZE` is the square render resolution. `FRAMES` is the number of simulation frames to run before the playback loop starts.
Fluid, agent and reaction-diffusion effects begin from an empty state, so a single frame of one is black. At 60 frames per second of simulated time, 1800
frames is about 30 seconds of evolution, and it takes roughly a minute of wall clock to compute. The
window does not repaint while that runs, which is why the scene puts a warning on screen first.

`SAMPLE_EVERY` decides how many of those frames are kept as playback stills, and `PLAYBACK_FPS` how
fast they loop once the render finishes.

Programs made only of still effects do not need this sequence. Set `FRAMES` to `1` for an immediate render.

To render a different program, replace `program.dsl`. Anything the Noisemaker language accepts
works, as long as its effects are in the supported set below.

## Still images

`res://addons/noisemaker/tools/render_graph.gd` renders offline from the command line, using the
same backend the scene does, so what it writes is what the project draws:

```
godot --path . --script res://addons/noisemaker/tools/render_graph.gd --position 5000,5000 \
      -- --dsl res://program.dsl --out /absolute/path/out.png --size 512 --run-seconds 30
```

`--size` is the square resolution. `--run-seconds` evolves the program that many seconds at 60 fps
and captures a timed series: one PNG every `--sample-every` seconds (default 5), written beside
`--out` as `out.t5.png`, `out.t10.png`, … up to `out.t30.png`, not to `--out` itself. That is what a
simulation needs, because its first frame is the empty starting state.

For a still effect, drop `--run-seconds` and the script renders a single frame straight to `--out`:

```
godot --path . --script res://addons/noisemaker/tools/render_graph.gd --position 5000,5000 \
      -- --dsl res://program.dsl --out /absolute/path/out.png --size 512
```

Everything after the bare `--` goes to the script rather than to Godot. `--position 5000,5000` is
the part that matters: the run still opens a window, because it has to, and this parks it offscreen
so it never appears over your work.

## Effects used by this program

{{NM_EFFECT_LIST}}

## What this port cannot render

External texture/camera/video/audio input is not supported. Shader sources ship for the
3D effects (`synth3d`, `filter3d`, and the 3D render stages). Shader presence does not establish
pixel parity. Use the port's parity harness to verify the program on the target platform.

No machine-readable copy of the supported set ships in this export. To check an edited `program.dsl`
against a different build of this port, put it back into Noisedeck and open the export dialog with
Godot selected: it marks any effect this port cannot render before you export again.

## License

The Noisemaker engine and the Godot port are MIT licensed. See `LICENSES/`. Your program and the
imagery it renders are yours.
