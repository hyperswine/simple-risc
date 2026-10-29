# Sourced by build.sh. The preset is a fixed configuration, not defaults that
# inherited experimental environment variables can silently override.
if [[ -n "${SDRAM_PRESET:-}" ]]; then
  [[ "$SDRAM_PRESET" == fprisc-48 ]] || { echo "unknown SDRAM_PRESET: $SDRAM_PRESET" >&2; exit 1; }
  sdram_preset_setting() {
    if [[ -n "${!1+x}" && "${!1}" != "$2" ]]; then
      echo "SDRAM_PRESET=fprisc-48 requires $1=$2 (got ${!1})" >&2; exit 1
    fi
    export "$1=$2"
  }
  sdram_preset_setting SDRAM_FREQ_MHZ 48
  sdram_preset_setting SDRAM_CPU_FREQ_MHZ 48
  sdram_preset_setting SDRAM_RVC 1
  sdram_preset_setting SDRAM_CACHE 1
  sdram_preset_setting SDRAM_CACHE_WAYS 1
  sdram_preset_setting SDRAM_CACHE_LINE_BITS 12
  sdram_preset_setting SDRAM_PHASE_DEGREES 135
  sdram_preset_setting SDRAM_PLACE_OPTION 2
  sdram_preset_setting SDRAM_TARGET_MHZ 48
  for name in SDRAM_RTL_FILE SDRAM_CACHE_RTL SDRAM_BRIDGE_RTL SDRAM_ROM_FILE SDRAM_REGION_CST SDRAM_SKIP_TIMING_CHECK \
    SDRAM_MAP_OPTION SDRAM_ROUTE_OPTION SDRAM_REPLICATE SDRAM_MAX_FANOUT SDRAM_ROUTE_MAXFAN; do
    [[ -z "${!name:-}" ]] || { echo "$name is incompatible with SDRAM_PRESET=fprisc-48" >&2; exit 1; }
  done
  unset -f sdram_preset_setting
fi
