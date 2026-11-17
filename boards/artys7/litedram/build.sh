#!/usr/bin/env bash
# Standalone LiteDRAM core + native-port self-test on the Arty S7-50.
#   1. litedram_gen arty_s7.yml -> build/gateware/litedram_core.v (+ BIOS ROM)
#   2. yosys -> nextpnr-himbaechel (xilinx) -> Project X-Ray
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
X="${OPENXC7:-$HOME/Documents/Libs/openxc7}"
OSS="${OSS_CAD_SUITE:-$HOME/Documents/Libs/oss-cad-suite}"
LITEX="${LITEX:-$HOME/Documents/Libs/litex}"
PART=xc7s50csga324-1
DB="$X/nextpnr-xilinx/xilinx/external/prjxray-db"
export PATH="$LITEX/venv/bin:$PATH"
cd "$here"
if [[ "${SKIP_GENERATE:-0}" != 1 ]]; then
  litedram_gen arty_s7.yml --name litedram_core --output-dir build --no-compile-gateware > build/gen.log 2>&1
fi
cd build/gateware
top="${TOP:-top}"   # top.v (sequential native test) or top_rand.v (random adapter test)
vex=$(grep -oE 'read_verilog \{[^}]*VexRiscv[^}]*\}' litedram_core.tcl | sed -E 's/read_verilog \{(.*)\}/\1/')
"$OSS/bin/yosys" -q -l $top-test-yosys.log -p "read_verilog $vex litedram_core.v; read_verilog -sv $here/../pipeline/ddr3_line_memory.v $here/$top.v; synth_xilinx -flatten -abc9 -arch xc7 -top top; write_json $top-test.json"
"$X/nextpnr/build/nextpnr-himbaechel" --device $PART -o xdc="$here/arty-s7-50-ddr3.xdc" --json $top-test.json \
  -o fasm=$top-test.fasm --router router2 --log $top-test-nextpnr.log > /dev/null
grep 'Max frequency' $top-test-nextpnr.log | tail -4
PYTHONPATH="$X/prjxray" "$X/venv/bin/python" -W ignore "$X/prjxray/utils/fasm2frames.py" \
  --part $PART --db-root "$DB/spartan7" $top-test.fasm $top-test.frames
"$X/prjxray/build/tools/xc7frames2bit" --part_file "$DB/spartan7/$PART/part.yaml" --part_name $PART \
  --frm_file $top-test.frames --output_file $top-test.bit
echo "Bitstream: $PWD/$top-test.bit"
