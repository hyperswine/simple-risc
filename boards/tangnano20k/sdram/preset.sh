# Sourced by build.sh. The preset is a fixed configuration, not defaults that
# inherited experimental environment variables can silently override.
#   fprisc-48  CPU/SDRAM 48/48 MHz, one-way 64 KiB cache, placement 2: the
#              validated FP-RISC development image.
#   fprisc-72  CPU 72 / SDRAM 48 MHz behind the clock bridge, two-way 64 KiB
#              cache, placement 0 aimed at 79 MHz with the timing-driven map
#              and route options (docs/2026-11-01-FPRISC-72-PRESET.md).
if [[ -n "${SDRAM_PRESET:-}" ]]; then
  case "$SDRAM_PRESET" in fprisc-48|fprisc-72) ;; *) echo "unknown SDRAM_PRESET: $SDRAM_PRESET" >&2; exit 1;; esac
  sdram_preset_setting() {
    if [[ -n "${!1+x}" && "${!1}" != "$2" ]]; then
      echo "SDRAM_PRESET=$SDRAM_PRESET requires $1=$2 (got ${!1})" >&2; exit 1
    fi
    export "$1=$2"
  }
  sdram_preset_setting SDRAM_FREQ_MHZ 48
  sdram_preset_setting SDRAM_RVC 1
  sdram_preset_setting SDRAM_CACHE 1
  sdram_preset_setting SDRAM_PHASE_DEGREES 135
  # Settings no preset may take from the environment.
  forbidden=(SDRAM_RTL_FILE SDRAM_CACHE_RTL SDRAM_BRIDGE_RTL SDRAM_ROM_FILE SDRAM_REGION_CST SDRAM_SKIP_TIMING_CHECK
    SDRAM_REPLICATE SDRAM_MAX_FANOUT SDRAM_EXTRA_SDC)
  if [[ "$SDRAM_PRESET" == fprisc-48 ]]; then
    sdram_preset_setting SDRAM_CPU_FREQ_MHZ 48
    sdram_preset_setting SDRAM_CACHE_WAYS 1
    sdram_preset_setting SDRAM_CACHE_LINE_BITS 12
    sdram_preset_setting SDRAM_PLACE_OPTION 2
    sdram_preset_setting SDRAM_TARGET_MHZ 48
    forbidden+=(SDRAM_MAP_OPTION SDRAM_ROUTE_OPTION SDRAM_ROUTE_MAXFAN)
  else
    sdram_preset_setting SDRAM_CPU_FREQ_MHZ 72
    sdram_preset_setting SDRAM_CACHE_WAYS 2
    sdram_preset_setting SDRAM_CACHE_LINE_BITS 11
    sdram_preset_setting SDRAM_PLACE_OPTION 0
    sdram_preset_setting SDRAM_TARGET_MHZ 79
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
