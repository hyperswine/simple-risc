# Sourced by build.sh. The preset is a fixed configuration, not defaults that
# inherited experimental environment variables can silently override.
#   fprisc-48  CPU/SDRAM 48/48 MHz, one-way 64 KiB cache, placement 2: the
#              validated FP-RISC development image.
#   fprisc-72  CPU 72 / SDRAM 48 MHz behind the clock bridge, two-way 64 KiB
#              cache, aimed at 79 MHz with the timing-driven map and route
#              options (docs/2026-11-01-FPRISC-72-PRESET.md); placement 3 and
#              the floorplan since the three-clock cache port, like fprisc-81.
#   fprisc-81  CPU 81 / SDRAM 48 MHz, the RV32IM core (no compressed
#              instructions: docs/2026-11-08-IM-CANON.md), two-way 64 KiB
#              cache, placement 3 aimed at 89 MHz with the fprisc-81.plan
#              floorplan.
#   fprisc-84  the fprisc-81 shape at CPU 84 MHz, the highest clock every
#              placement option closes (docs/2026-11-08-FPRISC-84.md).
if [[ -n "${SDRAM_PRESET:-}" ]]; then
  case "$SDRAM_PRESET" in fprisc-48|fprisc-72|fprisc-81|fprisc-84) ;; *) echo "unknown SDRAM_PRESET: $SDRAM_PRESET" >&2; exit 1;; esac
  sdram_preset_setting() {
    if [[ -n "${!1+x}" && "${!1}" != "$2" ]]; then
      echo "SDRAM_PRESET=$SDRAM_PRESET requires $1=$2 (got ${!1})" >&2; exit 1
    fi
    export "$1=$2"
  }
  sdram_preset_setting SDRAM_FREQ_MHZ 48
  # fprisc-48 and fprisc-72 are the RV32IMC core; fprisc-81 and fprisc-84 are
  # RV32IM, which places with margin at every placement option where the IMC
  # core does not.
  case "$SDRAM_PRESET" in fprisc-81|fprisc-84) sdram_preset_setting SDRAM_RVC 0;; *) sdram_preset_setting SDRAM_RVC 1;; esac
  sdram_preset_setting SDRAM_CACHE 1
  sdram_preset_setting SDRAM_PHASE_DEGREES 135
  # Settings no preset may take from the environment.
  forbidden=(SDRAM_RTL_FILE SDRAM_CACHE_RTL SDRAM_BRIDGE_RTL SDRAM_ROM_FILE SDRAM_REGION_CST SDRAM_SKIP_TIMING_CHECK
    SDRAM_REPLICATE SDRAM_MAX_FANOUT SDRAM_EXTRA_SDC)
  # The split-clock presets have a floorplan, and it is the preset's own.
  [[ "$SDRAM_PRESET" != fprisc-48 ]] || forbidden+=(SDRAM_FLOORPLAN)
  if [[ "$SDRAM_PRESET" == fprisc-48 ]]; then
    sdram_preset_setting SDRAM_CPU_FREQ_MHZ 48
    sdram_preset_setting SDRAM_CACHE_WAYS 1
    sdram_preset_setting SDRAM_CACHE_LINE_BITS 12
    sdram_preset_setting SDRAM_PLACE_OPTION 2
    sdram_preset_setting SDRAM_TARGET_MHZ 48
    forbidden+=(SDRAM_MAP_OPTION SDRAM_ROUTE_OPTION SDRAM_ROUTE_MAXFAN)
  elif [[ "$SDRAM_PRESET" == fprisc-72 ]]; then
    sdram_preset_setting SDRAM_CPU_FREQ_MHZ 72
    sdram_preset_setting SDRAM_CACHE_WAYS 2
    sdram_preset_setting SDRAM_CACHE_LINE_BITS 11
    sdram_preset_setting SDRAM_PLACE_OPTION 3
    sdram_preset_setting SDRAM_FLOORPLAN boards/tangnano20k/sdram/fprisc-81.plan
    sdram_preset_setting SDRAM_TARGET_MHZ 79
    sdram_preset_setting SDRAM_MAP_OPTION 3
    sdram_preset_setting SDRAM_ROUTE_OPTION 1
    sdram_preset_setting SDRAM_ROUTE_MAXFAN 8
  elif [[ "$SDRAM_PRESET" == fprisc-81 ]]; then
    sdram_preset_setting SDRAM_CPU_FREQ_MHZ 81
    sdram_preset_setting SDRAM_CACHE_WAYS 2
    sdram_preset_setting SDRAM_CACHE_LINE_BITS 11
    sdram_preset_setting SDRAM_PLACE_OPTION 3
    sdram_preset_setting SDRAM_FLOORPLAN boards/tangnano20k/sdram/fprisc-81.plan
    sdram_preset_setting SDRAM_TARGET_MHZ 89
    sdram_preset_setting SDRAM_MAP_OPTION 3
    sdram_preset_setting SDRAM_ROUTE_OPTION 1
    sdram_preset_setting SDRAM_ROUTE_MAXFAN 8
  else
    sdram_preset_setting SDRAM_CPU_FREQ_MHZ 84
    sdram_preset_setting SDRAM_CACHE_WAYS 2
    sdram_preset_setting SDRAM_CACHE_LINE_BITS 11
    sdram_preset_setting SDRAM_PLACE_OPTION 3
    sdram_preset_setting SDRAM_FLOORPLAN boards/tangnano20k/sdram/fprisc-81.plan
    sdram_preset_setting SDRAM_TARGET_MHZ 92
    sdram_preset_setting SDRAM_MAP_OPTION 3
    sdram_preset_setting SDRAM_ROUTE_OPTION 1
    sdram_preset_setting SDRAM_ROUTE_MAXFAN 8
  fi
  for name in "${forbidden[@]}"; do
    [[ -z "${!name:-}" ]] || { echo "$name is incompatible with SDRAM_PRESET=$SDRAM_PRESET" >&2; exit 1; }
  done
  unset -f sdram_preset_setting
  unset forbidden
fi
