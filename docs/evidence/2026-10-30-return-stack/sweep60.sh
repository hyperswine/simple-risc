#!/usr/bin/env bash
# Pass/fail at the next clock step: 60 MHz CPU and SDRAM (phase 112.5, as the
# 60 MHz variants), placer over-constrained to 66 MHz, route 1, map 3,
# route max-fanout 8. One build at a time (license server).
set -u
cd "$(dirname "$0")/../../.."
D=output/tangnano20k/timing-sweep-20261030
for place in 0 2 3; do
  for design in head fast; do
    out=$D/c60-$design-p$place
    [[ -f $out/done ]] && continue
    for i in 1 2 3 4 5 6 7 8; do
      SDRAM_RVC=1 SDRAM_FREQ_MHZ=60 SDRAM_TARGET_MHZ=66 SDRAM_PHASE_DEGREES=112.5 SDRAM_PLACE_OPTION=$place \
      SDRAM_ROUTE_OPTION=1 SDRAM_MAP_OPTION=3 SDRAM_ROUTE_MAXFAN=8 SDRAM_RTL_FILE=$D/rtl/$design.v SDRAM_OUT=$out \
        bash boards/tangnano20k/sdram/build.sh pipeline > $out.log 2>&1
      grep -q "License verification failed" $out.log || break
      sleep 30
    done
    line=$(grep -E "^(PASS|FAIL)" $out.log | tail -1)
    [[ -n "$line" ]] || line="NO RESULT: $(tail -1 $out.log)"
    echo "60MHz $design place=$place: $line" | tee -a $D/summary60.txt
    touch $out/done 2>/dev/null
  done
done
