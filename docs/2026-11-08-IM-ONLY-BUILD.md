# The core without RVC: five placements pass with margin

Kind: measurement on a build variant, 2026-11-08. The canon's source
(`dcd220d`, main at 99ab2c0), built with `SDRAM_RVC=0` and otherwise the
`fprisc-81` settings and `fprisc-81.plan`. Follows
[LOOP-CENSUS](2026-11-08-LOOP-CENSUS.md), whose conclusion was that fill, not
logic depth, sets the routing, and the four placement records of the same
day, in which nothing moved the baseline's distribution.

## Result

Dropping compressed-instruction support removes the assembly stage and the
F queue, and with them 15.9% of the whole design's logic. **All five
placement options then close 81 MHz with margin**, the first netlist in this
record to do so:

| Placement | IMC canon (`dcd220d`) | IM-only | IM-only slices | Routing time |
|---:|---|---|---:|---:|
| 0 | 81.055 MHz, +0.008 ns | **84.413 MHz, +0.499 ns** | 8,125 | 39 s |
| 1 | 78.766 MHz, -0.350 ns | **85.238 MHz, +0.614 ns** | 8,085 | 35 s |
| 2 | 78.766 MHz, -0.350 ns | **85.238 MHz, +0.614 ns** (same as 1) | 8,085 | - |
| 3 | 84.447 MHz, +0.504 ns | **88.149 MHz, +1.001 ns** | 8,053 | 44 s |
| 4 | 557 unrouted nets | **82.194 MHz, +0.179 ns** | 8,012 | 45 s |

The canon routes in 3 to 46 minutes; these route in under a minute, which
is what a design with room looks like.

The price is code size: the classifier compiled as RV32IM is 93,592 bytes of
text against 74,372 as RV32IMC, +25.8%. What that costs in cycles is
measured below.

## Area

Whole-design synthesis, identical options:

| | IMC canon | IM-only | Change |
|---|---:|---:|---:|
| Logic (LUT + ALU + RAM16) | 15,074 | 12,684 | -2,390 (-15.9%) |
| of which LUT / ALU | 13,981 / 901 | 11,692 / 800 | -2,289 / -101 |
| Registers | 5,436 | 5,316 | -120 |
| Block RAMs | 40 | 40 | 0 |
| Occupied slices at placement 3 | 8,717 (84%) | 8,053 (78%) | -664 |
| Core LUT4 equivalents (census) | 12,834 | 10,547 | -2,287 |

By structure in the core: assembly (`pA`) 1,090 to 587, F 686 to 125, fetch
1,223 to 884, E1 798 to 536, D 648 to 498, E2 1,450 to 1,331. The slow path
is unchanged (CSR and counters 1,782, bus and devices 1,221, divide 807), so
it is now 37% of a smaller core.

The loop census of the five routes shows the same structures at the same
depths as before (fetch and BTB loops at 7 levels, E1 to D-blocked at 12),
all with positive slack: the loops did not get shorter, their wires did.

## Checks

| Check | Result |
|---|---|
| Verilator cache/CDC guest, IM observed core, two-way 64 KiB cache (timer interrupts, traps, FENCE.I, Ctrl-C during a miss, three negative controls) | pass |
| Board, the placement-3 image loaded into FPGA SRAM: `check_processor.py`, `check_rv32m.py` (30,720), `check_rv32i.py` (38,400) at 81 MHz | all pass |

The canon image was restored to the board afterwards and re-checked. The
IM core's generated RTL was also in the 6 November regression (six
`check_pipeline_rtl.py` configurations, all passing).

## What the code size costs

The same classifier fixture (128/64, bins 8, depth 5, one run), compiled
twice by the same compiler (`fprisc` 9451dca, since today's head fails every
rv32 bare-metal build) and run on the matching core in the perf harness,
each with the reference result:

| Clocks | IMC image on the IMC core | IM image on the IM core | IM cost |
|---|---:|---:|---:|
| 48 / 48 MHz | 130,288,341 cycles | 142,250,129 cycles | **+9.2%** |
| 81 / 48 MHz | 145,606,053 cycles | 156,452,097 cycles | **+7.5%** |
| cache fills (code fills) | 152,938 (29,862) | 220,310 (76,432) | x1.44 (x2.56) |
| held cycles at 81/48 | 26,546,705 | 25,315,859 | -4.6% |

The whole cost is instruction fetch: code fills rise 2.6x and the pipeline
spends the extra cycles waiting for them, while held time is slightly lower
(wider instructions mean fewer instructions to execute per byte fetched
collide less with data traffic). At 81 MHz the IM core needs 7.5% more
cycles for the same work, so **at the same clock it is 7% slower**; it breaks
even at about 87 MHz, which its +1.0 ns of margin at placement 3 suggests is
available, and anything the recovered 664 slices buy in IPC is on top.

(These images take 1.45x the cycles of the 2026-10-30 frozen classifier
used in every pricing since: a different compiler state and `FPR_HEAP_REPORT`
on. The comparison here is between two images from one compiler, which is
the fair one for the ISA question; the compiler drift is a separate FP-RISC
matter.)

## What this means

This is the first measurement that separates a design effect from placement
luck: the difference between the two arms is 4 passes out of 4 distinct
implementations against 2, with every IM-only margin above the canon's
median, and routing times an order of magnitude shorter. By the revised
method it is a candidate that qualifies on every count except the one it
trades away.

Whether to take the trade is a decision about FP-RISC code, not about the
core: RVC buys fetch bandwidth and cache capacity worth 7.5% of cycles on
this workload at 81/48, and the core pays for it with a front end that does
not place. Options:

1. **Adopt the IM core as the canon at 81 MHz**, accepting the code-size and
   cycle cost, and spend the recovered slices and margin on the IPC work
   that the four-clock port, the floorplan and every refactor so far could
   not place: the three-clock port already closes everywhere, and load-use
   forwarding (L1, 1.010x) and the front-end work become placeable again.
2. **Keep RVC and buy the same room another way**: the assembly stage and F
   queue are about 1,600 LUTs and 350 registers of the 2,390 removed; a
   narrower RVC front end (expand in the fetch stage from a 32-bit word with
   a one-halfword carry, no separate queue) would be a core redesign with
   this result as its target.
3. **Raise the clock on the IM core**: with +1.0 ns at placement 3 and
   routing in under a minute, 87 or 90 MHz builds are worth a distribution
   run before any adoption decision, since the comparison that matters is
   MIPS on the board, not Fmax.

Either way the next experiment is cheap: the FP-RISC suite and the 512/128
classifier on the board with the IM image, against the canon's 6.799 s.
That needs the FP-RISC runner to accept an `fprisc-81-im` preset (its
configuration copy pins `compressed=True`) and a compiler that builds RV32IM
images; today's `fprisc` HEAD (7dfb6f9, the typed-lowering work) fails
silently on every rv32 bare-metal build, so the images here come from a
worktree at 9451dca.

## Evidence

[evidence/2026-11-08-im-only/](evidence/2026-11-08-im-only/): `routes.txt`
(all five placements), `synthesis-totals.json`, `area-census.txt` and
`.json`, `loop-census.json`, `rtl-check-im.txt`, `board-checks.txt`,
`images.txt` (the two classifier images' sizes and hashes), the simulation
`results-*.json`. Builds under `output/tangnano20k/im-only-20261108/`.
