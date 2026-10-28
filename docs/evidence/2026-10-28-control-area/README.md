# Control-fanout and area evidence

See the [analysis](../../2026-10-28-CONTROL-FANOUT-AND-AREA.md) for results,
source tracing, implementation rationale and acceptance limits.

- `baseline-fresh/` and `mru-ram/` contain complete timing/utilization reports,
  constraints, stamped ROM, top-level source, compressed synthesis netlists
  and bitstream hashes from successful 48/48 MHz builds.
- `baseline-analysis.json`, `baseline-fresh-analysis.json` and
  `mru-analysis.json` are extracted by `analyze_implementation.py`. The two
  baseline reports agree on resources, Fmax and all 25 leading setup paths.
- `controls.json` checks that only cache source changed. Generated build
  outputs match after normalizing their output-directory paths.
- `baseline-cache.v` and `optimized-cache.v` retain the exact compared cache
  implementations. The frozen CPU is the preceding benchmark's
  [`cpu-on.v.gz`](../2026-10-28-controlled-benchmark/cpu-on.v.gz), SHA-256 after
  decompression `b2db3d0bd4c05399f7b8b0eb26e508c027b69e018e70571299cc6b9cd05f1030`.
- `cache-regression/` and `mru-regression/` retain the 18 existing cache cases
  and five replacement-policy cases, including expected failures.
- `cpu-im.log` and `cpu-imc-cdc.log` execute the frozen generated CPUs against
  the new cache, including deliberately corrupt backend rejection.
- `perf-mru/` contains the new classifier output, simulator build receipt and
  result. `performance-comparison.json` checks every counter against the
  preceding benchmark. Its exact binary/ELF inputs remain in that benchmark's
  evidence directory, so no compiler rebuild is required.
- `hardware/` contains the three new physical runs, the local experiment
  script, SRAM-programming logs and successful known-good restoration/probe.
  Its script records local paths and is evidence of the procedure, not a
  portable deployment interface.
- `smoke.S` and `gls-mru.log` exercise three conflicting tags against the
  actual synthesized primitives. The final run exits successfully after
  223,271 SDRAM clocks. `primitive-model-source.json` identifies the installed
  vendor model consulted for `RAM16SDP1` semantics.
- `formal.log` records the 19 passing searches. The new MRU test is also
  wired into CI; no hosted run is claimed for this local change.

The `diagnostics/` directory retains unsuccessful setup attempts separately:
two license-server refusals, an initially relative baseline-cache override,
and the first smoke harness run whose ROM `DONE` prefix prevented its exit
matcher from recognizing the printed success line. The final smoke program
begins its success output with a newline and the successful gate-level run
ends on the success marker, before its cycle limit. None of these attempts
is counted as a passing run.

## Re-extract the archived implementation reports

From the repository root:

```bash
python3 - <<'PY'
from pathlib import Path
import gzip, shutil
src = Path('docs/evidence/2026-10-28-control-area')
out = Path('output/tangnano20k/control-area-analysis-replay')
out.mkdir(parents=True, exist_ok=False)
for name in ('baseline-fresh', 'mru-ram'):
    build = out/name
    (build/'impl/gwsynthesis').mkdir(parents=True)
    (build/'impl/pnr').mkdir()
    (build/'impl/gwsynthesis/sdram_test.vg').write_bytes(
        gzip.decompress((src/name/'sdram_test.vg.gz').read_bytes()))
    for file in ('sdram_test.tr', 'sdram_test.rpt.txt'):
        shutil.copy2(src/name/file, build/'impl/pnr'/file)
PY
python3 boards/tangnano20k/sdram/analyze_implementation.py \
  output/tangnano20k/control-area-analysis-replay/baseline-fresh \
  --out output/tangnano20k/control-area-analysis-replay/baseline.json
python3 boards/tangnano20k/sdram/analyze_implementation.py \
  output/tangnano20k/control-area-analysis-replay/mru-ram \
  --out output/tangnano20k/control-area-analysis-replay/optimized.json
python3 boards/tangnano20k/sdram/check_cache_mru.py
```

For a fresh hardware build, decompress the frozen CPU into a generated RTL
directory and select its absolute path with `SDRAM_RTL_FILE`. Use
`SDRAM_FREQ_MHZ=48`, `SDRAM_CPU_FREQ_MHZ=48`, `SDRAM_RVC=1`,
`SDRAM_CACHE=1`, `SDRAM_CACHE_WAYS=2`, `SDRAM_CACHE_LINE_BITS=11`,
`SDRAM_PHASE_DEGREES=135`, `SDRAM_PLACE_OPTION=2`, and a dedicated `SDRAM_OUT`.
Select an **absolute** `SDRAM_CACHE_RTL` path for either cache snapshot, then
run `boards/tangnano20k/sdram/build.sh pipeline`. This is an experimental
build, not a change to the accepted `fprisc-48` preset.

The analysis captures internal FPGA timing only. The external SDRAM timing
model remains incomplete, and the physical tests are three classifier runs
at ambient conditions, not electrical or endurance qualification.
