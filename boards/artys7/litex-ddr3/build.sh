#!/usr/bin/env bash
# LiteX SoC with DDR3 on the Arty S7-50, open-source flow.
#   1. LiteX generates the SoC Verilog, constraints and BIOS (--no-compile-gateware)
#   2. yosys -> nextpnr-himbaechel (xilinx) -> Project X-Ray, as ../blink-echo
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
X="${OPENXC7:-$HOME/Documents/Libs/openxc7}"
OSS="${OSS_CAD_SUITE:-$HOME/Documents/Libs/oss-cad-suite}"
LITEX="${LITEX:-$HOME/Documents/Libs/litex}"
PART=xc7s50csga324-1
export PATH="$LITEX/venv/bin:$PATH"   # LiteX runs meson and ninja for the BIOS
DB="$X/nextpnr-xilinx/xilinx/external/prjxray-db"
SYS_MHZ="${SYS_MHZ:-100}"     # system clock; the DDR3 runs at 8 x SYS_MHZ MT/s
out="build-${SYS_MHZ}mhz"
cd "$here"
if [[ "${SKIP_GENERATE:-0}" != 1 ]]; then
  mkdir -p "$out"
  "$LITEX/venv/bin/python3" -m litex_boards.targets.digilent_arty_s7 --variant s7-50 --cpu-type vexriscv \
    --sys-clk-freq "${SYS_MHZ}e6" --output-dir "$out" --build --no-compile-gateware > "$out/gen.log" 2>&1
fi
cd "$out/gateware"
sources=$(grep -oE 'read_verilog \{[^}]*\}' digilent_arty_s7.tcl | sed -E 's/read_verilog \{(.*)\}/\1/' | tr '\n' ' ')
"$OSS/bin/yosys" -q -l yosys.log -p "read_verilog $sources; synth_xilinx -flatten -abc9 -arch xc7 -top digilent_arty_s7; write_json top.json"
"$X/nextpnr/build/nextpnr-himbaechel" --device $PART -o xdc=digilent_arty_s7.xdc --json top.json \
  -o fasm=top.fasm --router router2 --log nextpnr.log > /dev/null
grep 'Max frequency' nextpnr.log | tail -6
PYTHONPATH="$X/prjxray" "$X/venv/bin/python" -W ignore "$X/prjxray/utils/fasm2frames.py" \
  --part $PART --db-root "$DB/spartan7" top.fasm top.frames
"$X/prjxray/build/tools/xc7frames2bit" --part_file "$DB/spartan7/$PART/part.yaml" --part_name $PART \
  --frm_file top.frames --output_file top.bit
echo "Bitstream: $PWD/top.bit"
