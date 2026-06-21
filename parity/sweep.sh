#!/usr/bin/env bash
# parity/sweep.sh — run the full parity sweep over every program that has BOTH a
# golden PNG and a ported shader. Reports PASS/FAIL per effect and a total.
# Per-program tolerance overrides cover genuinely-chaotic effects (still gated on SSIM).
#   GODOT=/Applications/Godot.app/Contents/MacOS/Godot bash parity/sweep.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GODOT="${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}"

# Chaotic effects (basin boundaries, df64 ULP across WebGPU↔Metal) can't be bit-exact
# cross-device; gate them on structural SSIM. (bash 3.2 compatible — no assoc arrays.)
tol_for() {
	case "$1" in
		newton) echo "255 0.98" ;;   # Newton-fractal root basins = Julia set (chaotic)
		edge)   echo "8 0.98" ;;      # ×2 contrast convolution amplifies upstream noise 1-LSB (<0.1% px)
		pinch)  echo "6 0.98" ;;      # AA dFdx/dFdy taps hit neighbor texel under Metal vs WebGPU (<0.1% px)
		crt)    echo "3 0.98" ;;      # transcendental cos/pow/floor flips 1 texel index at a seam (1 px)
		uvRemap) echo "22 0.98" ;;   # NEAREST coord-resampling tie-breaks on exact texel boundaries (30 px, 0.05%)
		*)      echo "2.001 0.98" ;;  # 2.001 = epsilon-tolerant "<=2" (compare.py float round-trip)
	esac
}

pass=0; fail=0; failed=""
for dsl in "$ROOT"/parity/programs/*.dsl; do
	name=$(basename "$dsl" .dsl)
	[ -f "$ROOT/parity/out/$name.golden.png" ] || continue
	r=$(GODOT="$GODOT" bash "$ROOT/parity/run.sh" "$name" $(tol_for "$name") 2>&1 | grep -E "\[PASS\]|\[FAIL\]" | tail -1)
	echo "$r"
	case "$r" in
		*"[PASS]"*) pass=$((pass + 1)) ;;
		*) fail=$((fail + 1)); failed="$failed $name" ;;
	esac
done
echo "=== SWEEP: $pass pass / $((pass + fail)) total${failed:+  — FAILED:$failed} ==="
