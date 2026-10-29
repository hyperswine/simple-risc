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
| Same source, `-route_option 1` (target 53) | - | - | 63.401 MHz, +5.061 ns |
| Same source, `-route_option 1 -map_option 3` | - | - | **74.483 MHz**, +7.407 ns |

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
wide distribution; the build options below are what move the distribution
itself.

**Two build options are worth more than any of it.** The design is routing and
mapping dominated, and the stock effort gives up early. Both options move the
same netlist without touching it, and both raise the clock well past the day's
baseline:

| 48 MHz target, two-way, `LINE_BITS=11`, placement 2 | Logic | CLS | Fmax | Slack |
|---|---:|---:|---:|---:|
| stock (`-route_option 0 -map_option 1`) | 11,950 (58 %) | 7,655 (74 %) | 54.863 MHz | +2.606 ns |
| `-route_option 1` | 11,950 | 7,655 | 63.401 MHz | +5.061 ns |
| `-route_option 1 -map_option 3` | 13,521 (66 %) | 8,239 (80 %) | **74.483 MHz** | **+7.407 ns** |
| `-route_option 1 -map_option 4` | 20,494 (99 %) | - | does not fit | - |

- `-route_option 1` spends compile time looking for a better routing solution.
  It shortens the hold enable's 58-node tree by about 2.5 ns on its own.
- `-map_option 3` allows synthesis to grow the LUT count for a LUT5-oriented
  mapping. It costs 13 % more logic and buys 11 MHz, because the design's depth
  is a chain of narrow LUTs rather than one wide function.
- `-map_option 4` reaches 99 % logic utilisation and the placer fails with nine
  SSRAMs unplaced: there is no room for it on a GW2AR-18.

Two more options were measured and did not help: `SDRAM_TARGET_MHZ=53`
(over-constrain the placer by 10 %) produced a build identical to
`SDRAM_TARGET_MHZ=48`, and `SDRAM_PLACE_OPTION=4` produced a build identical to
placement 2. Placement 3 is worse (48.990 MHz). `SDRAM_ROUTE_MAXFAN` was not
evaluated: both probe runs aborted on a Gowin licence-server error before
reaching placement.

```bash
SDRAM_FREQ_MHZ=48 SDRAM_CPU_FREQ_MHZ=48 SDRAM_CACHE_WAYS=2 \
SDRAM_CACHE_LINE_BITS=11 SDRAM_PLACE_OPTION=2 SDRAM_TARGET_MHZ=53 \
SDRAM_ROUTE_OPTION=1 SDRAM_MAP_OPTION=3 \
SDRAM_OUT="$PWD/output/tangnano20k/push48-map3" boards/tangnano20k/sdram/build.sh pipeline
```

## 54 MHz on the board

With those two options the design has enough margin to leave 48 MHz. Two images
were built, flashed and run at 54/54 MHz with the same options and placement 2:

| 54/54 MHz, two-way, `LINE_BITS=11`, `-route_option 1 -map_option 3` | RV32IM | RV32IMC |
|---|---:|---:|
| Fmax at the 54 MHz constraint | 64.513 MHz | 62.085 MHz |
| Worst setup slack | +3.018 ns | +2.412 ns |
| Bitstream sha256 | `922d935c...` | `0d4a51c8...` |
| `check_core` (1 MiB, all banks, byte lanes) | PASS | PASS |
| `check_compressed_board` | - | PASS |
| 38,400 RV32I / 30,720 RV32M | PASS | PASS |
| 3,852 bus / 5 C programs / 27 counters / 27 interrupts | PASS | PASS |

The RV32IMC image is the one to keep: it is the preset's ISA. The board is
left running it.

## Is the SDRAM the limit? No

The 60 MHz memory failures invite the question, so it was measured directly with
the standalone tester (`build.sh test`, which drives `sdram_burst_memory` from a
state machine with no CPU in the way). All eight MiB pass at 60 MHz **and** at
66 MHz:

| standalone tester, `build.sh test` | 60 MHz | 66 MHz |
|---|---:|---:|
| Fmax (small design, so it is not the limiter) | 112.515 MHz | 116.220 MHz |
| `check.py` (12,582,912 word comparisons, all banks, byte lanes, retention) | PASS | PASS |

So the pins, the command sequencing, the burst protocol, the refresh and the
read-capture phase all work on this board at 66 MHz — above any clock the
processor reaches. The memory is not the wall; the processor is. That also means
the SDRAM's absolute ceiling was not located here, only shown to be above 66 MHz.

Two caveats keep this from being a signoff:

1. **The interface has no timing model.** `io_timing.py` emits
   `model_complete: false` with `t_ac_max`, `t_oh_min`, command/data/DQM
   setup and hold, every flight time, the setup/hold uncertainties and the whole
   qualification block missing, and the SDC carries no SDRAM I/O constraints.
   Every frequency above 48 MHz is empirically qualified, not proven.
2. **The capture window shrinks with the period.** At the 135 degrees the
   pipeline uses, the memory clock edge sits `0.375 x period` after the FPGA
   launch edge (commands get that much setup) and `0.625 x period` before the
   next capture edge (reads get that much to arrive). The second number is what
   has to cover the SDRAM's `tAC`, which does not shrink: 13.0 ns at 48 MHz,
   11.6 ns at 54, 10.4 ns at 60, 9.5 ns at 66. The project's phase-window model
   (`check_phase_window.py`) puts the 135-degree read margin at +5.57 ns with a
   6 ns `tAC` and +1.57 ns with a 10 ns `tAC` at 54 MHz, and at +3.47 ns and
   -0.53 ns at 66 MHz. Phase is the knob that trades the two windows against
   each other: 112.5 degrees buys about 0.95 ns of read margin at the cost of
   the same amount of command setup, and `sdram.v` itself documents 66.7 MHz as
   the ceiling for its cycle counts.

**60 MHz is not usable for the processor.** A 60/60 MHz build closes timing at only +0.938 ns and
on the board the 1 MiB test reports `SDRAM BAD` and the C arithmetic programs
return wrong results, so the margin the report shows is not real there. With under a
nanosecond of slack, and with the memory separately proven healthy at 60 and
66 MHz, the core is the cause: the reported Fmax saturates at 63.6-64.5 MHz once
the constraint actually bites, whether it is set to 54 or 60 MHz. The 74.483 MHz
figure above is what the placer reports when it is told to close at 48 MHz and
then stops working, not a clock this build reaches under pressure. 60 MHz is
also outside the frequency set the I/O tooling models (`io_timing.py` and
`check_phase_window.py` accept 27, 48, 54 and 66 MHz), so the next supported
step up is 66 MHz, and it needs the core past 66 MHz first.

## Attacking the hold enable directly

Two attempts, one of them a dead end worth recording.

**Freeing the payload registers does not work.** The D, E1 and E2 payloads are
965 of the ~3,900 flops on the hold enable, and each one's next value looked
idempotent: during a hold it recomputes the same payload it already holds, so
loading it every cycle instead of only on `~holding` should be a no-op. It is
not, and the RTL guest caught it (timeout after 22 fills, `hold=x` reaching the
cache). A payload register advances *one stage ahead of its own token*: while
the pipeline is held, `e2Advance` is frozen true, so a free-running E2 payload
is overwritten with `e1Out(E1)` - the instruction *behind* it - while the pipe
register that carries the M token is frozen. When the hold ends, M takes that
payload, which is `e2Moved` of the frozen E2 payload. Payload and token must
move together; only the token registers are what make a payload meaningful.
The 965 flops therefore stay on the enable, and the change was reverted.

**`-route_maxfan` is the one knob that reaches this net.** It is a routing
resource limit, not one of the synthesis nets `syn_maxfan` refuses to touch
(clock, enable, reset), so it changes how the router builds the buffer tree for
a thousands-of-loads net. Swept at the 60 MHz constraint, everything else fixed
(place 2, `-route_option 1 -map_option 3`, target 66):

| `SDRAM_ROUTE_MAXFAN` | Fmax at the 60 MHz constraint | Slack |
|---|---:|---:|
| 45 | 63.577 MHz | +0.938 ns |
| default (23) | 63.577 MHz | +0.938 ns |
| 12 | 65.697 MHz | +1.445 ns |
| 10 | 64.056 MHz | +1.055 ns |
| **8** | **65.749 MHz** | **+1.457 ns** |

Lowering the per-node fan-out shortens the tree and is worth about half a
nanosecond, consistently - the only lever measured that changes this path's
routing without touching the netlist. It is not enough to make 60 MHz usable
(the board still reports `S?RAM BAD` with garbled UART output at +1.457 ns), but
it is free and should ride along with any build where the enable is critical.

## The wall is enable depth, not fan-out

The paragraphs above guessed wrong about this, and the netlist says so. Counting
clock-enable pins per net in the 60 MHz build shows the tool has already
partitioned the enable: 172 distinct `CE` nets, the widest with 641 loads, and
the leading setup paths end at a *forty-one* load net. So the enable is not one
5,000-load tree to be shortened by replication.

What those paths actually contain is logic. In the pre-change build the worst
path ran `ds5_732 -> case tree -> a thirteen-bit carry chain -> two LUTs -> CE`:
7.6 ns to 22.8 ns, of which the buffer tree is the last 3 ns. `ds5[768:770]` is
`e1Pc[4:2]`, and `btbIndex pc = pc >> 2` - the branch table's *entry select*.
Synthesis had absorbed the "which entry am I writing" select, and therefore the
whole branch-target adder behind it, into the clock enable of the pipe register.

**Fix: register the table update, and let the read bypass it.** `Pipe` gains
`pBtbWrite :: Maybe (Index 8, BtbEntry)`: the resolution is registered for one
cycle and installed from a flop. The fetch read is `applyBtbWrite pipe`, the
registered table with the pending entry overriding it - and since at most one
entry changes per cycle, that override makes the deferral invisible to every
reader. Behaviour is unchanged (the RTL guest reports identical 101 fills, 20
writes and 58,049 held clocks), but the adder and the entry select now end at a
forty-six-bit register instead of at the pipe enable.

| 60 MHz constraint, place 2, `-route_option 1 -map_option 3 -route_maxfan 8` | Fmax | Slack |
|---|---:|---:|
| before | 65.749 MHz | +1.457 ns |
| after (RV32IM) | **69.388 MHz** | **+2.255 ns** |
| after (RV32IMC) | **70.901 MHz** | **+2.563 ns** |

At the 54 MHz constraint the same RV32IMC source reports 68.489 MHz and
+3.918 ns. The leading paths no longer start at a payload bit: they start at a
fetch bit and run through the table hit compare and the `+4` of the sequential
fetch address, which is the next enable-absorption site.

Adding the field moved every Clash record offset, which silently broke the
testbench: `pipeline_cpu_tb.v` hard-codes bit slices of the packed machine
(`+46` here) for the FENCE.I monitor. The coverage assertion fails loudly
(`commits=0`) rather than passing vacuously, and the dependency is now commented
at both places.

**Where that leaves the enable.** Correction: the wall is not fan-out (see
below) but the depth of the logic synthesis folds into the enables. Fan-out is
already partitioned into 172 nets. What remains, in rough order of effort:

1. Fewer flops behind the hold enable. The fetch queue, the in-flight window
   and the branch table (~1,500 bits) are register arrays that could become
   RAM and so lose their clock enables.
2. A cache that can be told, one cycle early, that it will hold. The enable
   would then come straight off a flop instead of off a LUT.
3. A tool that supports fan-out replication for control signals on this
   device. `set_option -replicate_resources` is Arora V/III only, and
   `syn_maxfan` explicitly excludes clock, enable and reset nets.

## 60 MHz is still not usable, for a different reason

The +2.563 ns build was flashed and exercised. It does **not** work, but the
failure has changed shape and the new shape is informative: execution completes
(the program prints `DONE` at the end of every run) and every byte *before* the
last line is lost.

| 60/60 MHz, RV32IMC, `btbdef-60-rvc` (`5158dc5a...`) | Result |
|---|---|
| `check_finisher` | PASS |
| `check_core`, `check_traps`, `check_counters` | `b'DONE'` only |
| `check_bus` | expected marker `S`, received `b'DONE'` |
| `check_rv32i` | `(1, b'DONE')` |

So the core computes and the program runs to completion, and the defect is in
getting the program's output out - not in the internal timing the Fmax figure
measures. Earlier 60 MHz builds produced *garbled* variants of the same dump
(`S?RAM BAD`), consistent with a marginal serial link rather than a marginal
CPU. 60 MHz is also outside the modelled I/O set (27/48/54/66), and the UART's
bit period is a fixed 868 clocks, so at 60 MHz both ends must agree on 69,124
baud. The next step is to qualify that link - separating ROM-upload throughput
from program-output throughput at 60 MHz - rather than to keep pushing the core.

## New build knobs

`build.sh` gained the synthesis and routing options that were previously
unreachable from this flow. All are unset by default, which leaves the stock
tool behaviour:

| Variable | Option | Range | Note |
|---|---|---|---|
| `SDRAM_MAP_OPTION` | `-map_option` | 1-4 | 3 is LUT5-oriented and worth 11 MHz here; 4 does not fit |
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
