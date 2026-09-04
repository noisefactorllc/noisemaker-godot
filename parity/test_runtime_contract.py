#!/usr/bin/env python3
"""GPU-free Godot regression tests for runtime contracts."""

import os
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]
GODOT = Path(os.environ.get("GODOT", "/Applications/Godot.app/Contents/MacOS/Godot"))


@unittest.skipUnless(GODOT.exists(), f"Godot binary not found: {GODOT}")
class RuntimeContractTests(unittest.TestCase):
    def _run_godot_script(self, script):
        with tempfile.TemporaryDirectory(prefix="nm-godot-runtime-") as tmp:
            script_path = Path(tmp) / "runtime_test.gd"
            script_path.write_text(textwrap.dedent(script))
            return subprocess.run(
                [str(GODOT), "--headless", "--path", str(REPO / "godot"), "--script", str(script_path)],
                capture_output=True,
                text=True,
                timeout=30,
            )

    def test_boolean_definition_defines_emit_glsl_bool_literals(self):
        script = textwrap.dedent(
            """
            extends SceneTree

            func read_definition(path: String) -> Dictionary:
                var file := FileAccess.open(path, FileAccess.READ)
                var parsed = JSON.parse_string(file.get_as_text())
                file.close()
                return parsed

            func _init() -> void:
                var backend_script = load("res://addons/noisemaker/runtime/nm_backend.gd")
                if backend_script == null or not backend_script.can_instantiate():
                    print("DEFINE_TEST: backend failed to load")
                    quit(1)
                    return
                var backend = backend_script.new()
                if not backend.has_method("_format_define_value"):
                    print("DEFINE_TEST: missing definition-aware formatter")
                    quit(1)
                    return
                var noise3d := read_definition("res://addons/noisemaker/effects/synth3d/noise3d.json")
                var render3d := read_definition("res://addons/noisemaker/effects/render/render3d.json")
                var curl := read_definition("res://addons/noisemaker/effects/synth/curl.json")
                var noise_source := FileAccess.get_file_as_string("res://addons/noisemaker/shaders/effects/synth3d/noise3d/precompute.glsl")
                var render_source := FileAccess.get_file_as_string("res://addons/noisemaker/shaders/effects/render/render3d/render3d.glsl")
                var curl_source := FileAccess.get_file_as_string("res://addons/noisemaker/shaders/effects/synth/curl/curl.glsl")
                var actual := [
                    backend.call("_format_define_value", "RIDGES", 0.0, noise3d, noise_source),
                    backend.call("_format_define_value", "RIDGES", 1.0, noise3d, noise_source),
                    backend.call("_format_define_value", "INVERT", 0.0, render3d, render_source),
                    backend.call("_format_define_value", "FILTERING", 0.0, render3d, render_source),
                    backend.call("_format_define_value", "OCTAVES", 4.0, noise3d, noise_source),
                    backend.call("_format_define_value", "RIDGES", 1.0, curl, curl_source),
                    backend.call("_format_define_value", "RIDGES", 1.0, curl, "// if (RIDGES)\\nif (RIDGES != 0) {}"),
                ]
                var expected := ["false", "true", "false", "0", "4", "1", "1"]
                if actual == expected:
                    print("DEFINE_TEST: PASS")
                    quit(0)
                else:
                    print("DEFINE_TEST: expected=", expected, " actual=", actual)
                    quit(1)
            """
        )
        result = self._run_godot_script(script)

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("DEFINE_TEST: PASS", result.stdout, result.stdout + result.stderr)

    def test_parameterized_texture_dimension_applies_power(self):
        script = """
            extends SceneTree

            func _init() -> void:
                var backend_script = load("res://addons/noisemaker/runtime/nm_backend.gd")
                if backend_script == null or not backend_script.can_instantiate():
                    print("DIMENSION_TEST: backend failed to load")
                    quit(1)
                    return
                var backend = backend_script.new()
                var power_spec := {"param": "volumeSize_chain_0", "power": 2, "default": 4096}
                var multiply_spec := {"param": "volumeSize_chain_0", "multiply": 2, "default": 128}
                var actual := [
                    backend.call("_resolve_dim", power_spec, 256, {"volumeSize_chain_0": 64}),
                    backend.call("_resolve_dim", power_spec, 256, {}),
                    backend.call("_resolve_dim", multiply_spec, 256, {"volumeSize_chain_0": 32}),
                ]
                var expected := [4096, 4096, 64]
                if actual == expected:
                    print("DIMENSION_TEST: PASS")
                    quit(0)
                else:
                    print("DIMENSION_TEST: expected=", expected, " actual=", actual)
                    quit(1)
        """
        result = self._run_godot_script(script)

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("DIMENSION_TEST: PASS", result.stdout, result.stdout + result.stderr)

    def test_volume_uniforms_clamp_power_of_two_to_texture_limit(self):
        script = """
            extends SceneTree

            func graph_with_volume_size(value: int) -> Dictionary:
                return {
                    "passes": [{
                        "uniforms": {
                            "volumeSize": value,
                            "volumeSize_chain_0": value,
                            "volumeSize_node_0": value,
                            "unrelated": value,
                        },
                    }],
                    "textures": {},
                }

            func _init() -> void:
                var backend_script = load("res://addons/noisemaker/runtime/nm_backend.gd")
                var backend = backend_script.new()
                if not backend.has_method("_clamp_graph_volume_sizes"):
                    print("VOLUME_LIMIT_TEST: missing clamp method")
                    quit(1)
                    return
                var constrained := graph_with_volume_size(128)
                var exact_fit := graph_with_volume_size(128)
                backend.call("_clamp_graph_volume_sizes", constrained, 8192)
                backend.call("_clamp_graph_volume_sizes", exact_fit, 16384)
                var constrained_uniforms: Dictionary = constrained["passes"][0]["uniforms"]
                var exact_uniforms: Dictionary = exact_fit["passes"][0]["uniforms"]
                var constrained_ok: bool = constrained_uniforms == {
                    "volumeSize": 64,
                    "volumeSize_chain_0": 64,
                    "volumeSize_node_0": 64,
                    "unrelated": 128,
                }
                var exact_ok: bool = exact_uniforms["volumeSize"] == 128 \
                    and exact_uniforms["volumeSize_chain_0"] == 128 \
                    and exact_uniforms["volumeSize_node_0"] == 128
                if constrained_ok and exact_ok:
                    print("VOLUME_LIMIT_TEST: PASS")
                    quit(0)
                else:
                    print("VOLUME_LIMIT_TEST: constrained=", constrained_uniforms, " exact=", exact_uniforms)
                    quit(1)
        """
        result = self._run_godot_script(script)

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("VOLUME_LIMIT_TEST: PASS", result.stdout, result.stdout + result.stderr)

    def test_mrt_budget_demotes_trailing_float_attachment_only_when_needed(self):
        script = """
            extends SceneTree

            func graph_with_mrt() -> Dictionary:
                return {
                    "passes": [{
                        "id": "pointsEmit:init",
                        "outputs": {"xyzOut": "xyz", "velOut": "vel", "rgbaOut": "rgba"},
                    }],
                    "textures": {
                        "xyz": {"format": "rgba32f"},
                        "vel": {"format": "rgba32float"},
                        "rgba": {"format": "rgba8"},
                    },
                }

            func _init() -> void:
                var backend_script = load("res://addons/noisemaker/runtime/nm_backend.gd")
                var backend = backend_script.new()
                if not backend.has_method("_apply_mrt_format_budget"):
                    print("MRT_BUDGET_TEST: missing budget method")
                    quit(1)
                    return
                var constrained := graph_with_mrt()
                var desktop := graph_with_mrt()
                backend.call("_apply_mrt_format_budget", constrained, 32)
                backend.call("_apply_mrt_format_budget", desktop, 64)
                var constrained_textures: Dictionary = constrained["textures"]
                var desktop_textures: Dictionary = desktop["textures"]
                var constrained_ok: bool = constrained_textures["xyz"]["format"] == "rgba32f" \
                    and constrained_textures["vel"]["format"] == "rgba16f" \
                    and constrained_textures["rgba"]["format"] == "rgba8"
                var desktop_ok: bool = desktop_textures["xyz"]["format"] == "rgba32f" \
                    and desktop_textures["vel"]["format"] == "rgba32float" \
                    and desktop_textures["rgba"]["format"] == "rgba8"
                if constrained_ok and desktop_ok:
                    print("MRT_BUDGET_TEST: PASS")
                    quit(0)
                else:
                    print("MRT_BUDGET_TEST: constrained=", constrained_textures, " desktop=", desktop_textures)
                    quit(1)
        """
        result = self._run_godot_script(script)

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("MRT_BUDGET_TEST: PASS", result.stdout, result.stdout + result.stderr)

    def test_audio_samples_pack_into_declared_scope_and_spectrum_slots(self):
        script = """
            extends SceneTree

            func _init() -> void:
                var backend_script = load("res://addons/noisemaker/runtime/nm_backend.gd")
                var backend = backend_script.new()
                if not backend.has_method("set_audio_samples"):
                    print("AUDIO_PACK_TEST: missing audio sample API")
                    quit(1)
                    return
                var waveform := PackedFloat32Array()
                waveform.resize(128)
                waveform[0] = 0.25
                waveform[1] = 0.5
                waveform[2] = 0.75
                waveform[3] = 1.0
                var spectrum := PackedFloat32Array()
                spectrum.resize(128)
                spectrum[0] = 1.0
                spectrum[1] = 0.75
                spectrum[2] = 0.5
                spectrum[3] = 0.25
                backend.call("set_audio_samples", waveform, spectrum)
                var layout := {
                    "audioWaveform_0": {"slot": 4, "components": "xyzw"},
                    "audioSpectrum_0": {"slot": 5, "components": "xyzw"},
                }
                var packed: PackedByteArray = backend.call("pack_with_layout", layout, {}, {})
                var values := packed.to_float32_array()
                var expected := PackedFloat32Array()
                expected.resize(24)
                expected[16] = 0.25
                expected[17] = 0.5
                expected[18] = 0.75
                expected[19] = 1.0
                expected[20] = 1.0
                expected[21] = 0.75
                expected[22] = 0.5
                expected[23] = 0.25
                if values == expected:
                    print("AUDIO_PACK_TEST: PASS")
                    quit(0)
                else:
                    print("AUDIO_PACK_TEST: expected=", expected, " actual=", values)
                    quit(1)
        """
        result = self._run_godot_script(script)

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("AUDIO_PACK_TEST: PASS", result.stdout, result.stdout + result.stderr)

    def test_nested_oscillator_uniform_is_seekable_and_scaled_when_packed(self):
        script = """
            extends SceneTree

            func _init() -> void:
                var backend_script = load("res://addons/noisemaker/runtime/nm_backend.gd")
                var backend = backend_script.new()
                if not backend.has_method("resolve_uniform_value"):
                    print("NESTED_AUTOMATION_TEST: missing runtime automation resolver")
                    quit(1)
                    return
                var rate := {
                    "type": "Oscillator", "oscType": 0,
                    "min": 0.0, "max": 1.0, "speed": 1.0, "offset": 0.0, "seed": 1.0,
                }
                var carrier := {
                    "type": "Oscillator", "oscType": 2,
                    "min": 0.0, "max": 1.0, "speed": rate, "offset": 0.0, "seed": 1.0,
                }
                var quarter = backend.call("resolve_uniform_value", carrier, 0.25, {"min": 2.0, "max": 6.0})
                var later = backend.call("resolve_uniform_value", carrier, 0.75, null)
                backend.call("resolve_uniform_value", carrier, 0.12, null)
                var repeated = backend.call("resolve_uniform_value", carrier, 0.75, null)
                var expected_quarter = 2.0 + 4.0 * fposmod(-20.0 / TAU, 1.0)
                var expected_later = fposmod(20.0 / TAU, 1.0)
                var layout := {"amount": {"slot": 0, "components": "x"}}
                var pass_data := {
                    "uniforms": {"amount": carrier},
                    "uniformSpecs": {"amount": {"min": 2.0, "max": 6.0}},
                }
                backend.set("_time", 0.25)
                var packed: PackedByteArray = backend.call("pack_with_layout", layout, {}, pass_data)
                var packed_amount = packed.to_float32_array()[0]
                var ok: bool = abs(quarter - expected_quarter) <= 1e-8 \
                    and abs(later - expected_later) <= 1e-8 \
                    and repeated == later \
                    and abs(packed_amount - expected_quarter) <= 1e-6
                if ok:
                    print("NESTED_AUTOMATION_TEST: PASS")
                    quit(0)
                else:
                    print("NESTED_AUTOMATION_TEST: quarter=", quarter, " later=", later,
                        " repeated=", repeated, " packed=", packed_amount)
                    quit(1)
        """
        result = self._run_godot_script(script)

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("NESTED_AUTOMATION_TEST: PASS", result.stdout, result.stdout + result.stderr)

    def test_external_inputs_drive_nested_rate_and_capture_requirements_recurse(self):
        script = """
            extends SceneTree

            func oscillator(kind: int, speed) -> Dictionary:
                return {
                    "type": "Oscillator", "oscType": kind,
                    "min": 0.0, "max": 1.0, "speed": speed, "offset": 0.0, "seed": 1.0,
                }

            func _init() -> void:
                var backend = load("res://addons/noisemaker/runtime/nm_backend.gd").new()
                if not backend.has_method("get_audio_input_requirements"):
                    print("EXTERNAL_AUTOMATION_TEST: missing capture requirements")
                    quit(1)
                    return
                var midi_rate := {
                    "type": "Midi", "channel": 1, "mode": 2,
                    "min": 0.0, "max": 1.0, "sensitivity": 1.0,
                }
                var audio_rate := {
                    "type": "Audio", "band": 4,
                    "min": 0.0, "max": 1.0, "_invalid": false,
                }
                backend.call("set_midi_state", {
                    "channels": {1: {"key": 60, "velocity": 127, "gate": 1, "time": 0}},
                })
                backend.call("set_audio_state", {"raw": 1.0, "rawReady": true})
                var midi_forward = backend.call("resolve_uniform_value", oscillator(2, midi_rate), 0.0125, null)
                var audio_forward = backend.call("resolve_uniform_value", oscillator(2, audio_rate), 0.0125, null)
                backend.call("set_midi_state", {
                    "channels": {1: {"key": 60, "velocity": 0, "gate": 1, "time": 0}},
                })
                backend.call("set_audio_state", {"raw": -1.0, "rawReady": true})
                var midi_reverse = backend.call("resolve_uniform_value", oscillator(2, midi_rate), 0.0125, null)
                var audio_reverse = backend.call("resolve_uniform_value", oscillator(2, audio_rate), 0.0125, null)

                var inner := {
                    "type": "Audio", "band": 4, "min": 0.0, "max": 1.0, "_invalid": false,
                    "channel": 2, "name": "Inner Interface", "id": "inner-id",
                }
                var outer := {
                    "type": "Audio", "band": 0, "min": inner, "max": 1.0, "_invalid": false,
                    "channel": 1, "name": "Outer Interface", "id": "outer-id",
                }
                var requirements: Dictionary = backend.call("get_audio_input_requirements", {
                    "passes": [
                        {"uniforms": {"amount": outer}},
                        {
                            "effectKey": "synth.scope", "namespace": "synth", "func": "scope",
                            "uniforms": {},
                        },
                    ],
                })
                var ids := []
                for requirement in requirements["selected"]:
                    ids.append(requirement["id"])
                ids.sort()
                var invalid_outer := {
                    "type": "Audio", "band": 0, "min": inner, "max": 1.0, "_invalid": true,
                }
                var invalid_requirements: Dictionary = backend.call("get_audio_input_requirements", {
                    "passes": [{"uniforms": {"amount": invalid_outer}}],
                })
                var invalid_value = backend.call("resolve_uniform_value", invalid_outer, 0.5, null)

                backend.call("set_audio_state", {
                    "devices": {
                        "actual-id": {
                            "name": "Shared Name", "connected": true,
                            "channels": {1: {"low": 0.8}},
                        },
                    },
                })
                var missing_id := {
                    "type": "Audio", "band": 0, "min": 0.0, "max": 1.0, "_invalid": false,
                    "channel": 1, "name": "Shared Name", "id": "missing-id",
                }
                var missing_id_value = backend.call("resolve_uniform_value", missing_id, 0.5, null)
                var cyclic := oscillator(0, 1.0)
                cyclic["speed"] = cyclic
                var cyclic_value = backend.call("resolve_uniform_value", cyclic, 0.25, null)
                var ok: bool = abs(midi_forward - 0.25) <= 1e-8 \
                    and abs(audio_forward - 0.25) <= 1e-8 \
                    and abs(midi_reverse - 0.75) <= 1e-8 \
                    and abs(audio_reverse - 0.75) <= 1e-8 \
                    and ids == ["inner-id", "outer-id"] \
                    and requirements["needsLegacy"] \
                    and invalid_requirements["selected"].is_empty() \
                    and invalid_value == 0.0 \
                    and missing_id_value == 0.0 \
                    and cyclic_value == 0.0
                if ok:
                    print("EXTERNAL_AUTOMATION_TEST: PASS")
                    quit(0)
                else:
                    print("EXTERNAL_AUTOMATION_TEST: midi=", midi_forward, "/", midi_reverse,
                        " audio=", audio_forward, "/", audio_reverse, " ids=", ids,
                        " invalid=", invalid_requirements, "/", invalid_value,
                        " missing-id=", missing_id_value, " cyclic=", cyclic_value)
                    quit(1)
        """
        result = self._run_godot_script(script)

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("EXTERNAL_AUTOMATION_TEST: PASS", result.stdout, result.stdout + result.stderr)

    def test_blend_factor_names_accept_definition_json_casing(self):
        script = """
            extends SceneTree

            func _init() -> void:
                var backend_script = load("res://addons/noisemaker/runtime/nm_backend.gd")
                var backend = backend_script.new()
                var upper = backend.call("_blend_factor", "ONE")
                var lower = backend.call("_blend_factor", "one")
                if upper == lower and upper == RenderingDevice.BLEND_FACTOR_ONE:
                    print("BLEND_CASE_TEST: PASS")
                    quit(0)
                else:
                    print("BLEND_CASE_TEST: upper=", upper, " lower=", lower)
                    quit(1)
        """
        result = self._run_godot_script(script)

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("BLEND_CASE_TEST: PASS", result.stdout, result.stdout + result.stderr)
        self.assertNotIn("unknown blend factor", result.stdout + result.stderr)

    def test_synthesized_mat3_uniform_uses_three_std140_columns(self):
        script = """
            extends SceneTree

            func _init() -> void:
                var backend_script = load("res://addons/noisemaker/runtime/nm_backend.gd")
                var backend = backend_script.new()
                var globals := {
                    "basis": {
                        "type": "mat3",
                        "uniform": "cubeBasis",
                        "default": [1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0],
                    }
                }
                var layout: Dictionary = backend.call("_synth_layout", "test", "mat3", globals)
                var header: String = backend.call("_synth_header", layout)
                var packed: PackedByteArray = backend.call("pack_with_layout", layout, globals, {})
                var values := packed.to_float32_array()
                var spec: Dictionary = layout.get("cubeBasis", {})
                var slot := int(spec.get("slot", -1))
                var matrix_ok: bool = spec.get("columns") == 3 \
                    and header.contains("mat3(data[%d].xyz, data[%d].xyz, data[%d].xyz)" % [slot, slot + 1, slot + 2]) \
                    and values[slot * 4] == 1.0 and values[slot * 4 + 2] == 3.0 \
                    and values[(slot + 1) * 4] == 4.0 and values[(slot + 2) * 4 + 2] == 9.0
                if matrix_ok:
                    print("MAT3_LAYOUT_TEST: PASS")
                    quit(0)
                else:
                    print("MAT3_LAYOUT_TEST: layout=", layout, " header=", header, " values=", values)
                    quit(1)
        """
        result = self._run_godot_script(script)

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("MAT3_LAYOUT_TEST: PASS", result.stdout, result.stdout + result.stderr)

    def test_lens_warp_packs_inherited_pipeline_speed_without_definition_drift(self):
        script = """
            extends SceneTree

            func _init() -> void:
                var backend_script = load("res://addons/noisemaker/runtime/nm_backend.gd")
                var backend = backend_script.new()
                var globals := {
                    "displacement": {"type": "float", "uniform": "displacement", "default": 0.0625},
                    "antialias": {"type": "boolean", "uniform": "antialias", "default": true},
                }
                var layout: Dictionary = backend.call("_synth_layout", "filter", "lensWarp", globals)
                var speed_spec: Dictionary = layout.get("speed", {})
                var packed: PackedByteArray = backend.call(
                    "pack_with_layout", layout, globals, {"uniforms": {"speed": 7.0}}
                )
                var values := packed.to_float32_array()
                var slot := int(speed_spec.get("slot", -1))
                var offsets: Array = backend.call("_comp_offsets", str(speed_spec.get("components", "")))
                var speed_ok: bool = slot >= 0 and offsets.size() == 1 \
                    and values[slot * 4 + int(offsets[0])] == 7.0
                if speed_ok:
                    print("LENS_WARP_SPEED_TEST: PASS")
                    quit(0)
                else:
                    print("LENS_WARP_SPEED_TEST: layout=", layout, " values=", values)
                    quit(1)
        """
        result = self._run_godot_script(script)

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("LENS_WARP_SPEED_TEST: PASS", result.stdout, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
