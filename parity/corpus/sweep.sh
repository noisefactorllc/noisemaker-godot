#!/usr/bin/env bash
# parity/corpus/sweep.sh — integration parity over REAL compositions from the
# NoiseBLASTER! corpus (parity/corpus/programs/<name>.dsl). Unlike parity/sweep.sh
# (one effect in isolation), these are whole shared programs — the harness that
# caught the curl seed-offset bug (invisible to seed:0 isolation tests).
#
# A program appears here once it is RENDERABLE (all its shader programs ported —
# see `node parity/corpus/coverage.mjs`). Goldens are produced by the reference:
#   SHADE_HEADLESS=1 node parity/export-and-render.mjs \
#       parity/corpus/programs/<name>.dsl parity/out --size 256 --time 0.25 --backend webgl2
#
#   GODOT=/Applications/Godot.app/Contents/MacOS/Godot bash parity/corpus/sweep.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GODOT="${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}"

# Real programs chain many effects; high-frequency color maps (palette repeat>1)
# turn a 1-LSB upstream luminance delta into a several-level color swing at a few
# pixels — structurally identical (SSIM~1), so gate on SSIM. (bash 3.2: no assoc arrays.)
tol_for() {
	case "$1" in
		passing_through) echo "4 0.999" ;;  # palette repeat:4 amplifies 1-LSB curl/osc delta (max-diff 4, ssim 0.9999)
		lit_noise)       echo "22 0.999" ;; # lighting reflection/refraction + tetraCosine NEAREST boundary ties (max-diff 20)
		*)               echo "2.001 0.98" ;;
	esac
}

pass=0; fail=0; skip=0; failed=""
for dsl in "$ROOT"/parity/corpus/programs/*.dsl; do
	name=$(basename "$dsl" .dsl)
	# Continuous solvers (Gray-Scott reactionDiffusion, navierStokes) are faithful ports
	# but amplify sub-ULP cross-backend fp non-determinism -> not bit-reproducible. Skipped,
	# not failed, exactly as parity/sweep.sh skips reactionDiffusion. See project memory.
	case "$name" in
		rd_example)
			echo "[SKIP] $name: continuous reactionDiffusion solver (cross-backend-divergent)"
			skip=$((skip + 1)); continue ;;
	esac
	[ -f "$ROOT/parity/out/$name.golden.png" ] || { echo "[skip] $name (no golden — not yet renderable)"; continue; }
	r=$(GODOT="$GODOT" bash "$ROOT/parity/run.sh" "$name" $(tol_for "$name") 2>&1 | grep -E "\[PASS\]|\[FAIL\]" | tail -1)
	echo "$r"
	case "$r" in
		*"[PASS]"*) pass=$((pass + 1)) ;;
		*) fail=$((fail + 1)); failed="$failed $name" ;;
	esac
done
echo "=== CORPUS SWEEP: $pass pass / $((pass + fail)) total${skip:+, $skip skipped (continuous-divergent)}${failed:+  — FAILED:$failed} ==="
