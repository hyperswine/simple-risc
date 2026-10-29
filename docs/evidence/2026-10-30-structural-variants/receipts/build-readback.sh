#!/bin/bash
set -euo pipefail
cd /Users/jasonqin/Documents/GitHub/simple-risc
for mhz in 48 60; do
  SDRAM_FREQ_MHZ="$mhz" SDRAM_CPU_FREQ_MHZ="$mhz" SDRAM_RVC=1 SDRAM_CACHE=1 \
  SDRAM_CACHE_WAYS=2 SDRAM_CACHE_LINE_BITS=11 SDRAM_PHASE_DEGREES=135 \
  SDRAM_PLACE_OPTION=2 SDRAM_ROUTE_OPTION=1 SDRAM_MAP_OPTION=3 SDRAM_ROUTE_MAXFAN=8 \
  SDRAM_RTL_FILE="$PWD/output/tangnano20k/structural-20261030/observed/generated/SdramPipeline.topEntity/sdram_pipeline_risc.v" \
  SDRAM_ROM_FILE="$PWD/output/tangnano20k/structural-next-20261030/readback-rom/readback.hex" \
  SDRAM_OUT="$PWD/output/tangnano20k/structural-next-20261030/raw-$mhz" \
  boards/tangnano20k/sdram/build.sh pipeline > "output/tangnano20k/structural-next-20261030/raw-$mhz.log" 2>&1
  echo "Readback ROM hardware built at $mhz MHz"
done
