#!/usr/bin/env bash
# The SimpleRisc block-RAM core on the Arty S7-50, open-source flow:
# Clash -> yosys -> nextpnr-himbaechel (xilinx) -> Project X-Ray.
#
#   FREQ_MHZ  core clock (default 54); 12 * MULT / DIVIDE with the VCO in
#             600-1200 MHz. The UART runs at FREQ_MHZ * 1e6 / 868 baud.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../../.." && pwd)"
X="${OPENXC7:-$HOME/Documents/Libs/openxc7}"
OSS="${OSS_CAD_SUITE:-$HOME/Documents/Libs/oss-cad-suite}"
PART=xc7s50csga324-1
DB="$X/nextpnr-xilinx/xilinx/external/prjxray-db"
freq="${FREQ_MHZ:-54}"
read -r mult divide < <(python3 - "$freq" <<'PY'
import sys
f = float(sys.argv[1])
for mult in range(63, 1, -1):    # prefer a high VCO; nextpnr takes 1..63
    vco = 12 * mult
    if 600 <= vco <= 1200:
        d = vco / f
        if abs(d - round(d)) < 1e-9 and 1 <= d <= 128:
            print(mult, round(d)); break
else:
    sys.exit(f'no MMCM setting gives {f} MHz from 12 MHz')
PY
)
out="$root/output/artys7/core-${freq}"
mkdir -p "$out"
echo "core clock $freq MHz (MULT $mult, DIVIDE $divide, VCO $((12 * mult)) MHz), UART $(python3 -c "print(round($freq*1e6/868))") baud"
cd "$root"
cabal run -v0 clash -- -isrc -hide-package simple-risc src/SimpleRisc.hs --verilog -outputdir "$out/clash"
core="$(ls "$out"/clash/SimpleRisc.topEntity/*.v | tr '\n' ' ')"
"$OSS/bin/yosys" -q -l "$out/yosys.log" -p \
  "read_verilog ${core}; read_verilog -sv $here/top.v; chparam -set MULT $mult -set DIVIDE $divide top; synth_xilinx -flatten -abc9 -arch xc7 -top top; write_json $out/top.json"
"$X/nextpnr/build/nextpnr-himbaechel" --device $PART -o xdc="$here/arty-s7-50.xdc" --json "$out/top.json" \
  -o fasm="$out/top.fasm" --router router2 --freq "$freq" --log "$out/nextpnr.log" > /dev/null
grep 'Max frequency' "$out/nextpnr.log" | tail -1
PYTHONPATH="$X/prjxray" "$X/venv/bin/python" -W ignore "$X/prjxray/utils/fasm2frames.py" \
  --part $PART --db-root "$DB/spartan7" "$out/top.fasm" "$out/top.frames"
"$X/prjxray/build/tools/xc7frames2bit" --part_file "$DB/spartan7/$PART/part.yaml" --part_name $PART \
  --frm_file "$out/top.frames" --output_file "$out/top.bit"
echo "Bitstream: $out/top.bit"
