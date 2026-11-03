#!/usr/bin/env bash
# Build and run the 81/84/87/90 MHz E2->D + cache-flattened + D.fPc-cut images on the connected Tang Nano 20K.
set -euo pipefail
cd "$(dirname "$0")/../../.."
ROOT="$PWD"
LOADER="${OPENFPGALOADER:-/Users/jasonqin/Documents/Libs/oss-cad-suite/bin/openFPGALoader}"
PORT="${PORT:-/dev/cu.usbserial-20250303171}"
RTL="$ROOT/output/tangnano20k/sdram-generated/SdramPipeline-1/SdramPipeline.topEntity/sdram_pipeline_risc.v"
OUT_BASE="$ROOT/output/tangnano20k/cpu-84-90-board-20261103"
mkdir -p "$OUT_BASE"

for cpu in ${CPUS:-81 84 87 90}; do
  echo "=== Sweeping CPU=${cpu} MHz / SDRAM=48 MHz ==="
  SDRAM_RTL_FILE="$RTL" SDRAM_MAP_OPTION=3 SDRAM_ROUTE_OPTION=1 SDRAM_ROUTE_MAXFAN=8 \
    python3 boards/tangnano20k/sdram/sweep_place.py \
      --base-freq-mhz "$cpu" --memory-freq-mhz 48 --rvc --cache-ways 2 \
      --placements "${PLACEMENTS:-1,2,3}" --jobs 1 \
      --out "$OUT_BASE/cpu${cpu}-sweep" || true

  best_fs="$(python3 - "$OUT_BASE/cpu${cpu}-sweep/sweep-results.json" <<'PY'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1])
if not p.is_file():
    sys.exit(0)
data = json.loads(p.read_text())
passing = [r for r in data.get("placements", []) if r.get("passed")]
if not passing:
    sys.exit(0)
best = max(passing, key=lambda r: (r.get("worst_setup_slack_ns", -999), r.get("fmax_mhz", 0)))
fs = pathlib.Path(best["out"]) / "impl/pnr/sdram_test.fs"
if fs.is_file():
    print(f"{best['placement']}:{best.get('fmax_mhz')}:{best.get('worst_setup_slack_ns')}:{fs}")
PY
)"
  if [[ -z "$best_fs" ]]; then
    echo "CPU ${cpu} MHz: no placement passed STA gate; stopping frequency climb."
    continue
  fi
  place="${best_fs%%:*}"; rest="${best_fs#*:}"
  fmax="${rest%%:*}"; rest="${rest#*:}"
  slack="${rest%%:*}"; fs_path="${rest#*:}"
  echo "=== Programming CPU=${cpu} MHz (place=${place}, Fmax=${fmax} MHz, slack=${slack} ns) ==="
  "$LOADER" -b tangnano20k "$fs_path"
  python3 boards/tangnano20k/run_program.py --port "$PORT" --freq-mhz "$cpu" --identify | tee "$OUT_BASE/cpu${cpu}-identify.log"
  python3 boards/tangnano20k/check_processor.py --port "$PORT" --clock "$((cpu * 1000000))" --ram-base 0x80000000 | tee "$OUT_BASE/cpu${cpu}-processor.log"
  python3 boards/tangnano20k/check_rv32m.py --port "$PORT" --clock "$((cpu * 1000000))" --ram-base 0x80000000 | tee "$OUT_BASE/cpu${cpu}-rv32m.log"
  python3 boards/tangnano20k/check_rv32i.py --port "$PORT" --clock "$((cpu * 1000000))" --ram-base 0x80000000 | tee "$OUT_BASE/cpu${cpu}-rv32i.log"
done
