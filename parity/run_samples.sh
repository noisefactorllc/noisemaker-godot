#!/usr/bin/env bash
# parity/run_samples.sh <name> [tol] [ssim_min] [run_seconds] [sample_every] [size]
#
# STATEFUL-SIM parity (reference 30s/5s sampling, per user guidance): render the Godot
# candidate as a TIMED SERIES (run_seconds of sim-time, captured every sample_every)
# and compare each timestep against the matching golden sample. Unlike parity/run.sh
# (single pinned frame, which freezes fluid/feedback sims at the seed), this evolves the
# sim to a developed state — the meaningful parity test for navierStokes & friends.
#
# Goldens + graph must pre-exist in parity/out/ (produced by the reference harness):
#   SHADE_HEADLESS=1 node parity/export-and-render.mjs parity/programs/<name>.dsl \
#       parity/out --size 256 --backend webgl2 --run-seconds 30 --sample-every 5
#
#   GODOT=/Applications/Godot.app/Contents/MacOS/Godot bash parity/run_samples.sh <name>
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NAME="${1:?usage: run_samples.sh <name> [tol] [ssim] [run_seconds] [sample_every] [size]}"
TOL="${2:-10}"
SSIM="${3:-0.998}"
RUN="${4:-30}"
EVERY="${5:-5}"
SIZE="${6:-256}"
GODOT="${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}"
PY="$ROOT/parity/.venv/bin/python"
GRAPH="$ROOT/parity/out/$NAME.graph.json"
[ -f "$GRAPH" ] || { echo "missing graph: $GRAPH (run export-and-render.mjs first)"; exit 2; }

"$GODOT" --path "$ROOT/godot" --script res://addons/noisemaker/tools/render_graph.gd \
	--position 5000,5000 -- --graph "$GRAPH" --out "$ROOT/parity/out/$NAME.candidate.png" \
	--size "$SIZE" --run-seconds "$RUN" --sample-every "$EVERY" 2>&1 \
	| grep -E "NM_SAMPLE|RD_NULL|SCRIPT ERROR|shader |error" || true

pass=0; total=0
t=$EVERY
while [ "$t" -le "$RUN" ]; do
	g="$ROOT/parity/out/$NAME.golden.t$t.png"
	c="$ROOT/parity/out/$NAME.candidate.t$t.png"
	if [ -f "$g" ] && [ -f "$c" ]; then
		total=$((total + 1))
		r=$("$PY" "$ROOT/parity/compare.py" "$g" "$c" --name "${NAME}_t$t" \
			--tolerance "$TOL" --ssim-min "$SSIM" 2>&1 | grep -E "\[PASS\]|\[FAIL\]" | tail -1)
		echo "$r"
		case "$r" in *"[PASS]"*) pass=$((pass + 1)) ;; esac
	fi
	t=$((t + EVERY))
done
echo "=== SAMPLES: $NAME $pass/$total pass (tol=$TOL ssim>=$SSIM, ${RUN}s every ${EVERY}s) ==="
[ "$pass" -eq "$total" ] && [ "$total" -gt 0 ]
