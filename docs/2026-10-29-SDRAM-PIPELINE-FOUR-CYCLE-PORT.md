# Four-cycle cache port, and placement-sweep tooling

Kind: implementation change with RTL regressions, 2026-10-29. Baseline is
`bb1104b` (ROM identity and CRC-verified upload record). No Gowin synthesis,
placement or STA was run for this page, so no timing or clock-rate result is
claimed here.

## What changed

### 1. A register after the cache's BSRAM read (port latency 4)

`pipeline_cache.v` already selected the BSRAM word in the same logical clock
that the CPU consumed it:

```text
cpu_address -> a1 -> a2 -> bank word / ROM -> store+fill forwarding -> cpu_rdata
```

The forwarding mux therefore sat behind a registered bank select, a registered
one-hot AND-OR return and the held/ROM select, in one clock.

`cpu_word` now keeps that old-timing word (the write-update store path still
merges into it, so `store_word` and the `words_data` write-back are unchanged)
and `cpu_rdata_return` repeats it one *advancing* edge later. `cpu_rdata` is
now `cpu_rdata_return`, so the port is four logical clocks. Both registers are
loaded only while the CPU is advancing, so a cache hold freezes the whole
return path with the request slot and both lookup stages; the CPU still reads a
stable word on the edge that releases it.

The miss return keeps its existing mechanism: `cpu_word` takes the final beat
(or `fill_target`) on the completion edge, and the release edge forwards the
same word again through `filled`/`fill_data`, so `cpu_rdata` holds it across
the release.

### 2. The CPU pays the extra clock only for external memory

`cpuExternalMemory` distinguishes the SDRAM image (`SdramPipeline`) from the
BRAM image and the Haskell test model. In `SimpleRisc.hs`:

- `pInflight` is four entries; `inflightArrival` selects entry 2 for the
  internal block RAM and entry 3 for the external cache, so the internal port's
  arrival timing is unchanged.
- A load's `mWait` is 3 for an external cache and still 2 otherwise. Stores are
  unchanged: the pipelined store path writes lanes at commit and never reads
  back.

Everything else — the fetch queue, `pOutstanding < 4`, store ordering,
cancellation and the phases — is untouched. Because the outstanding cap is
still four and the in-flight pipeline is now four deep, a full queue and a full
in-flight pipeline cannot occur together, so the four-entry fetch ring keeps
its capacity.

### 3. Placement and cache-sweep build knobs

`sdram/build.sh` gained three settings:

| Setting | Effect |
|---|---|
| `SDRAM_TARGET_MHZ` | integer placer/optimizer target above `SDRAM_CPU_FREQ_MHZ`, wired into `-frequency`/`-global_freq`; the SDC still constrains the real clocks |
| `SDRAM_REGION_CST` | appends a FloorPlanner-generated constraint file to `pins.cst` |
| `SDRAM_SKIP_TIMING_CHECK` | records a build that misses the over-constrained target instead of failing it |

`sweep_place.py` runs `SDRAM_PLACE_OPTION` 0-4 across one or more cache
geometries at a target `--target-pct` (default 10%) above the real clock, parses
each `sdram_test.tr` for Fmax and worst setup slack, and writes
`sweep-results.json`. The region hook deliberately does not invent region
syntax: a coordinate set must come from the FloorPlanner for the actual
GW2AR-18QN88 floorplan.

## Verification

All of the following pass in this working tree:

- `cabal build all`, `cabal test`: the internal block-RAM path and the Haskell
  model are unchanged, including the cycle-count assertions for pipelined
  loads (11 cycles for a full-fetch load, 9 for a word store) and the
  reference-model and interrupt-transparency properties.
- `check_pipeline_cache.py`: all 18 cases, with the testbench reply check moved
  from `logical-3` to `logical-4`, plus the `cpu_word` mutation for the
  "final beat captured" negative control.
- `check_cache_mru.py`, `check_clock_bridge.py`, `check_fence_assertion.py`:
  unchanged cache replacement, clock-crossing and instruction-fence checks.
- `check_pipeline_rtl.py` against freshly generated `SdramPipeline` Verilog:

| generated top | cache | guest | result |
|---|---|---|---|
| uncompressed | two-way, `LINE_BITS=11` | base guest | PASS, 101 fills, 20 writes, 58,049 held clocks |
| uncompressed | two-way, `LINE_BITS=7` | base guest | PASS, 103 fills, 20 writes, 56,134 held clocks |
| compressed | two-way, `LINE_BITS=11` | base guest | PASS, 91 fills, 20 writes, 57,745 held clocks |
| uncompressed | one-way, `LINE_BITS=12` | `I`/`U`/`C`/`G` ROM upload | PASS, `OK ee8a36e9`, `LDONE` |
| uncompressed | one-way, `LINE_BITS=7` | `I`/`U`/`C`/`G` ROM upload | PASS |
| compressed | one-way, `LINE_BITS=12` | `I`/`U`/`C`/`G` ROM upload | PASS |

The guests cover instruction fetch through the queue, aligned and masked
stores, byte/halfword loads, cache aliases, `fence.i` epochs, eight timer
interrupts across misses, the counters and Ctrl-C, so the changed fetch depth
and load wait are exercised rather than assumed. The one-way 64 KiB geometry is
the one `fprisc-48` selects.

`SDRAM_PRESET=fprisc-48` now pins `SDRAM_TARGET_MHZ=48` and rejects
`SDRAM_REGION_CST` and `SDRAM_SKIP_TIMING_CHECK`, so the validated preset
cannot silently pick up a different placement target or a weaker gate. The
boot-ROM, upload, preset-manifest and benchmark-guard contract tests still
pass.

## Costs and open items

- One extra cycle per load and per cache-port word, plus the extra
  `pInflight` entry and the two 32-bit return registers. `run_perf.py` and the
  frozen classifier counters will quantify the CPI cost; they have not been
  re-run here.
- The return register does not remove the bank-select cone, it only removes it
  from the CPU's setup requirement. Whether that moves the critical path out of
  the cache needs a Gowin build.
- SDRAM I/O remains unqualified; the sweep measures internal placement only.
- The remaining review items are unchanged: per-stage enable registers with
  fanout duplication (item 1) and a registered `hold_cpu` with a skid buffer
  (item 3).
