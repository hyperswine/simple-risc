#!/usr/bin/env bash
# Step 1 of the amended proposal: equalities as LUT trees. Synthesis plus
# placement 3 from build.sh at 87 MHz (retried on licence refusals), then
# placements 0, 1 and 4 with pnr_only.sh on that netlist.
set -u
cd /Users/jasonqin/Documents/GitHub/simple-risc
S=output/tangnano20k/lut-eq-and-20261109
f=87; t=96
for attempt in 1 2 3 4; do
  rm -rf $S/f$f-p3
  SDRAM_CPU_FREQ_MHZ=$f SDRAM_FREQ_MHZ=48 SDRAM_RVC=0 SDRAM_CACHE=1 SDRAM_PHASE_DEGREES=135 SDRAM_CACHE_WAYS=2 SDRAM_CACHE_LINE_BITS=11 \
  SDRAM_PLACE_OPTION=3 SDRAM_TARGET_MHZ=$t SDRAM_MAP_OPTION=3 SDRAM_ROUTE_OPTION=1 SDRAM_ROUTE_MAXFAN=8 \
  SDRAM_FLOORPLAN=boards/tangnano20k/sdram/fprisc-81.plan SDRAM_REPORT_PATHS=3000 \
  SDRAM_OUT=$S/f$f-p3 boards/tangnano20k/sdram/build.sh pipeline > $S/f$f-p3.log 2>&1
  grep -q 'License verification failed' $S/f$f-p3.log || break
  sleep 40
done
[ -f $S/f$f-p3/impl/gwsynthesis/sdram_test.vg ] || { echo "f$f: no netlist" >> $S/sweep.log; echo SWEEP-DONE >> $S/sweep.log; exit 1; }
cp output/tangnano20k/sdram-generated/SdramPipeline-0/SdramPipeline.topEntity/sdram_pipeline_risc.v $S/
for p in 0 1 4; do
  PNR_PLACE_OPTION=$p PNR_REPORT_PATHS=3000 PNR_TIMEOUT=1800 boards/tangnano20k/sdram/pnr_only.sh $S/f$f-p3 $S/f$f-p$p > $S/f$f-p$p.log 2>&1 &
  sleep 20
done
wait
echo SWEEP-DONE >> $S/sweep.log
