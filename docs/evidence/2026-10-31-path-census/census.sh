#!/usr/bin/env bash
# Path census builds: CPU clock high, SDRAM at 48 MHz, 3000 reported paths.
set -u
cd "$(dirname "$0")/../../.."
D=output/tangnano20k/census-20261031
for cpu in ${CPUS:-72 96}; do
  out=$D/cpu$cpu-${DESIGN:-head}-p${PLACE:-0}${TAG:-}
  [[ -f $out/done ]] && continue
  for i in 1 2 3 4 5 6 7 8; do
    SDRAM_RVC=1 SDRAM_FREQ_MHZ=48 SDRAM_CPU_FREQ_MHZ=$cpu SDRAM_TARGET_MHZ=$cpu SDRAM_PLACE_OPTION=${PLACE:-0} \
    SDRAM_ROUTE_OPTION=1 SDRAM_MAP_OPTION=3 SDRAM_ROUTE_MAXFAN=8 SDRAM_CRITICAL_PATHS=3000 SDRAM_REPORT_PATHS=${REPORT_PATHS:-3000} \
    SDRAM_RTL_FILE=$D/${DESIGN:-head}.v SDRAM_OUT=$out \
      bash boards/tangnano20k/sdram/build.sh pipeline > $out.log 2>&1
    grep -q "License verification failed" $out.log || break
    sleep 30
  done
  line=$(grep -E "^(PASS|FAIL)" $out.log | tail -1)
  [[ -n "$line" ]] || line="NO RESULT: $(tail -1 $out.log)"
  echo "cpu $cpu ${DESIGN:-head} place=${PLACE:-0}: $line" | tee -a $D/summary.txt
  touch $out/done 2>/dev/null
done
