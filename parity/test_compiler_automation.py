#!/usr/bin/env python3
"""GPU-free regression tests for MIDI/audio compiler descriptors."""

import json
import os
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]
GODOT = Path(os.environ.get("GODOT", "/Applications/Godot.app/Contents/MacOS/Godot"))


@unittest.skipUnless(GODOT.exists(), f"Godot binary not found: {GODOT}")
class CompilerAutomationTests(unittest.TestCase):
    def _dump(self, script_name, programs):
        with tempfile.TemporaryDirectory(prefix="nm-godot-automation-") as tmp:
            paths = []
            for name, source in programs.items():
                path = Path(tmp) / name
                path.write_text(textwrap.dedent(source))
                paths.append(path)
            result = subprocess.run(
                [
                    str(GODOT),
                    "--headless",
                    "--path",
                    str(REPO / "godot"),
                    "--script",
                    f"res://addons/noisemaker/compiler/{script_name}",
                    "--",
                    *(str(path) for path in paths),
                ],
                capture_output=True,
                text=True,
                timeout=30,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            marker = "PARSEDUMP:" if script_name == "_parse_dump.gd" else "VALIDATEDUMP:"
            marker_line = next(
                (line for line in result.stdout.splitlines() if line.startswith(marker)),
                None,
            )
            self.assertIsNotNone(marker_line, result.stdout + result.stderr)
            payload = json.loads(marker_line[len(marker) :])
            return {Path(path).name: payload[str(path)] for path in paths}

    def test_selected_descriptors_survive_validation(self):
        source = r'''
            search synth
            noise(
                scaleX: midi(mode: 0, 2, 0.1, 0.9, 3, name: "Launchkey\\Main", id: "midi-1"),
                scaleY: audio(max: 0.9, audioBand.raw, 0.1, channel: 2, name: 'Interface "A"', id: "audio-1")
            ).write(o0)
            render(o0)
        '''
        output = self._dump("_validate_dump.gd", {"selected.dsl": source})["selected.dsl"]

        self.assertTrue(output["ok"])
        self.assertEqual(output["out"]["diagnostics"], [])
        args = output["out"]["plans"][0]["chain"][0]["args"]
        midi = args["scaleX"]
        audio = args["scaleY"]

        self.assertEqual(
            {key: midi[key] for key in ("type", "channel", "mode", "min", "max", "sensitivity", "name", "id")},
            {
                "type": "Midi",
                "channel": 2,
                "mode": 0,
                "min": 0.1,
                "max": 0.9,
                "sensitivity": 3,
                "name": r"Launchkey\Main",
                "id": "midi-1",
            },
        )
        self.assertEqual(
            {key: audio[key] for key in ("type", "band", "min", "max", "channel", "name", "id", "_invalid")},
            {
                "type": "Audio",
                "band": 4,
                "min": 0.1,
                "max": 0.9,
                "channel": 2,
                "name": 'Interface "A"',
                "id": "audio-1",
                "_invalid": False,
            },
        )

    def test_invalid_selector_forms_are_rejected(self):
        expressions = {
            "midi_id_without_name.dsl": 'midi(1, id: "midi-1")',
            "midi_unquoted_name.dsl": "midi(1, name: controller)",
            "audio_unpaired_selector.dsl": "audio(audioBand.raw, channel: 2)",
            "audio_selector_positional.dsl": "audio(audioBand.raw, 0, 1, 2)",
            "unknown_selector.dsl": 'midi(1, port: "Launchkey")',
        }
        programs = {
            name: f"search synth\nnoise(scaleX: {expression}).write(o0)\nrender(o0)\n"
            for name, expression in expressions.items()
        }
        outputs = self._dump("_parse_dump.gd", programs)

        self.assertEqual(set(outputs), set(expressions))
        self.assertTrue(all(not output["ok"] for output in outputs.values()))

    def test_invalid_audio_diagnostics_match_javascript_value_formatting(self):
        cases = {
            "band_member.dsl": (
                "audio(band: audioBand.bogus)",
                "audio() band must resolve to an integer from 0 to 4 (got undefined): 'audioBand.bogus'",
                "audioBand.bogus",
                "band",
            ),
            "band_boolean.dsl": (
                "audio(band: true)",
                "audio() band must resolve to an integer from 0 to 4 (got undefined): 'true'",
                "true",
                "band",
            ),
            "band_negative.dsl": (
                "audio(band: -1)",
                "audio() band must resolve to an integer from 0 to 4 (got -1)",
                "-1",
                "band",
            ),
            "band_integer.dsl": (
                "audio(band: 5)",
                "audio() band must resolve to an integer from 0 to 4 (got 5)",
                "5",
                "band",
            ),
            "band_fraction.dsl": (
                "audio(band: 1.5)",
                "audio() band must resolve to an integer from 0 to 4 (got 1.5)",
                "1.5",
                "band",
            ),
            "channel_zero.dsl": (
                'audio(band: audioBand.raw, channel: 0, name: "Interface")',
                "audio() channel must be a positive integer (got 0): '[Number]'",
                "[Number]",
                "channel",
            ),
            "channel_negative.dsl": (
                'audio(band: audioBand.raw, channel: -1, name: "Interface")',
                "audio() channel must be a positive integer (got -1)",
                "-1",
                "channel",
            ),
            "channel_fraction.dsl": (
                'audio(band: audioBand.raw, channel: 1.5, name: "Interface")',
                "audio() channel must be a positive integer (got 1.5)",
                "1.5",
                "channel",
            ),
        }
        programs = {
            name: f"search synth\nnoise(scaleX: {case[0]}).write(o0)\nrender(o0)\n"
            for name, case in cases.items()
        }
        outputs = self._dump("_validate_dump.gd", programs)

        for name, (_, message, identifier, invalid_field) in cases.items():
            output = outputs[name]
            self.assertTrue(output["ok"], name)
            self.assertEqual(len(output["out"]["diagnostics"]), 1, name)
            diagnostic = output["out"]["diagnostics"][0]
            self.assertEqual(diagnostic["message"], message, name)
            self.assertEqual(diagnostic["identifier"], identifier, name)
            config = output["out"]["plans"][0]["chain"][0]["args"]["scaleX"]
            self.assertTrue(config["_invalid"], name)
            self.assertNotIn(invalid_field, config, name)


if __name__ == "__main__":
    unittest.main()
