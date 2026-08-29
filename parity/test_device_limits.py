#!/usr/bin/env python3
"""Live RenderingDevice coverage for texture and MRT limit handling."""

import os
import subprocess
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]
GODOT = Path(os.environ.get("GODOT", "/Applications/Godot.app/Contents/MacOS/Godot"))
PROBE = REPO / "parity" / "device_limits_probe.gd"


@unittest.skipUnless(GODOT.exists(), f"Godot binary not found: {GODOT}")
class DeviceLimitTests(unittest.TestCase):
    def test_device_limits_are_probed_and_applied_to_a_live_mrt_render(self):
        result = subprocess.run(
            [
                str(GODOT),
                "--path",
                str(REPO / "godot"),
                "--script",
                str(PROBE),
                "--position",
                "5000,5000",
            ],
            capture_output=True,
            text=True,
            timeout=60,
        )

        output = result.stdout + result.stderr
        self.assertEqual(result.returncode, 0, output)
        self.assertIn("DEVICE_LIMITS_TEST: PASS", output, output)
        self.assertNotIn("ERROR:", output, output)
        self.assertNotIn("SCRIPT ERROR", output, output)


if __name__ == "__main__":
    unittest.main()
