# Tang Nano 20K SDRAM experiment

The [stage-enable record](../../../docs/2026-10-29-STAGE-ENABLES-AND-REGISTERED-HOLD.md)
gives each pipeline stage (and the pipeline itself) its own clock-enabled
register and turns the cache hold into a clock enable rather than a
machine-wide next-state select. At 48/48 MHz it reports 13,293 logic cells
against 15,911 (16.5% fewer) at essentially the same Fmax, with placement
option 3 the better mode (51.712 MHz, +1.495 ns).

The [four-cycle cache port record](../../../docs/2026-10-29-SDRAM-PIPELINE-FOUR-CYCLE-PORT.md)
registers the cache's BSRAM read return, making its CPU port four logical
clocks for the SDRAM images only; the BRAM image keeps three. It also adds the
build knobs for an over-constrained placement target, a region constraint and a
placement/cache sweep. The recorded RTL regressions pass; no timing result is
claimed.

The [integration report](../../../docs/2026-10-19-TANGNANO20K-INTEGRATION.md) records the combined
cache and architecture-test branches, the selected decode-hazard timing
change, and fresh simulation and physical regressions at CPU72/SDRAM54.
The selected build uses 15,827 logic cells and closes internal timing at
+0.008 ns worst setup slack; that tight margin does not qualify SDRAM I/O.

The [cache and clock-bridge report](../../../docs/2026-10-19-TANGNANO20K-SDRAM-CACHE.md) makes the historical one-way 72/54 MHz
pipeline 2.33 times faster on the board's FP-RISC classifier (2.84 s against
6.61 s): a 64 KiB cache, refills that drain only stores to their own line, and
an asynchronous-FIFO clock bridge with posted writes. `run_perf.py` simulates
where the cycles go and matched the board within 1.4%. The current experimental
default is two-way with `SDRAM_CACHE_WAYS=2` and `SDRAM_CACHE_LINE_BITS=11`
(64 KiB total); `fprisc-48` deliberately preserves the validated one-way
`WAYS=1`, `LINE_BITS=12` geometry. Two-way timing and physical qualification
are separate from the historical results.

The [controlled benchmark matrix](../../../docs/2026-10-28-CONTROLLED-BENCHMARK.md)
holds the guest binary, 72/54 MHz clocks, 64 KiB capacity and write policy fixed
while varying compressed branch prediction, associativity and bridge response
latency. It includes exact replay inputs and a separate 48 MHz board comparison.
`prepare_benchmark_matrix.py --image IMAGE --elf ELF --out NEW_DIRECTORY`
freezes a small-classifier guest with a 72 MHz timer and generates both CPU
variants; `benchmark_matrix.py --out NEW_DIRECTORY` runs all eight cases.
Use `--resume` to reuse source- and output-validated results. Each result must
pass the independent classifier oracle as well as successful exit and counter
checks. `run_perf.py` also supports `--build-only`, `--run-only`, bounded `--jobs`
and `--timeout`, and optional named-port `--profile-cpu` observations. Generate
`SdramPipelineObserved` for profiling and CPU-level RTL tests; ordinary board
builds continue to use `SdramPipeline`. Historical matrix receipts without a
profiling-ABI field explicitly select the archived 2026-10-28 layout.
`--stall-breakdown` attributes every measured cycle to one issue-slot cause
(named-v2 ABI); generate the observed top with `-DPIPELINE_SLOT_OBSERVATIONS`
for it. See [STALL-BREAKDOWN](../../../docs/2026-10-30-STALL-BREAKDOWN.md).

The [structural experiment plan](../../../docs/2026-10-30-STRUCTURAL-EXPERIMENTS.md)
records the baseline, acceptance criteria and pending experiments. For example:

```sh
cabal run clash -- -isrc -hide-package simple-risc -DRISCV_COMPRESSED \
  src/SdramPipelineObserved.hs --verilog -fclash-clear -outputdir output/observed
python3 boards/tangnano20k/sdram/check_pipeline_rtl.py --compressed \
  --generated output/observed/SdramPipelineObserved.topEntity --simulator verilator
cabal run -v0 pipeline-layout > output/pipeline-layout.json
```

`analyze_implementation.py` now retains detailed physical endpoint pins,
per-hop cell and route delays, LUT drivers and synthesized CE loads. Optional
`--generated`, `--layout` and repeated `--register-layout REGISTER=TYPE` attribute
bits to source fields with checked register widths and explicit ownership
bindings. They are analysis metadata; functional tests use named ports.

`diagnose_output.py --build-only --out NEW_DIRECTORY` builds a memory-signature
workload and a separate paced reporter. Physical runs require `--freq-mhz` and
`--bitstream` for the image already loaded into SRAM; they keep one UART
descriptor open. `--uploads-only` never executes its zero/ones/sequence
payloads: it compares the receive CRC with three memory readback CRCs.
The RTL checker supports the same upload-only experiment through
`--boot-loader --loader-command U --upload-pattern zero --upload-words 512`.

The [control-fanout and area analysis](../../../docs/2026-10-28-CONTROL-FANOUT-AND-AREA.md)
traces the global hold/break and execution-mode enables, and replaces two-way
MRU registers with a synchronous distributed-RAM lookup. A controlled 48 MHz
build uses 18.79% fewer logic cells with identical classifier counters.
`check_cache_mru.py` compares replacement decisions with the original policy
and tests lookup/write collisions and a broken-bypass negative control.
`analyze_implementation.py BUILD --out REPORT.json` extracts Gowin utilization,
module primitives, high-fanout drivers and leading setup paths. The clock
ceiling remains a separate timing and physical-qualification question.

The [write-update follow-up](../../../docs/2026-10-19-TANGNANO20K-SDRAM-WRITE-UPDATE.md) keeps lines valid on
store hits (`WRITE_UPDATE`, now default 1): 2.06 s, 1.38 times faster again.
It failed on the board until the data array was built from 512x32 BSRAM
banks; Gowin's narrow BSRAM slices corrupted other words under isolated
writes. `run_gls.py` simulates a whole Gowin netlist under Verilator
(`gowin_models.v`), and `bsram-rdw/` probes block-RAM behaviour on the board.

The [I/O timing audit](../../../docs/2026-10-18-TANGNANO20K-SDRAM-IO.md) records the missing embedded
memory bounds, a sourced constraint generator and the strict model gate.
Current builds explicitly distinguish internal STA from full SDRAM I/O
signoff; the supplied QN88 model remains incomplete.
`SDRAM_PHASE_DEGREES` selects an experimental memory-clock phase in
22.5-degree steps. The [phase checks](../../../docs/2026-10-18-TANGNANO20K-SDRAM-IO.md#local-phase-experiments-while-waiting-for-the-vendor)
verify PLL/SDC alignment and functional read-window sensitivity; they do not
qualify the electrical interface.

The [physical 54 MHz sweep](../../../docs/2026-10-18-TANGNANO20K-SDRAM-PHASE-SWEEP.md) tested every
22.5-degree step: 90, 112.5, 135 and 157.5 degrees passed all 8 MiB twice;
all other steps failed despite identical passing internal STA. The tested
CPU72/SDRAM54 image at 135 degrees was restored and FP-RISC numeric checks
passed. This is an ambient board result, with full I/O signoff still pending.

The board's 64-Mbit, 32-bit SDR SDRAM is usable as 8 MiB of main memory.
The [pipelined experiment](../../../docs/2026-10-16-TANGNANO20K-SDRAM-PIPELINE.md) uses a unified cache
(64 KiB since 2026-10-19, originally 2 KiB) with 16-byte lines, four posted
masked writes and four-word SDRAM bursts. Its CPU port is four logical clocks
since 2026-10-29: the word after the BSRAM read is registered, and only
external-memory images pay that extra cycle.
`build.sh core` or `pipeline` selects it; `serial` retains the earlier 1 KiB
word-cache image described in the historical results below. The BRAM image
remains separate. RV32IM is the default. The optional C frontend passes board
checks and six FP-RISC stress programs at 27 and 48 MHz. Four-beat variants
use a 135-degree SDRAM clock; the legacy single-word variants keep 225 degrees.
The pipeline also exposes the [microSD SPI byte port](../../../docs/2026-10-18-TANGNANO20K-SDRAM-SD-SPI.md)
at `0x10001000`, with a capability register at `+0x0c`; DMA remains unmapped.

## Cached 66 MHz experiment (2026-10-06)

A 256-entry direct-mapped cache stores one physical word per entry, using two
block RAMs. It has synchronous lookup, a valid bit and full physical tags.
Writes invalidate the indexed entry, go through to SDRAM and complete only
after the backing write. Reset sweeps all entries before accepting requests.
There are no dirty lines or separate instruction/data copies. Data stores and
the boot ROM's loader writes use physical word addresses, keeping code uploads
and modified instructions coherent. Ctrl-C leaves the cache transaction to drain with the
existing wrapper. Refresh continues independently during hits.

Measured repeated reads of a 512-byte array (25,600 reads, checksum 1,625,600):

| Image | Measured cycles | Time |
| --- | ---: | ---: |
| Uncached 54 MHz | 2,933,382 | 54.322 ms |
| Cached 54 MHz | 2,389,660 | 44.253 ms |
| Cached 66 MHz | 2,389,648 | 36.207 ms |

Counts vary by a few clocks when refresh overlaps the timed section. The
uncached reference was rebuilt with `SDRAM_CACHE=0` and rechecked on the board.
Cache alone saves 18.5% of cycles; cache plus clock gives about 1.50x throughput
on this workload. This is a small repeated-read workload, not a general FP-RISC
speedup claim; streaming misses and write-heavy workloads can pay lookup overhead.
`benchmark.c` also executes code patched through data stores, with
`fence.i`. (Until 2026-10-11 it also checked the zero-address alias.)

Cached 54 MHz STA reports Fmax 70.692 MHz, +4.373 ns setup slack. The tested
66 MHz placement reports Fmax 66.165 MHz, +0.038 ns, zero setup/hold violations.
Its limiting paths are routed logic inside the processor, not the cache RAM.
The margin is small and full SDRAM I/O signoff is still outstanding. 66 MHz is
an experimental board-tested setting, not completion of the 96 MHz roadmap gate.
The controller retains its existing <=66.7 MHz timing parameters; higher SDRAM
clocks need revised CAS/delay parameters and a wider initialization cycle counter,
or a separate SDRAM clock with a verified clock-domain bridge.

At 66 MHz the full-capacity tester passes all six phases, 12,582,912 comparisons,
including masked writes and the frequency-adjusted 250 ms retention pause.
The cached CPU passes 38,400 RV32I and 30,720 RV32M reference comparisons,
3,852 bus checks, 270 counter checks, 267 trap checks, 15 finisher cases,
arithmetic/UART/Ctrl-C/reload tests, alias/instruction coherence and the full
1 MiB working set/all-bank/end-of-memory checks. Cache simulation additionally
checks hits, conflicts, write completion, reset invalidation and memory backpressure.

The complete FP-RISC builtin smoke/CSR/refusal/recovery harness passes at
66 MHz on the zero alias. The high-linked 2 MiB allocation fixture also passes,
including its 32 sampled words, final byte, free and successful exit.

Tested cached processor SHA-256:
`0d4e7e54fe6e70ea7f268aa8f3ce8337ffa0c8065c3caec4cbdd2365ffc06565`.

## Original uncached validation (2026-10-06)

The standalone tester passes all 2,097,152 words in six phases: zero, ones,
address hash, complemented hash, zero plus four independent byte-mask writes,
and reverse-order retention readback after a 250 ms pause. Refresh continues
during that pause. Total: 12,582,912 word comparisons, zero mismatches. The
address hash is an odd multiply/XOR, so each word address has a distinct value
and bank/row/column aliases cannot pass the hash phase. Unselected byte lanes
carry poisoned values during masked writes, so ignoring the mask cannot pass. Host checking requires
all six reports and exact cumulative coverage; silence/partial output fails.
A behavioral protocol simulation exercises readiness dropping between request
preparation and acceptance; injected ignored masks fail on all 32 test words.
This simulation checks the tester, not SDRAM electrical timing.

Vendor STA at 54 MHz reports 99.307 MHz estimated maximum, +8.449 ns setup
slack and zero setup/hold violations for the final standalone tester. The
processor placement reports 61.175 MHz, +2.172 ns and zero setup/hold violations.
These are internal logic checks; SDRAM I/O setup/hold constraints and shifted
clock phase still require full timing signoff. The physical tests above are
board evidence under the current conditions, not PVT stress qualification.
The oscillator generic-routing warning remains.

The processor passes 3,852 bus/RX checks, 15 finisher cases, 270 counter checks,
267 traps, arithmetic/UART/reset/reload/memory tests and 34,560 RV32IM reference
comparisons at 54 MHz. Counter tests use the SDRAM mode: elapsed cycles must
include memory waits, while retirement and rollover checks retain exact values.
All Haskell suites pass, including 36 SimpleRisc properties.
A high-address C image passes a full 1 MiB working-set write/verify, all four
bank ends and mixed byte writes near the last RAM word. It saves/restores
stack words when testing those addresses.
The existing complete FP-RISC builtin harness also passes on the zero alias.
High-linked FP-RISC allocates 2 MiB, writes/verifies 32 word samples at 64 KiB
intervals, checks the final byte, frees the allocation and exits successfully.
An earlier 2,048-sample FP-RISC fixture did not finish within the 30/60 second
budgets; instrumentation confirmed allocation completed. That denser loop is
not a passed test and its performance/cause has not been fully profiled.

Bitstream SHA-256:

- Standalone: `9cf37316ed26515007261bec14741ee318422820bc8bd834c80598bfb8609436`
- Processor: `815d54bf81454c37809e1445f31490990ff1c881f566c15b7c247d6809219b5a`

## Memory and host contract

Since 2026-10-11 this image shares the BRAM image's boot ROM and memory map
([../README.md](../README.md)); the zero-address alias and the `H` command are
gone.

- `0x80000000..0x807fffff`: full 8 MiB SDRAM, word indices retain 21 bits.
- `0x00000000..0x000007ff`: the boot ROM, read from block RAM without an SDRAM
  request. Finisher, BOOTCAUSE and UART addresses match the BRAM image.
- The ROM's `P` loads at `0x80000000` with the existing 16-bit count and
  64 KiB image limit; `R` runs there. Data/BSS/heap/stack can use the rest of
  SDRAM.
- `M` clears the first 64 KiB, not all SDRAM; startup code initializes BSS.
- `Q` uses a 32-bit little-endian word count and accepts up to 2 MiB, with
  the loader stack at the top of RAM, `0x80800000`. `V` sends the uploaded words'
  XOR readback as eight lowercase hex digits and newline. `H` runs from
  `0x80000000`; `T` probes the UART with `DONE`. This is the same framing as
  the FP-RISC Base uploader. The separate BRAM ROM bounds `Q` at 65,280 bytes.
  Ctrl-C cancels a running program's work and drains an outstanding memory
  operation; inside the ROM it is an ordinary byte.
- Cycle counters count physical memory wait clocks, including cache lookup.

The retained `serial` image's `SdramSimpleRisc` wraps the serial core. It captures full addresses
before the core's block RAM index, sends boot ROM reads to a small block RAM, stops controller advancement during an
outstanding memory transaction, buffers received UART data and continues the
cycle counter. One outstanding transaction and registered data keep instruction
fetch, byte-store read/modify/write and loader accesses ordered. Refresh gets
priority before accepting work and runs at least every roughly 10 us.
The [new pipeline report](../../../docs/2026-10-16-TANGNANO20K-SDRAM-PIPELINE.md) describes its fixed-latency
port, physical holds, burst refills and posted writes.

## Build and test

```bash
boards/tangnano20k/sdram/build.sh test
openFPGALoader -b tangnano20k output/tangnano20k/sdram-test/impl/pnr/sdram_test.fs
python3 boards/tangnano20k/sdram/test_protocol.py
python3 boards/tangnano20k/sdram/check.py
boards/tangnano20k/sdram/build.sh core
openFPGALoader -b tangnano20k output/tangnano20k/sdram-core/impl/pnr/sdram_test.fs
python3 boards/tangnano20k/sdram/check_core.py
python3 boards/tangnano20k/check_counters.py --freq-mhz 54 --sdram
```

Placement experiments use three extra settings. `SDRAM_TARGET_MHZ` raises the
placer's target above the real clock (the SDC still constrains the real
clocks), `SDRAM_REGION_CST` appends a FloorPlanner-generated constraint file to
`pins.cst`, and `SDRAM_SKIP_TIMING_CHECK=1` records a build that misses the
over-constrained target. `sweep_place.py` runs the combination:

```bash
python3 boards/tangnano20k/sdram/sweep_place.py --out output/tangnano20k/place-sweep \
  --base-freq-mhz 72 --memory-freq-mhz 54 --target-pct 10 \
  --place-options 0 1 2 3 4 --cache-line-bits 11
```

It writes `sweep-results.json` beside the per-case build directories. Neither
the sweep nor the region hook qualifies SDRAM I/O.

Five synthesis and routing options are reachable as well; all are unset by
default, and `SDRAM_PRESET=fprisc-48` rejects them:

| Variable | `set_option` | Range |
|---|---|---|
| `SDRAM_MAP_OPTION` | `-map_option` | 1-4 (3/4 are LUT5-oriented for timing) |
| `SDRAM_ROUTE_OPTION` | `-route_option` | 0-2 (1 spends compile time on routing) |
| `SDRAM_REPLICATE` | `-replicate_resources` | 0/1 (Arora V/III only) |
| `SDRAM_MAX_FANOUT` | `-max_fanout` | integer (global `syn_maxfan`, default 1000) |
| `SDRAM_ROUTE_MAXFAN` | `-route_maxfan` | 1-100 (routing-tree fan-out, default 23; 8 is worth ~0.5 ns here) |

Two of them are worth having on this design. `SDRAM_ROUTE_OPTION=1` took the
2026-10-29 netlist from 54.863 MHz to 63.401 MHz at identical area, and adding
`SDRAM_MAP_OPTION=3` (LUT5-oriented mapping, 13 % more logic) reached
74.483 MHz; since then deferring the branch table's update register by a cycle
reached 70.901 MHz and +2.563 ns for the RV32IMC image. With those, the RV32IMC
image runs on the board at 54 MHz with the full check suite passing. 60 MHz is not usable, and the cause is the processor,
not the memory: the standalone tester (`build.sh test`, then `check.py`) passes
all 8 MiB at 60 and at 66 MHz, while the processor's reported Fmax saturates at
63.6-64.5 MHz once the constraint bites. Raising the processor clock further
means cutting its own critical path; the SDRAM has margin above 66 MHz. See
[HOLD-ENABLE-AND-MRU-LOOKUP](../../../docs/2026-10-29-HOLD-ENABLE-AND-MRU-LOOKUP.md).

The host starts the standalone test after opening the UART, preventing lost
initial reports. Build uses the licensed macOS Gowin flow and rejects internal
timing violations. Programming is SRAM-only. Both clocks run at the selected frequency. The default remains 54 MHz.
`SDRAM_CACHE=0` with `build.sh serial` builds the earlier uncached comparison.
The earlier serial image is board-tested at `SDRAM_FREQ_MHZ=66`; that result
does not validate the new pipeline at the same clock.
Larger loader frames (images over 64 KiB) remain future work.

To reproduce the historical cached serial image:

```bash
SDRAM_FREQ_MHZ=66 SDRAM_OUT="$PWD/output/tangnano20k/sdram-cache66" \
  boards/tangnano20k/sdram/build.sh serial
openFPGALoader -b tangnano20k output/tangnano20k/sdram-cache66/impl/pnr/sdram_test.fs
python3 boards/tangnano20k/sdram/check_cache.py --freq-mhz 66
python3 boards/tangnano20k/sdram/check_core.py --freq-mhz 66
```

Use the same frequency for `build.sh test`, `check.py --freq-mhz 66`, all
processor check scripts and the FP-RISC runner. `SDRAM_OUT` must be absolute.
The standalone tester bypasses the cache to exercise every SDRAM word.

## Controller provenance

`sdram.v` derives from nand2mario's Apache-2.0 controller at
https://github.com/nand2mario/sdram-tang-nano-20k,
commit `918ae4143eed676d29b706df6ec7ebcb61e257c1`. `LICENSE` retains its license.
Changes here provide 32-bit writes with four byte enables and registered word
readback. Four-word bursts use an earlier CAS2 capture and a 135-degree output
clock to provide a wider read window; single-word mode retains its later capture
and 225-degree clock. `memory.v`
adds request/completion handling and autonomous refresh. The embedded-memory
port names let Gowin connect the dedicated SDRAM pins; the pin report confirms
those connections.

The cache's standalone simulation can be reproduced with:

```bash
iverilog -g2012 -s cache_tb -o /tmp/sdram-cache-tb \
  boards/tangnano20k/sdram/cache.v boards/tangnano20k/sdram/cache_tb.v
vvp /tmp/sdram-cache-tb
```
