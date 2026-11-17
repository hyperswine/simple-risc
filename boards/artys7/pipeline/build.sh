#!/usr/bin/env bash
# simple-risc's SDRAM-pipeline core with DDR3 on the Arty S7-50.
#   CPU_MHZ  CPU clock (default 81, the canon); 12 * MULT / DIVIDE, VCO 600-1200
#   RVC      1 for RV32IMC (default 0: RV32IM, as fprisc-81)
# Needs ../litedram/build (run ../litedram/build.sh once).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../../.." && pwd)"
X="${OPENXC7:-$HOME/Documents/Libs/openxc7}"
OSS="${OSS_CAD_SUITE:-$HOME/Documents/Libs/oss-cad-suite}"
PART=xc7s50csga324-1
DB="$X/nextpnr-xilinx/xilinx/external/prjxray-db"
cpu="${CPU_MHZ:-81}"; mem=80; rvc="${RVC:-0}"
dram="$here/../litedram/build/gateware"
[[ -f "$dram/litedram_core.v" ]] || { echo "run ../litedram/build.sh first" >&2; exit 1; }
read -r mult divide < <(python3 - "$cpu" <<'PY'
import sys
f = float(sys.argv[1])
for mult in range(63, 1, -1):
    vco = 12 * mult
    if 600 <= vco <= 1200 and abs(vco / f - round(vco / f)) < 1e-9 and 1 <= vco / f <= 128:
        print(mult, round(vco / f)); break
else:
    sys.exit(f'no MMCM setting gives {f} MHz from 12 MHz')
PY
)
out="$root/output/artys7/pipeline-${cpu}"
mkdir -p "$out"
echo "CPU $cpu MHz (x$mult / $divide), memory $mem MHz, RVC=$rvc, UART $(python3 -c "print(round($cpu*1e6/868))") baud"
cd "$root"
options=(-isrc -hide-package simple-risc); [[ "$rvc" == 1 ]] && options+=(-DRISCV_COMPRESSED)
cabal run -v0 clash -- "${options[@]}" src/SdramPipeline.hs --verilog -fclash-clear -outputdir "$out/clash" > "$out/clash.log" 2>&1
rtl="$out/clash/SdramPipeline.topEntity/sdram_pipeline_risc.v"
# Boot ROM: 508 code words, then CPU MHz, memory MHz and a build id (as the
# Tang Nano's sdram/build.sh stamps it; the loader reports these).
python3 - "$root/boards/tangnano20k/bootrom/bootrom-sdram.hex" "$out/bootrom-sdram.hex" "$cpu" "$mem" "$rtl" <<'PY'
import hashlib, sys
from pathlib import Path
words = Path(sys.argv[1]).read_text().splitlines()[:508]
assert len(words) == 508
build = hashlib.sha256(('\n'.join(words) + ':arty-s7:' + sys.argv[3] + ':' + sys.argv[4] + ':' +
                        hashlib.sha256(Path(sys.argv[5]).read_bytes()).hexdigest()).encode()).hexdigest()[:16]
Path(sys.argv[2]).write_text('\n'.join(words + [f'{int(sys.argv[3]):08x}', f'{int(sys.argv[4]):08x}', build[:8], build[8:]]) + '\n')
PY
vex=$(grep -oE 'read_verilog \{[^}]*VexRiscv[^}]*\}' "$dram/litedram_core.tcl" | sed -E 's/read_verilog \{(.*)\}/\1/')
sd="$root/boards/tangnano20k/sdram"
cd "$dram"
# The top's parameter defaults carry this build's clock and stamped ROM path
# (yosys cannot pass a path string through chparam); -defer elaborates the
# cache only once the top hands it that path.
sed -e "s|parameter integer MULT   = 54|parameter integer MULT   = $mult|" \
    -e "s|parameter integer DIVIDE = 8|parameter integer DIVIDE = $divide|" \
    -e "s|parameter ROM_FILE = \"bootrom-sdram.hex\"|parameter ROM_FILE = \"$out/bootrom-sdram.hex\"|" \
    "$here/top.v" > "$out/top.v"
grep -q "$out/bootrom-sdram.hex" "$out/top.v" || { echo "ROM path not substituted" >&2; exit 1; }
# -nosrl: yosys maps some of the core's pipeline registers (Clash resets them
# to partly-x values) into SRL16E shift registers that do not match the RTL; a
# gate-level simulation of the core reproduced the board failure, -nosrl fixed it.
"$OSS/bin/yosys" -q -l "$out/yosys.log" -p "read_verilog -defer $vex litedram_core.v $rtl $sd/pipeline_cache.v $sd/clock_bridge.v $here/ddr3_line_memory.v; read_verilog -defer -sv $out/top.v; hierarchy -top top; synth_xilinx -flatten -abc9 -arch xc7 -nosrl -top top; write_json $out/top.json"
"$X/nextpnr/build/nextpnr-himbaechel" --device $PART -o xdc="$here/arty-s7-50.xdc" --json "$out/top.json" \
  -o fasm="$out/top.fasm" --router router2 --log "$out/nextpnr.log" > /dev/null || true
grep 'Max frequency' "$out/nextpnr.log" | tail -4
[[ -s "$out/top.fasm" ]] || { echo "no FASM; see $out/nextpnr.log" >&2; exit 1; }
PYTHONPATH="$X/prjxray" "$X/venv/bin/python" -W ignore "$X/prjxray/utils/fasm2frames.py" \
  --part $PART --db-root "$DB/spartan7" "$out/top.fasm" "$out/top.frames"
"$X/prjxray/build/tools/xc7frames2bit" --part_file "$DB/spartan7/$PART/part.yaml" --part_name $PART \
  --frm_file "$out/top.frames" --output_file "$out/top.bit"
echo "Bitstream: $out/top.bit"
# build-manifest.json for FP-RISC's board runner (machine/tangnano20k/examples.sol
# --preset arty-s7-81): the configuration, the ROM identity the loader will
# report, and hashes of the bitstream and the timing log. ready only when
# nextpnr met timing on both clocks.
python3 - "$out" "$cpu" "$mem" "$rvc" <<'PY'
import hashlib, json, re, sys
from pathlib import Path
out, cpu, mem, rvc = Path(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3]), sys.argv[4] == '1'
log = (out / 'nextpnr.log').read_text()
def passed(clock):
    found = re.findall(rf"Max frequency for clock +'{clock}': [0-9.]+ MHz \((PASS|FAIL) at", log)
    return bool(found) and found[-1] == 'PASS'
words = (out / 'bootrom-sdram.hex').read_text().split()
manifest = {
    'preset': f'arty-s7-{cpu}' + ('-imc' if rvc else ''),
    'board': 'arty-s7-50',
    'configuration': {'xlen': 32, 'compressed': rvc, 'cpu_mhz': cpu, 'memory_mhz': mem,
                      'ram_bytes': 8388608, 'cache_bytes': 65536, 'cache_ways': 2, 'cache_line_bits': 11,
                      'memory': 'ddr3-litedram', 'synthesis': 'yosys-nosrl'},
    'rom_identity': {'protocol': 'SRID1', 'isa': 'rv32imc' if rvc else 'rv32im', 'cpu_mhz': cpu,
                     'mem_mhz': mem, 'build_id': words[510] + words[511]},
    'ready': passed('clk') and passed('clk_memory'),
    'qualification': 'nextpnr STA only (openXC7); DDR3 calibrated by LiteDRAM at boot',
    'artifacts': {name: hashlib.sha256((out / name).read_bytes()).hexdigest()
                  for name in ('top.bit', 'nextpnr.log', 'bootrom-sdram.hex')},
}
(out / 'build-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
print(f"Manifest: {out / 'build-manifest.json'} (ready={manifest['ready']})")
PY
