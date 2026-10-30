#!/usr/bin/env bash
# 128-entry BTB: netlists, RTL check, sim, 60 MHz builds.
set -u
cd "$(dirname "$0")/../../.."
D=output/tangnano20k/timing-sweep-20261030
S=/private/tmp/claude-501/-Users-jasonqin-Documents-GitHub/e52837f9-dd17-4ab3-ae0b-9c0491a42b2e/scratchpad
cabal run -v0 clash -- -isrc -hide-package simple-risc -DRISCV_COMPRESSED src/SdramPipeline.hs --verilog -fclash-clear -outputdir $S/rtl-btb128 > $S/rtl-btb128.log 2>&1 || { echo "clash failed"; exit 1; }
cp $S/rtl-btb128/SdramPipeline.topEntity/sdram_pipeline_risc.v $D/rtl/btb128.v
cabal run -v0 clash -- -isrc -hide-package simple-risc -DRISCV_COMPRESSED -DPIPELINE_SLOT_OBSERVATIONS src/SdramPipelineObserved.hs --verilog -fclash-clear -outputdir output/observed-btb128 > output/observed-btb128.log 2>&1 || { echo "observed clash failed"; exit 1; }
python3 boards/tangnano20k/sdram/check_pipeline_rtl.py --compressed --generated output/observed-btb128/SdramPipelineObserved.topEntity --simulator verilator --out output/tangnano20k/rtl-check-btb128 > output/tangnano20k/rtl-check-btb128.log 2>&1
echo "rtlcheck=$?"; tail -3 output/tangnano20k/rtl-check-btb128.log
I=output/tangnano20k/structural-20261030/input; O=output/tangnano20k/btb128-20261030; mkdir -p $O
python3 boards/tangnano20k/sdram/run_perf.py $I/base.bin --elf $I/base.elf --generated output/observed-btb128/SdramPipelineObserved.topEntity --cpu-mhz 48 --mem-mhz 48 --single-clock --line-bits 11 --ways 2 --write-update 1 --split --out $O/sim --jobs 4 > $O/runner.log 2>&1
echo "sim=$?"; grep -E "DTREE (train|test)|commits|^PERF redirect_kind|front_redirects" $O/runner.log
DESIGN=btb128 PLACES="${PLACES:-0 2 3}" bash $D/design60.sh
