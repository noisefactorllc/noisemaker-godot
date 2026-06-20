#!/usr/bin/env bash
# parity/sweep.sh — run the full parity sweep over every program that has BOTH a
# golden PNG and a ported shader. Reports PASS/FAIL per effect and a total.
# Per-program tolerance overrides cover genuinely-chaotic effects (still gated on SSIM).
# Invoke with bash (the per-program map uses bash assoc arrays):
#   GODOT=/Applications/Godot.app/Contents/MacOS/Godot bash parity/sweep.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GODOT="${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}"

# name -> "tolerance ssim_min". Chaotic effects (basin boundaries, df64 ULP across
# WebGPU↔Metal) can't be bit-exact cross-device; gate them on structural SSIM.
declare -A TOL
TOL[newton]="255 0.98"   # Newton-fractal root basins = Julia set (chaotic boundary)

pass=0; fail=0; failed=""
for dsl in "$ROOT"/parity/programs/*.dsl; do
	name=$(basename "$dsl" .dsl)
	[ -f "$ROOT/parity/out/$name.golden.png" ] || continue
	args="${TOL[$name]:-2 0.98}"
	r=$(GODOT="$GODOT" bash "$ROOT/parity/run.sh" "$name" $args 2>&1 | grep -E "\[PASS\]|\[FAIL\]" | tail -1)
	echo "$r"
	if [[ "$r" == *"[PASS]"* ]]; then
		pass=$((pass + 1))
	else
		fail=$((fail + 1)); failed="$failed $name"
	fi
done
echo "=== SWEEP: $pass pass / $((pass + fail)) total${failed:+  — FAILED:$failed} ==="
