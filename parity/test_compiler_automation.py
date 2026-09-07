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

    def test_expression_modes_and_default_audio_channels(self):
        expressions = {
            **{f"mode-{mode}.dsl": f"midi(zone: selected, members: count, mode: midiMode.{mode}" +
               (", nrpn: parameter" if mode == "nrpn" else "") + ")"
               for mode in ("cc", "cc14", "nrpn", "pitchBend", "pressure", "polyPressure")},
            "default-audio.dsl": "audio(band: audioBand.raw, channel: 32)",
        }
        programs = {name: "search synth\nlet selected = midiZone.upper\nlet count = 7\nlet parameter = 1234\n"
                    f"noise(scaleX: {expression}).write(o0)\nrender(o0)"
                    for name, expression in expressions.items()}
        outputs = self._dump("_validate_dump.gd", programs)
        for mode, number in (("cc", 5), ("cc14", 6), ("nrpn", 7), ("pitchBend", 8), ("pressure", 9), ("polyPressure", 10)):
            output = outputs[f"mode-{mode}.dsl"]
            self.assertTrue(output["ok"], output)
            self.assertEqual([], output["out"]["diagnostics"])
            value = output["out"]["plans"][0]["chain"][0]["args"]["scaleX"]
            self.assertEqual(number, value["mode"])
            self.assertEqual(1, value["zone"])
            self.assertEqual(7, value["members"])
            self.assertNotIn("channel", value)
            if mode == "nrpn": self.assertEqual(1234, value["nrpn"])
            if mode in ("cc", "cc14"): self.assertEqual(1, value["cc"])
        output = outputs["default-audio.dsl"]
        self.assertTrue(output["ok"], output)
        self.assertEqual([], output["out"]["diagnostics"])
        value = output["out"]["plans"][0]["chain"][0]["args"]["scaleX"]
        self.assertEqual(32, value["channel"])
        self.assertNotIn("name", value)

    def test_invalid_expression_selectors_fail_closed(self):
        expressions = ["midi(channel: 0, mode: 5)", "midi(channel: true, mode: 8)",
                       "midi(channel: 2, mode: 6, cc: 32)", "midi(channel: 2, mode: 7)",
                       "midi(channel: 2, mode: 7, nrpn: 16383)", "midi(zone: 2)",
                       "midi(zone: 0, members: 16)", "audio(band: audioBand.raw, channel: 33)"]
        programs = {f"invalid-{index}.dsl": f"search synth\nnoise(scaleX: {expr}).write(o0)\nrender(o0)"
                    for index, expr in enumerate(expressions)}
        for name, output in self._dump("_validate_dump.gd", programs).items():
            self.assertTrue(output["ok"], name)
            self.assertTrue(output["out"]["diagnostics"], name)
            self.assertTrue(output["out"]["plans"][0]["chain"][0]["args"]["scaleX"]["_invalid"], name)

    def test_invalid_selector_forms_are_rejected(self):
        expressions = {
            "midi_id_without_name.dsl": 'midi(1, id: "midi-1")',
            "midi_unquoted_name.dsl": "midi(1, name: controller)",
            "audio_unpaired_selector.dsl": 'audio(audioBand.raw, name: "Input")',
            "midi_duplicate_selector.dsl": "midi(channel: 2, zone: 0)",
            "midi_unpaired_members.dsl": "midi(channel: 2, members: 5)",
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
                "audio() channel must be a positive integer from 1 to 32 (got 0): '[Number]'",
                "[Number]",
                "channel",
            ),
            "channel_negative.dsl": (
                'audio(band: audioBand.raw, channel: -1, name: "Interface")',
                "audio() channel must be a positive integer from 1 to 32 (got -1)",
                "-1",
                "channel",
            ),
            "channel_fraction.dsl": (
                'audio(band: audioBand.raw, channel: 1.5, name: "Interface")',
                "audio() channel must be a positive integer from 1 to 32 (got 1.5)",
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

    def test_nested_automation_sources_survive_validation(self):
        source = """
            search synth
            let rate = audio(band: audioBand.raw, min: 0.25, max: 0.75)
            let carrier = osc(type: oscKind.saw, min: rate, speed: rate)
            noise(scaleX: carrier).write(o0)
            render(o0)
        """
        output = self._dump("_validate_dump.gd", {"nested.dsl": source})["nested.dsl"]

        self.assertTrue(output["ok"])
        self.assertEqual(output["out"]["diagnostics"], [])
        carrier = output["out"]["plans"][0]["chain"][0]["args"]["scaleX"]
        self.assertEqual(carrier["type"], "Oscillator")
        self.assertEqual(carrier["oscType"], 2)
        for field in ("min", "speed"):
            self.assertEqual(carrier[field]["type"], "Audio")
            self.assertEqual(carrier[field]["_varRef"], "rate")

    def test_automation_cycles_and_excess_depth_are_reported(self):
        programs = {
            "cycle.dsl": """
                search synth
                let first = osc(type: oscKind.sine, speed: second)
                let second = osc(type: oscKind.tri, speed: first)
                noise(scaleX: first).write(o0)
                render(o0)
            """,
            "depth.dsl": """
                search synth
                let rate9 = osc(type: oscKind.sine)
                let rate8 = osc(type: oscKind.sine, speed: rate9)
                let rate7 = osc(type: oscKind.sine, speed: rate8)
                let rate6 = osc(type: oscKind.sine, speed: rate7)
                let rate5 = osc(type: oscKind.sine, speed: rate6)
                let rate4 = osc(type: oscKind.sine, speed: rate5)
                let rate3 = osc(type: oscKind.sine, speed: rate4)
                let rate2 = osc(type: oscKind.sine, speed: rate3)
                let rate1 = osc(type: oscKind.sine, speed: rate2)
                let carrier = osc(type: oscKind.saw, speed: rate1)
                noise(scaleX: carrier).write(o0)
                render(o0)
            """,
        }
        outputs = self._dump("_validate_dump.gd", programs)

        cycle_messages = [item["message"] for item in outputs["cycle.dsl"]["out"]["diagnostics"]]
        depth_messages = [item["message"] for item in outputs["depth.dsl"]["out"]["diagnostics"]]
        self.assertTrue(any("cycle" in message.lower() for message in cycle_messages), cycle_messages)
        self.assertTrue(any("maximum depth of 8" in message for message in depth_messages), depth_messages)


if __name__ == "__main__":
    unittest.main()
