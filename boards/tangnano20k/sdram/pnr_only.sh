#!/usr/bin/env bash
# Place and route an already synthesized build again, with extra physical
# constraints. The netlist, pins, clocks and options come from SOURCE (a
# build.sh output directory), so two runs differ only in what is appended to
# pins.cst and in the placement option: a placement experiment on one netlist.
#
#   pnr_only.sh SOURCE OUT [REGION.cst]
#
# PNR_PLACE_OPTION overrides the source's placement option; PNR_POSP=1 also
# writes the post-place file (block RAM and DSP sites, in constraint syntax).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
ide="/Applications/GowinIDE.app/Contents/Resources/Gowin_EDA/IDE"
[[ $# -ge 2 ]] || { echo "usage: pnr_only.sh SOURCE OUT [REGION.cst]" >&2; exit 1; }
src="$(cd "$1" && pwd)"; mkdir -p "$2"; out="$(cd "$2" && pwd)"; region="${3:-}"
netlist="$src/impl/gwsynthesis/sdram_test.vg"
[[ -f "$netlist" ]] || { echo "no synthesized netlist in $src" >&2; exit 1; }
cp "$src/pins.cst" "$src/clocks.sdc" "$out/"
if [[ -n "$region" ]]; then
  [[ -f "$region" ]] || { echo "region file does not exist: $region" >&2; exit 1; }
  printf '\n' >> "$out/pins.cst"; cat "$region" >> "$out/pins.cst"
fi
{
  grep -E '^set_device|^set_option' "$src/build.tcl" \
    | grep -v -e '-top_module' -e '-gen_verilog_sim_netlist' -e '-num_critical_paths' ${PNR_PLACE_OPTION:+-e -place_option}
  [[ -n "${PNR_PLACE_OPTION:-}" ]] && echo "set_option -place_option $PNR_PLACE_OPTION"
  [[ "${PNR_POSP:-0}" == 1 ]] && echo 'set_option -gen_posp 1'
  echo "set_option -num_critical_paths ${PNR_REPORT_PATHS:-20}"
  echo "add_file -type netlist \"$netlist\""
  echo "add_file \"$out/pins.cst\""
  echo "add_file \"$out/clocks.sdc\""
  echo 'run pnr'
  echo 'exit'
} > "$out/build.tcl"
export DYLD_LIBRARY_PATH="$ide/lib"
export DYLD_FRAMEWORK_PATH="$ide/lib"
cd "$out"
rm -f impl/pnr/sdram_test.tr
# A region that is too full leaves the router searching for a very long time
# (the canon routes in three minutes): give up after PNR_TIMEOUT seconds.
limit="${PNR_TIMEOUT:-1500}"
for attempt in 1 2 3 4 5; do
  "$ide/bin/gw_sh" build.tcl > pnr.log 2>&1 &
  job=$!; start=$SECONDS
  while kill -0 "$job" 2>/dev/null; do
    if (( SECONDS - start > limit )); then
      kill "$job" 2>/dev/null; pkill -P "$job" 2>/dev/null || true
      echo "TIMEOUT: place and route not finished after $limit s ($(grep -E '^\[[0-9]+%\]' pnr.log | tail -1))"; exit 2
    fi
    sleep 5
  done
  wait "$job" && break
  grep -q 'License verification failed' pnr.log || { tail -5 pnr.log >&2; exit 1; }
  sleep 20
done
read -r cpu mem < <(python3 - <<'PYTHON'
import re
text = open('clocks.sdc').read()
def mhz(name):
    m = re.search(r'-name ' + name + r' .*?-multiply_by (\d+) -divide_by (\d+)', text)
    return round(27 * int(m.group(1)) / int(m.group(2))) if m else ''
print(mhz('clk_core'), mhz('clk_memory'))
PYTHON
)
args=(--freq-mhz "$cpu")
[[ -n "$mem" && "$mem" != "$cpu" ]] && args+=(--memory-freq-mhz "$mem")
python3 "$here/../check_gowin_timing.py" impl/pnr/sdram_test.tr "${args[@]}"
