#!/usr/bin/env bash
# Route one archived netlist again with the measured clock and placement settings.
set -euo pipefail
evidence=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$evidence/../../.." && pwd)
variant=${1:?usage: replay.sh baseline|btb|hazard 0..4 NEW_OUTPUT_DIRECTORY}
place=${2:?missing placement}
output=${3:?missing new output directory}
case "$variant" in baseline|btb|hazard) ;; *) exit 2 ;; esac
case "$place" in [0-4]) ;; *) exit 2 ;; esac
mkdir "$output"
output=$(cd "$output" && pwd)
source_dir="$output/source"
mkdir -p "$source_dir/impl/gwsynthesis"
gzip -dc "$evidence/$variant/sdram_test.vg.gz" > "$source_dir/impl/gwsynthesis/sdram_test.vg"
for name in pins.cst clocks.sdc build.tcl; do
  gzip -dc "$evidence/$variant/p$place/$name.gz" > "$source_dir/$name"
done
# p3's synthesis Tcl uses the shorter general report option. All five include
# the explicit 3000-path core report in the archived SDC.
paths=3000
if [[ "$place" == 3 ]]; then paths=20; fi
PNR_REPORT_PATHS="$paths" PNR_PLACE_OPTION="$place" \
  "$root/boards/tangnano20k/sdram/pnr_only.sh" "$source_dir" "$output/placement"
