#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../../.." && pwd)"
source "$here/preset.sh"
mode="${1:-test}"
if [[ -n "${SDRAM_PRESET:-}" ]]; then
  mode="${1:-pipeline}"
  [[ "$mode" == pipeline ]] || { echo 'fprisc-48 requires pipeline mode' >&2; exit 1; }
fi
freq="${SDRAM_FREQ_MHZ:-54}"
cpu_freq="${SDRAM_CPU_FREQ_MHZ:-$freq}"
# The placer/optimizer target. Set this above cpu_freq (typically ~10% high)
# to over-constrain placement; the SDC still constrains the real clocks.
target="${SDRAM_TARGET_MHZ:-$cpu_freq}"
cache="${SDRAM_CACHE:-1}"
rvc="${SDRAM_RVC:-0}"
cache_ways="${SDRAM_CACHE_WAYS:-2}"
case "$cache_ways" in 1|2) ;; *) echo "SDRAM_CACHE_WAYS must be 1 or 2" >&2;exit 1;; esac
# Pipeline cache size: 2^(bits+4) bytes per way (default 64 KiB total: 11 bits
# per way for 2-way, 12 bits for 1-way; 7 = 2 KiB per way).
default_line_bits=12
if [[ "$cache_ways" == 2 ]];then default_line_bits=11;fi
cache_line_bits="${SDRAM_CACHE_LINE_BITS:-$default_line_bits}"
placement="${SDRAM_PLACE_OPTION:-2}"
case "$placement" in 0|1|2|3|4) ;; *) echo "SDRAM_PLACE_OPTION must be 0 through 4" >&2;exit 1;; esac
# Synthesis and routing knobs. All are unset by default, which leaves the
# stock flow: 1/1/0/1000/23 below are the tool defaults.
map_option="${SDRAM_MAP_OPTION:-}"       # 1 default, 3/4 LUT5-oriented for timing
route_option="${SDRAM_ROUTE_OPTION:-}"   # 0 default, 1 spends compile time on routing
replicate="${SDRAM_REPLICATE:-}"         # 1 replicates high-fanout resources (Arora V/III only)
max_fanout="${SDRAM_MAX_FANOUT:-}"       # global syn_maxfan, default 1000
route_maxfan="${SDRAM_ROUTE_MAXFAN:-}"   # routing-tree fanout, default 23
for pair in "SDRAM_MAP_OPTION:1:2:3:4" "SDRAM_ROUTE_OPTION:0:1:2" "SDRAM_REPLICATE:0:1"; do
  name="${pair%%:*}"; allowed=":${pair#*:}:"
  value="${!name:-}"
  [[ -z "$value" || "$allowed" == *":$value:"* ]] || { echo "$name must be one of ${pair#*:}" >&2; exit 1; }
done
for name in SDRAM_MAX_FANOUT SDRAM_ROUTE_MAXFAN; do
  value="${!name:-}"
  [[ -z "$value" || ( "$value" =~ ^[1-9][0-9]*$ && "$value" -le 100000 ) ]] || { echo "$name must be a positive integer" >&2; exit 1; }
done
[[ -z "$route_maxfan" || "$route_maxfan" -le 100 ]] || { echo "SDRAM_ROUTE_MAXFAN must be 1 through 100" >&2; exit 1; }
case "$rvc" in 0|1) ;; *) echo "SDRAM_RVC must be 0 or 1" >&2;exit 1;; esac
case "$cache" in 0|1) ;; *) echo "SDRAM_CACHE must be 0 or 1" >&2;exit 1;; esac
case "$cache_line_bits" in 7|8|9|10|11|12) ;; *) echo "SDRAM_CACHE_LINE_BITS must be 7 through 12" >&2;exit 1;; esac
if [[ "$cache_ways" == 2 && "$cache_line_bits" == 12 ]];then
  echo "SDRAM_CACHE_WAYS=2 requires SDRAM_CACHE_LINE_BITS<=11 (64 KiB max on GW2AR-18)" >&2;exit 1
fi
case "$freq" in 27|48|54|60|66) ;; *) echo "supported SDRAM clocks: 27, 48, 54, 60, 66 MHz" >&2;exit 1;; esac
python3 - "$target" "$cpu_freq" <<'PYTHON'
import sys
try:
    target = int(sys.argv[1]); cpu = int(sys.argv[2])
    if target <= 0 or target < cpu:
        raise ValueError()
except ValueError:
    raise SystemExit('SDRAM_TARGET_MHZ must be an integer frequency >= SDRAM_CPU_FREQ_MHZ')
PYTHON
if [[ "$cpu_freq" != "$freq" ]];then
  if [[ ( "$cpu_freq" != 108 && "$cpu_freq" != 96 && "$cpu_freq" != 72 ) || ( "$freq" != 54 && "$freq" != 48 ) || ( "$mode" != core && "$mode" != pipeline ) ]];then
    echo "separate clocks require pipeline/core, SDRAM_CPU_FREQ_MHZ=72, 96 or 108 and SDRAM_FREQ_MHZ=48 or 54" >&2;exit 1
  fi
fi
# Audit the memory specification before expensive CPU generation. Ordinary
# builds still check internal STA only; an explicit I/O profile is fail-closed.
case "$mode" in test|serial) phase=225;burst_words=1;; core|pipeline|burst-test) phase=135;burst_words=4;;
 *) echo "usage: build.sh [test|burst-test|core|pipeline|serial]" >&2;exit 1;;esac
phase="${SDRAM_PHASE_DEGREES:-$phase}"
phase="$(python3 - "$phase" <<'PYTHON'
from decimal import Decimal, InvalidOperation
import sys
try:
    value = Decimal(sys.argv[1])
    if not value.is_finite() or not 0 <= value < 360 or value % Decimal('22.5'):
        raise ValueError()
except (InvalidOperation, ValueError):
    raise SystemExit('SDRAM_PHASE_DEGREES must be 0 through 337.5 in 22.5-degree steps')
print(format(value.normalize(), 'f'))
PYTHON
)"
out="${SDRAM_OUT:-$root/output/tangnano20k/sdram-$mode}"
if [[ -n "${SDRAM_PRESET:-}" ]]; then out="${SDRAM_OUT:-$root/output/tangnano20k/fprisc-48}"; fi
if [[ "$out" != /* ]];then out="$PWD/$out";fi
if [[ -n "${SDRAM_PRESET:-}" ]]; then
  python3 "$here/preset_manifest.py" begin "$out"
fi
case "${SDRAM_REQUIRE_IO_MODEL:-0}" in 0|1) ;; *) echo "SDRAM_REQUIRE_IO_MODEL must be 0 or 1" >&2;exit 1;;esac
io_args=(--freq-mhz "$freq" --phase-degrees "$phase" --burst-words "$burst_words" --out "$out")
if [[ "$cpu_freq" != "$freq" ]];then io_args+=(--split-clock);fi
if [[ -n "${SDRAM_IO_PROFILE:-}" ]];then
  io_profile="$SDRAM_IO_PROFILE"
  if [[ "$io_profile" != /* ]];then io_profile="$root/$io_profile";fi
  io_args+=(--profile "$io_profile" --emit-sdc)
elif [[ "${SDRAM_REQUIRE_IO_MODEL:-0}" == 1 ]];then
  io_args+=(--emit-sdc)
fi
python3 "$here/io_timing.py" "${io_args[@]}"
case "$mode" in
 test|burst-test) top="$here/test_top.v"; rtl="";;
 core|pipeline|serial)
   cd "$root"
   if [[ "$mode" == serial ]];then
     module=SdramSimpleRisc;entity=sdram_simple_risc;top="$here/core_top.v"
   else
     module=SdramPipeline;entity=sdram_pipeline_risc;top="$here/pipeline_top.v"
   fi
   generated="$root/output/tangnano20k/sdram-generated/$module-$rvc"
   options=(-isrc -hide-package simple-risc);if [[ "$rvc" == 1 ]];then options+=(-DRISCV_COMPRESSED);fi
   if [[ -n "${SDRAM_RTL_FILE:-}" ]];then
     rtl="$SDRAM_RTL_FILE"
     if [[ "$rtl" != /* ]];then rtl="$root/$rtl";fi
     if [[ ! -f "$rtl" ]];then echo "SDRAM_RTL_FILE does not exist: $rtl" >&2;exit 1;fi
   else
     cabal run -v0 clash -- "${options[@]}" "src/$module.hs" --verilog -fclash-clear -outputdir "$generated"
     rtl="$generated/$module.topEntity/$entity.v"
   fi;;
 *) echo "usage: build.sh [test|burst-test|core|pipeline|serial]" >&2; exit 1;;
esac
ide="/Applications/GowinIDE.app/Contents/Resources/Gowin_EDA/IDE"
# Diagnostic overrides: build with another cache or clock-bridge source.
cache_rtl="${SDRAM_CACHE_RTL:-$here/pipeline_cache.v}"
bridge_rtl="${SDRAM_BRIDGE_RTL:-$here/clock_bridge.v}"
for f in "$cache_rtl" "$bridge_rtl";do [[ -f "$f" ]] || { echo "missing RTL override: $f" >&2;exit 1; };done
mkdir -p "$out"
python3 - "$here" "$out" "$freq" "$mode" "$cache" "$phase" "$cpu_freq" "$cache_line_bits" "$cache_ways" <<'PYTHON'
from pathlib import Path
import hashlib, json, sys
src,out=map(Path,sys.argv[1:3]);freq=int(sys.argv[3])
cpu_freq=int(sys.argv[7])
# Only the pipeline top exposes the SD-card slot; the other images retain
# their original port list.
sd_slot=sys.argv[4] in ('core','pipeline')
(out/'pins.cst').write_text(''.join(line for line in (src.parent/'tangnano20k.cst').read_text().splitlines(True) if sd_slot or '"sd_' not in line))
if sys.argv[4] in ('core','pipeline','serial'):
    pipelined=sys.argv[4]!='serial'
    rom_words=(src.parent/'bootrom/bootrom-sdram.hex').read_text().splitlines()[:508]
    manifest_path=out/'build-manifest.json'
    build_id=None
    if manifest_path.is_file():
        try: build_id=(json.loads(manifest_path.read_text()).get('rom_identity') or {}).get('build_id')
        except Exception: build_id=None
    if not build_id or len(build_id)!=16:
        build_id=hashlib.sha256(('\n'.join(rom_words)+f':{sys.argv[4]}:{cpu_freq}:{freq}:{sys.argv[8]}:{sys.argv[9]}').encode()).hexdigest()[:16]
    stamped_rom=out/'bootrom-sdram.hex'
    stamped_rom.write_text('\n'.join([*rom_words,f'{cpu_freq:08x}',f'{freq:08x}',build_id[:8],build_id[8:16]])+'\n')
    top=(src/('pipeline_top.v' if pipelined else 'core_top.v')).read_text()
    top=top.replace('BOOT_ROM_FILE',str(stamped_rom)).replace('CORE_FREQUENCY',str(freq*1000000)).replace('CPU_FREQUENCY',str(cpu_freq*1000000)).replace('CACHE_LINE_BITS',sys.argv[8]).replace('CACHE_WAYS',sys.argv[9])
    if cpu_freq!=freq:
        top=top.replace('sdram_pll pll(.clk_27m(clk_27m),.clk_core(clk),.clk_sdram(clk_sdram),.pll_lock(lock));',
                        f'sdram_dual_pll #(.CPU_MHZ({cpu_freq}),.MEM_MHZ({freq})) pll(.clk_27m(clk_27m),.clk_core(clk),.clk_memory(clk_memory),.clk_sdram(clk_sdram),.pll_lock(lock));')
        top=top.replace(' assign clk_memory=clk; // SINGLE_CLOCK_MEMORY\n','')
    if pipelined and sys.argv[5]=='0':raise SystemExit('the pipeline requires its fixed-latency cache; use serial with SDRAM_CACHE=0')
    if not pipelined and sys.argv[5]=='0':
        start=top.index(' sdram_cache cache(');end=top.index(' sdram_memory mem(')
        top=top[:start]+''' assign mem_req=req;assign mem_write=write;assign mem_address=address;
 assign mem_wdata=wdata;assign ready=mem_ready;assign done=mem_done;assign rdata=mem_rdata;
'''+top[end:]
    (out/(sys.argv[4]+'_top.v')).write_text(top)
if sys.argv[4] in ('test','burst-test'):
    top=(src/'test_top.v').read_text().replace("24'd2700000",f"24'd{freq*50000}").replace("25'd13500000",f"25'd{freq*250000}")
    if sys.argv[4]=='burst-test':top=top.replace('sdram_memory mem(',f'sdram_burst_word_memory #(.FREQ({freq*1000000})) mem(')
    (out/(sys.argv[4]+'_top.v')).write_text(top)
pll=(src/'pll.v').read_text().replace('FBDIV_SEL=17',f'FBDIV_SEL={freq//3-1}').replace('ODIV_SEL=16','ODIV_SEL=32' if freq==27 else 'ODIV_SEL=16')
phase_bits=format(int(float(sys.argv[6])/22.5),'04b')
pll=pll.replace('PSDA_SEL("1010")',f'PSDA_SEL("{phase_bits}")')
(out/'pll.v').write_text(pll)
(out/'memory.v').write_text((src/'memory.v').read_text().replace('FREQ=54000000',f'FREQ={freq*1000000}'))
PYTHON
if [[ -n "${SDRAM_REGION_CST:-}" ]]; then
  region="${SDRAM_REGION_CST}"
  [[ "$region" != /* ]] && region="$root/$region"
  [[ -f "$region" ]] || { echo "SDRAM_REGION_CST does not exist: $region" >&2; exit 1; }
  printf '\n' >> "$out/pins.cst"
  cat "$region" >> "$out/pins.cst"
fi
top="$out/${mode}_top.v"
cat > "$out/build.tcl" <<TCL
set_device -name GW2AR-18C GW2AR-LV18QN88C8/I7
set_option -top_module top
set_option -output_base_name sdram_test
set_option -opt_goal timing
set_option -place_option $placement
set_option -frequency $target
set_option -global_freq $target
set_option -num_critical_paths 20
set_option -gen_verilog_sim_netlist 1
TCL
for knob in map_option route_option replicate max_fanout route_maxfan; do
  case "$knob" in
    replicate) option=-replicate_resources;;
    *) option="-$knob";;
  esac
  value="${!knob:-}"
  [[ -z "$value" ]] || echo "set_option $option $value" >> "$out/build.tcl"
done
cat >> "$out/build.tcl" <<TCL
add_file "$top"
add_file "$out/memory.v"
add_file "$here/cache.v"
add_file "$cache_rtl"
add_file "$here/burst_memory.v"
add_file "$bridge_rtl"
add_file "$here/sdram.v"
add_file "$out/pll.v"
add_file "$here/dual_pll.v"
add_file "$out/pins.cst"
add_file "$out/clocks.sdc"
file delete -force "$out/impl/pnr/sdram_test.tr"
run all
exit
TCL
if [[ -n "$rtl" ]]; then
  python3 - "$out/build.tcl" "$rtl" <<'PYTHON'
from pathlib import Path
import sys
p=Path(sys.argv[1]);p.write_text(p.read_text().replace('run all', 'add_file "'+sys.argv[2]+'"\nrun all'))
PYTHON
fi
if [[ "$cpu_freq" == "$freq" ]];then
cat > "$out/clocks.sdc" <<SDC
create_clock -name clk_27m -period 37.037037 [get_ports {clk_27m}]
create_generated_clock -name clk_core -source [get_ports {clk_27m}] -multiply_by $((freq/3)) -divide_by 9 [get_pins {pll/pll_s2/CLKOUT}]
create_generated_clock -name clk_sdram -source [get_ports {clk_27m}] -multiply_by $((freq/3)) -divide_by 9 -phase $phase [get_pins {pll/pll_s2/CLKOUTP}]
SDC
else
cat > "$out/clocks.sdc" <<SDC
create_clock -name clk_27m -period 37.037037 [get_ports {clk_27m}]
create_generated_clock -name clk_core -source [get_ports {clk_27m}] -multiply_by $((cpu_freq/3)) -divide_by 9 [get_pins {pll/cpu/pll/CLKOUT}]
create_generated_clock -name clk_memory -source [get_ports {clk_27m}] -multiply_by $((freq/3)) -divide_by 9 [get_pins {pll/memory/pll/CLKOUT}]
create_generated_clock -name clk_sdram -source [get_ports {clk_27m}] -multiply_by $((freq/3)) -divide_by 9 -phase $phase [get_pins {pll/memory/pll/CLKOUTP}]
# Only the first metastability stages (the FIFO's Gray pointers and the read
# response toggle) are asynchronous endpoints. Payload slots retain normal
# setup/hold analysis; no clock groups or blanket
# cross-domain false paths conceal their physical routing delays.
set_false_path -to [get_regs {dual_clock.bridge/put_meta_0_s0 dual_clock.bridge/put_meta_1_s0 dual_clock.bridge/put_meta_2_s0}]
set_false_path -to [get_regs {dual_clock.bridge/take_meta_0_s0 dual_clock.bridge/take_meta_1_s0 dual_clock.bridge/take_meta_2_s0}]
set_false_path -to [get_regs {dual_clock.bridge/response_meta_s0}]
SDC
fi
if [[ -f "$out/sdram-io.sdc" ]];then
  cat "$out/sdram-io.sdc" >> "$out/clocks.sdc"
  echo "SDRAM I/O bounds supplied; routed path coverage and protocol checks are still required."
else
  echo "SDRAM I/O remains unqualified: this build checks internal FPGA timing only."
fi
if [[ "${SDRAM_GENERATE_ONLY:-0}" == 1 ]];then
  echo "Generated $out: CPU/cache $cpu_freq MHz, SDRAM $freq MHz, phase $phase degrees, placement target $target MHz"
  exit 0
fi
export DYLD_LIBRARY_PATH="$ide/lib"
export DYLD_FRAMEWORK_PATH="$ide/lib"
cd "$out"
rm -f "$out/impl/pnr/sdram_test.tr"
"$ide/bin/gw_sh" build.tcl
if [[ "${SDRAM_SKIP_TIMING_CHECK:-0}" == 1 ]];then
  echo "Timing check skipped (SDRAM_SKIP_TIMING_CHECK=1); report at $out/impl/pnr/sdram_test.tr"
else
  timing_args=(--freq-mhz "$cpu_freq")
  if [[ "$cpu_freq" != "$freq" ]];then timing_args+=(--memory-freq-mhz "$freq");fi
  python3 "$here/../check_gowin_timing.py" "$out/impl/pnr/sdram_test.tr" "${timing_args[@]}"
fi
if [[ -n "${SDRAM_PRESET:-}" ]]; then
  python3 "$here/preset_manifest.py" finish "$out" "$rtl"
fi
