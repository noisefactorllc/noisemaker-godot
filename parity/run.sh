#!/usr/bin/env bash
# parity/run.sh <name> [tolerance] [ssim_min] [size]
#
# Render the Godot candidate for a Tier-1 program and compare it against the
# existing golden. Goldens + graph JSON are produced by the reference harness
# (parity/export-and-render.mjs) into parity/out/ — see parity/README.md.
#
# RenderingDevice is null under --headless, so the Godot runner is launched
# NON-headless with the window positioned offscreen (--position 5000,5000).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NAME="${1:?usage: run.sh <name> [tol] [ssim_min] [size]}"
# Default 2.001 (not 2): compare.py computes max-abs-diff as float ((x-y)/255*255),
# so a TRUE 8-bit diff of 2 reports ~2.0000035 and would false-fail a strict "<=2".
# 2.001 accepts true diffs <=2 and still rejects >=3.
TOL="${2:-2.001}"
SSIM="${3:-0.98}"
SIZE="${4:-256}"
GODOT="${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}"
PY="$ROOT/parity/.venv/bin/python"
GRAPH="$ROOT/parity/out/$NAME.graph.json"
GOLD="$ROOT/parity/out/$NAME.golden.png"
CAND="$ROOT/parity/out/$NAME.candidate.png"

[ -f "$GRAPH" ] || { echo "missing graph: $GRAPH (run: node tools/export-graph.mjs --file parity/programs/$NAME.dsl $GRAPH)"; exit 2; }
[ -f "$GOLD" ]  || { echo "missing golden: $GOLD (run the reference harness)"; exit 2; }

"$GODOT" --path "$ROOT/godot" --script res://addons/noisemaker/tools/render_graph.gd \
	--position 5000,5000 -- --graph "$GRAPH" --out "$CAND" --size "$SIZE" 2>&1 \
	| grep -E "NM_RENDERED|RD_NULL|SCRIPT ERROR|shader |missing|error" || true

"$PY" "$ROOT/parity/compare.py" "$GOLD" "$CAND" \
	--name "$NAME" --tolerance "$TOL" --ssim-min "$SSIM" \
	--report "$ROOT/parity/out/$NAME.report.json"
