#!/usr/bin/env bash
# Open-source Spartan-7 flow: yosys -> nextpnr-himbaechel (xilinx) -> prjxray.
set -euo pipefail
cd "$(dirname "$0")"
X="${OPENXC7:-$HOME/Documents/Libs/openxc7}"
OSS="${OSS_CAD_SUITE:-$HOME/Documents/Libs/oss-cad-suite}"
PART=xc7s50csga324-1
DB="$X/nextpnr-xilinx/xilinx/external/prjxray-db"
mkdir -p build
"$OSS/bin/yosys" -q -l build/yosys.log -p "synth_xilinx -flatten -abc9 -nobram -arch xc7 -top top; write_json build/top.json" top.v
"$X/nextpnr/build/nextpnr-himbaechel" --device $PART -o xdc=arty-s7-50.xdc --json build/top.json \
  -o fasm=build/top.fasm --router router2 --log build/nextpnr.log
PYTHONPATH="$X/prjxray" "$X/venv/bin/python" -W ignore "$X/prjxray/utils/fasm2frames.py" \
  --part $PART --db-root "$DB/spartan7" build/top.fasm build/top.frames
"$X/prjxray/build/tools/xc7frames2bit" --part_file "$DB/spartan7/$PART/part.yaml" --part_name $PART \
  --frm_file build/top.frames --output_file build/top.bit
ls -la build/top.bit
