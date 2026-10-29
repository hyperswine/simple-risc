# The hold enable and the MRU lookup: two paths, and what the placer does with them

Kind: implementation change with Gowin builds, RTL regressions and a board run,
2026-10-29. Every number is 48/48 MHz, two-way, `LINE_BITS=11`, placement 2
unless stated. The baseline is the split-module build of the same day
(56.638 MHz, +3.177 ns), whose two leading path groups were:

| Rank | Path | Delay |
|---|---|---:|
| 1 | `core/request_32` → `cache/entry_mru/D` | 17.621 ns |
| 2-25 | `core/ds5_731` → `core/c$running_app_arg_*/CE` | 15.4-16.4 ns |

The second group is the processor's hold clock enable: 24 of the 25 worst paths
were the same net driving the clock enable of the pipeline register. This page
is what came of attacking both.

## What the two paths actually are

**The hold enable.** `holding = memory_hold & ~breaking`, where
`breaking = emergency & ~cpuInRom`. Every pipeline flop loads unless the cache
holds the core, so one net reaches about 5,000 clock-enable pins.

**The MRU lookup.** One replacement bit per set, read asynchronously out of
distributed RAM at the CPU's address and registered into `entry_mru`. With
`LINE_BITS=11` that is a 2,048-deep LUT mux between an address register and the
bit's own flop.

## Changes

1. **`breaking` and the UART byte accept read registers, not the assembled
   pipeline** (`src/SdramPipeline.hs`). `cpuInRom` only ever comes from the
   machine register, and the held byte only from the held-state register, so
   reading them through `running` only added record-select logic in front of
   the enable.
2. **Every pipeline register loads on the hold enable alone.** The stage
   payload registers used `~holding & stageLoad[i]`. Synthesis merged that with
   the pipeline's plain `~holding` — they share a factor — so the pipeline's
   clock enable inherited the entire stage-advance cone, which is a function of
   the frozen pipeline registers. The leading paths launched at `ds5_732`, a
   payload bit, instead of at `emergency`: proof that stage logic had leaked
   into the pipeline's enable. A stage that does not advance now loads its own
   payload back, exactly as the pre-split design did.
3. **The replacement bit moved into block RAM** (`pipeline_cache.v`). The tags
   and data already live in BSRAM, where the address stops at the hard block's
   own input register. The MRU now does the same, with the write-through for a
   write that lands on the address being read carried in registers one cycle
   later, so the memory's read-during-write result is never observed. The bit
   is a replacement *hint*: it never changes the word a lookup returns, which
   is why it is the one array where discarding that result is safe.

`check_cache_mru.py` was updated for the new read-through shape; it still
compares every decision against the register-vector reference model, poisons
the RAM output on collisions, and refuses a build with the read-through
removed.

## Result

| 48/48 MHz, two-way, `LINE_BITS=11` | Baseline | Changes 1-2 | Changes 1-3 |
|---|---:|---:|---:|
| Logic | 12,988 | - | **11,950** (58 %) |
| CLS | 8,110 | - | **7,655** (74 %) |
| Registers | 5,381 | - | **5,382** |
| BSRAM | 37 | 37 | **38** (83 %) |
| Reported core Fmax | 56.638 MHz | 55.612 MHz | 54.863 MHz |
| Worst setup slack at 48 MHz | +3.177 ns | +2.852 ns | +2.606 ns |
| Worst path | MRU lookup | hold enable | hold enable |
| Same source with `-route_option 1` (target 53 MHz) | - | - | **63.401 MHz**, +5.061 ns |

The MRU lookup is gone from the leading paths: after change 3 the worst 25
paths are all the hold enable. The design is also 8 % smaller in logic and 6 %
smaller in CLS, because the block RAM replaces a LUT mux.

## What the measurements say that the table cannot

**The peak did not move, and the reason is the placer, not the logic.** In the
"changes 1-2" build the hold enable's cone is one LUT deep and the net's
fan-out tree is 7 nodes; in the "changes 1-3" build the identical netlist
produces a 58-node path for the same enable. GowinSynthesis and the router
choose how much logic to fold into a wide enable's driver and how deep to build
its buffer tree, and that choice moves the reported Fmax by 4-8 MHz between
builds of the same source. Placement 3 of the "changes 1-3" netlist reports
48.990 MHz, so the spread across two placement modes of one netlist is larger
than the spread between the netlists. Any single number here is one sample of a
wide distribution; `-route_option 1` is the only knob measured today that moves
the distribution itself.

**Routing effort is worth more than any of it.** The design is routing
dominated, and the stock `-route_option 0` gives up early. `-route_option 1`
spends compile time looking for a better routing solution and lands the same
netlist at **63.401 MHz (+5.061 ns)** — 8.5 MHz above the stock-option build of
that netlist and 6.8 MHz above the day's baseline — with an identical netlist,
identical placement mode and identical area. It shortens the hold enable's
58-node tree by about 2.5 ns on its own. That build also carried
`SDRAM_TARGET_MHZ=53`; the target alone was worth nothing, so the routing
effort is what moved it, but the exact command is:

```bash
SDRAM_FREQ_MHZ=48 SDRAM_CPU_FREQ_MHZ=48 SDRAM_CACHE_WAYS=2 \
SDRAM_CACHE_LINE_BITS=11 SDRAM_PLACE_OPTION=2 SDRAM_TARGET_MHZ=53 \
SDRAM_ROUTE_OPTION=1 SDRAM_OUT="$PWD/output/tangnano20k/mru-bram-48-t53route" \
boards/tangnano20k/sdram/build.sh pipeline
``` `SDRAM_TARGET_MHZ=53` (over-constrain
the placer by 10 %) changed nothing: it produced a build identical to
`SDRAM_TARGET_MHZ=48`, and placement 3 was worse than placement 2.

**The remaining wall is fan-out, not depth.** The hold enable's buffer tree
alone costs 9-16 ns of the 20.8 ns period, whichever way the driver is built.
No expression change fixes that: the design has one control signal that 5,000
flops must see. What would fix it, in rough order of effort:

1. Fewer flops behind the hold enable. The fetch queue, the in-flight window
   and the branch table (~1,500 bits) are register arrays that could become
   RAM and so lose their clock enables.
2. A cache that can be told, one cycle early, that it will hold. The enable
   would then come straight off a flop instead of off a LUT.
3. A tool that supports fan-out replication for control signals on this
   device. `set_option -replicate_resources` is Arora V/III only, and
   `syn_maxfan` explicitly excludes clock, enable and reset nets.

## New build knobs

`build.sh` gained the synthesis and routing options that were previously
unreachable from this flow. All are unset by default, which leaves the stock
tool behaviour:

| Variable | Option | Range | Note |
|---|---|---|---|
| `SDRAM_MAP_OPTION` | `-map_option` | 1-4 | 3/4 are LUT5-oriented for timing |
| `SDRAM_ROUTE_OPTION` | `-route_option` | 0-2 | 1 spends compile time on routing |
| `SDRAM_REPLICATE` | `-replicate_resources` | 0/1 | Arora V/III only |
| `SDRAM_MAX_FANOUT` | `-max_fanout` | integer | global `syn_maxfan`, default 1000 |
| `SDRAM_ROUTE_MAXFAN` | `-route_maxfan` | 1-100 | routing-tree fan-out, default 23 |

`SDRAM_PRESET=fprisc-48` rejects all five, so the board preset stays a fixed
configuration. Pinning `SDRAM_ROUTE_OPTION=1` in the preset is the obvious next
step and was left alone here: it would change every preset build's compile time
and its recorded timing, which is a separate decision from this page.

## Verification

- `cabal test`: 66 + 8 pass.
- `check_pipeline_cache.py`: 18/18. `check_cache_mru.py`: 5/5, including the
  poisoned-read and missing-read-through cases. `check_clock_bridge.py` and
  `check_fence_assertion.py` pass.
- `check_pipeline_rtl.py` for IM and IMC: guest program, masked stores,
  `fence.i`, traps, eight timer interrupts across misses, counters, Ctrl-C.
- Board, bitstream `ca1574ad7bceca02fff1ce427f8a82631b0d31da1b8ae8e39fad19d4e7f04cb9`
  (`output/tangnano20k/mru-bram-48-p2`, stock options), 48 MHz: `check_core`
  (1 MiB working set), 38,400 RV32I, 30,720 RV32M, 3,852 bus, 5 C programs with
  Ctrl-C recovery, 27 counter and 27 interrupt checks — all PASS.
- Board, bitstream `fc02e040c9b6c3e80c40ee04d5a4d92e6117a8281896fdcf92e748b45c4de42b`
  (`output/tangnano20k/mru-bram-48-t53route`, the 63.401 MHz build), 48 MHz:
  `check_core` and the five-program `check_processor` run — PASS.
