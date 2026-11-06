# Area census, floorplan constraints and the idle DSPs

Kind: measurement, tools, first floorplan builds and a ranked plan,
2026-11-06. Applies to the canon `fprisc-81` (core 187c637, 82.651 MHz,
+0.247 ns). Follows [LOAD-USE](2026-11-05-LOAD-USE.md) and
[IPC-PLAN-81MHZ](2026-11-05-IPC-PLAN-81MHZ.md), whose first goal was to make
the design placeable.

## Result

The routing wall is an area and geometry problem more than a placer problem:

- **About 40% of the core's logic is not the pipeline.** Of 12,461 LUT4
  equivalents, 5,056 feed the machine state outside the pipe: CSRs, traps and
  counters, the system bus and devices, the multiply/divide unit, register
  write-back and what is left of the phase machine.
- **That slow path sits in the middle of the die**, between the cache on the
  left edge and the pipeline stages, which wrap around it.
- **The cache covers the die.** Its 36 block RAMs occupy nearly every site in
  all three BSRAM rows (R10, R28, R46), so a cache-to-core route is die-length
  wherever the core is placed.
- **Routing is 78% of path delay** on average over the 3,000 reported setup
  paths (minimum 40%, maximum 85%), not only on the worst path.
- **The 2026-11-05 floorplan trial never reached the placer.** It stopped on
  a syntax error; the correct forms are in [Floorplan constraints](#floorplan-constraints).
- **The hard blocks are mostly idle**: 2.5 of 24 DSP macros and 40 of 46
  block RAMs are used, while logic slices are 86% full.

**The first floorplan closes the three-clock cache port at 81 MHz.** Two
regions that move the slow path's registers out of the centre take the L2
netlist of [LOAD-USE](2026-11-05-LOAD-USE.md) (1.106x fewer cycles in
simulation) to **84.447 MHz, +0.504 ns** at placement 3 and 81.055 MHz,
+0.008 ns at placement 0, against 61.9 and 69.6 MHz for the two unconstrained
builds of 2026-11-05. That is timing only: L2 is not adopted here, and it
still has to be built from source with the floorplan and pass the RTL checks,
the board checks and the FP-RISC suite.

The floorplan is not a general cure. The same plan makes the canon worse
(82.65 to 64.5 MHz), and one more pinned register leaves nets unrouted or
drops L2 to 55.9 MHz. The slow path turns out to be nearly separable
already: of its 1,021 registers only 4 are read by the pipeline within a
cycle.

## Where the logic is

`area_census.py` reads the synthesized netlist, takes the core module, and
walks back from every register through the LUT and ALU cells that feed it. A
cell is charged to the register group it feeds; a cell feeding several groups
is split evenly, and "only" counts cells feeding one group alone. A LUT5
counts as two LUT4s. The total matches the synthesis report (11,814 LUT +
673 ALU).

| Part of the core | Registers | LUTs | Only | Share |
|---|---:|---:|---:|---:|
| machine: CSR, trap, counters | 524 | 1,835 | 1,730 | 14.7% |
| machine: bus and devices | 356 | 1,262 | 1,208 | 10.1% |
| machine: multiply/divide unit | 141 | 869 | 704 | 7.0% |
| machine: register write-back | 80 | 556 | 381 | 4.5% |
| machine: phase datapath | 266 | 534 | 490 | 4.3% |
| pipeline: E2 | 421 | 1,428 | 1,221 | 11.5% |
| pipeline: fetch | 477 | 1,232 | 623 | 9.9% |
| pipeline: A | 262 | 1,079 | 660 | 8.7% |
| pipeline: F | 268 | 687 | 544 | 5.5% |
| pipeline: E1 | 310 | 648 | 271 | 5.2% |
| pipeline: D | 199 | 521 | 305 | 4.2% |
| pipeline: M | 360 | 410 | 356 | 3.3% |
| pipeline: BTB | 178 | 319 | 297 | 2.6% |
| unnamed registers (UART, cache request, multiply registers) | 639 | 948 | 926 | 7.6% |

The largest single fields:

| Field | Registers | LUTs |
|---|---:|---:|
| `cpuMulDiv` (the iterative unit) | 141 | 869 |
| `e2Candidates` (E1's eight ALU candidates) | 64 | 790 |
| `pA` (assembly and RVC expansion) | 99 | 757 |
| `systemBus` | 169 | 678 |
| `pFQueue` | 264 | 663 |
| `cpuTrapRegisters` | 127 | 531 |
| `heldState` (the cycle and mtime counters that run through a hold) | 139 | 461 |
| `cpuPendingWrite` | 38 | 457 |
| `pInstructionPc` + `pFetchPc` | 64 | 786 |
| `cpuBusResponse` | 35 | 311 |

The phase machine itself has mostly been removed by synthesis (8 of its 23
phase bits survive); what is expensive is the slow path it still runs.

`pipeline-layout` now also prints the `Machine` record and its sub-records,
which is how a `machine_0_N` register gets its field name.

## Where it was placed

A coarse map of the canon placement, from the cells on the 3,000 reported
paths (each character is 3 x 3 grid cells and shows the commonest structure
there: `C` cache, `b` bus and devices, `c` CSR/trap/counters, `d` divide
unit, `p` phase datapath, `w` write-back, `f A F D 1 2 M` pipeline stages,
`u` unnamed, `.` LUTs):

```
R 1    CC  .   .  cc.
R 4   ..      .   cc
R 7   CC .bbbbbbu ccc
R10   CCCbbbww  p12.FFF
R13  CCCbbbbMwdddF.1F11
R16   CCpbbb2.ddddp21FF
R19  CC.p..pM..d.cpMpFF
R22    CCppM.pddddMM..
R25  CCCpppMppddddMuuuuu
R28   CCCC2pp..M.MMuuu
R31  CCCCpc....p2MMuuuF
R34  CCCM2.....22222.ff
R37  CCCM..1MM2212..uffm
R40   C ..21.M2pFF.uuf.f
R43     ...1FfFFFFffffff
R46      ..1.ffFAAffffff
R49      ..1 ff.AAffff
R52      ..22.A.AAfff...
```

The bus, the divide unit and the phase datapath hold the centre; M and E2 are
scattered around them; fetch and assembly are in the far corner from the
cache. The block RAM sites, from the post-place file: way 0's sixteen banks
alternate between rows R10, R28 and R46 at sites 0-6, way 1's between sites
5-12, the BTB at R28[13] and R10[15], the register file at R46[7-8]. The DSPs
in use are at `DSP_R37[2]` and `DSP_R37[3]`.

## Floorplan constraints

The syntax is in the IDE's own guide, `doc/EN/SUG1541-1.0E_Gowin Software
Physical Constraints User Guide.pdf`. What the 2026-11-05 trial got wrong,
and what is right:

```
// Wrong: CT2000 'syntax error' near token ':'
INS_LOC "fp_trial" R20C10:R24C14;

// One instance in a range of rows and columns
INS_LOC "cache/cpu_rdata_return_3_s0" R[20:24]C[10:14];

// A group needs both statements. The group name is not quoted; member
// names are, and may use * and ?.
GROUP slow = {"core/machine_0_1208_s0" "core/heldState_*"};
GRP_LOC slow R[2:9]C[2:55];

// "exclusive" on GRP_LOC keeps everything else out of the region
GRP_LOC slow R[2:9]C[2:55] exclusive;

// Block RAM and DSP sites
INS_LOC "cache/banks[0].mem_banks[0].mem_0_0_s" BSRAM_R28[0];
INS_LOC "core/bits_2_32_s2" DSP_R37[2][A];

// Keep a site empty
LOC_RESERVE R2C3;
```

A range is `R[m:n]C[k:t]`, with `R[m:n]Cy` and `RxC[k:t]` for one column or
row, and an optional `[0-3]` slice and `[A-B]` half after it. Relative
placement (`REL_GROUP`, `INS_RLOC`) also exists and is not used here.

Three tools:

- `floorplan_cst.py PLAN NETLIST.vg --layout layout.json -o region.cst`
  writes the `GROUP`/`GRP_LOC` pairs. A plan has one group per line, `NAME
  REGION SELECTOR`, where the selector is a regular expression over the
  census's "part: field" names. Only registers are named; their LUTs have
  generated names and follow them.
- `pnr_only.sh SOURCE OUT [region.cst]` places and routes an already
  synthesized build again with the fragment appended to `pins.cst`. Two runs
  then differ only in constraints (and `PNR_PLACE_OPTION`), on the same
  netlist. Run without a fragment it reproduces the canon exactly (82.651 MHz,
  +0.247 ns). `PNR_POSP=1` adds the post-place file, which lists block RAM
  and DSP sites only.
- `area_census.py NETLIST.vg --layout layout.json` is the census above.

`SDRAM_REGION_CST` in `build.sh` takes the same fragment for a full build.

## First floorplan builds

Every run places and routes an existing netlist again with `pnr_only.sh`:
the canon's, or the three-clock cache port's from
[LOAD-USE](2026-11-05-LOAD-USE.md) (`cpu81-l2-p1`), with that build's own
options (target 89 MHz, map 3, route 1, route fan-out 8) and the canon's
timing constraints. The pipeline layout is the same for both, so one plan
serves both netlists.

The plan (`f2-slow-split.plan`), with `--free ^pipeline` from f3 on:

```
csr     R[2:9]C[2:55]     ^machine: csr, trap, counters
bus     R[38:53]C[2:19]   ^machine: bus and devices
```

| Run | Netlist | Placement | Constraint | Result | Routing |
|---|---|---:|---|---|---:|
| f0 | canon | 1 | none | 82.651 MHz, +0.247 ns | 3 min |
| f1 | canon | 1 | both groups in the top band, divide unit in `R[40:53]C[2:18]` | stopped: router not finished | over 12 min |
| f2 | canon | 1 | the plan, every register | 78.405 MHz, -0.409 ns, 126 endpoints | 8 min |
| f3 | canon | 1 | the plan, `--free ^pipeline` | 64.545 MHz, -3.147 ns, 425 endpoints | 22 min |
| 11-05 | L2 | 1 | none | 69.635 MHz, -2.015 ns, 189 endpoints | 46 min |
| 11-05 | L2 | 3 | none | 61.904 MHz, -3.808 ns, 465 endpoints | 23 min |
| f3 | L2 | 0 | the plan, `--free ^pipeline` | **81.055 MHz, +0.008 ns, passes** | 8 min |
| f3 | L2 | 1 | same | 78.766 MHz, -0.350 ns, 154 endpoints | 8.5 min |
| f3 | L2 | 2 | same | 78.766 MHz, -0.350 ns, 154 endpoints (as placement 1) | 10 min |
| f3 | L2 | 3 | same | **84.447 MHz, +0.504 ns, passes** | 2 min |
| f4 | L2 | 1 | f3 plus the reset synchroniser in `R[26:30]C[26:30]` | failed: 284 unrouted nets | - |
| f4 | L2 | 3 | same | 55.850 MHz, -5.559 ns, 82 endpoints | 24 min |

Routing times are from runs that shared the machine two or three at a time,
so they compare loosely; the passing placement 3 build routed in 2 minutes
against 23 for the same placement unconstrained.

What each run showed:

- **f1: a region must have room.** The top band holds 1,728 slices; the two
  groups' logic needs about 1,850 at the canon's packing (1.67 LUTs per
  slice). The constraints were accepted and placement finished, but the
  router did not. The plan above gives each region about 1.5 times what its
  group needs.
- **f2: one register in the wrong group.** 87 of the 126 failing endpoints
  were `cpuInterruptDue` to the `pFQueue` enables, at 86% routing: the census
  files that register under CSR state, but it gates the whole pipeline.
- **The boundary, measured.** Of the 1,021 slow-path registers (CSR, trap,
  counters, bus, devices, divide unit), **4** feed a pipeline register through
  LUTs alone: `cpuInterruptDue` (one bit, into 1,162 pipeline registers) and
  three bits of `cpuBusResponse` (into up to 358). **158** are written from
  pipeline registers within a cycle (`cpuBusRequest` 69, `cpuExceptionValue`
  32, `cpuCsrSource` 32, `cpuCsrSelection` 14, a few flags). **859** have no
  one-cycle path to or from the pipeline; they reach it through the phase
  datapath and write-back registers, which stay with the pipeline.
  `floorplan_cst.py --free ^pipeline` leaves the coupled registers out of
  every group (159 of the 880 in the two groups used here).
- **f3 on L2: every placement improves, two pass.** Placement 3 gains
  22.5 MHz and placement 1 gains 9.1 MHz over the unconstrained builds.
  What still fails at placements 1 and 2 is mostly the reset synchroniser
  reaching enable pins (21 of the 25 reported paths, 4 levels, 86% routing)
  plus two fetch paths.
- **f3 on the canon: worse.** It fails everywhere at 83-90% routing, with
  congestion of 0.96 in the centre. A likely reason, not established: the
  canon's return register already lets the core sit away from the cache, so
  it gains nothing from a freed centre and pays for the displaced logic,
  while L2 needs the core beside the cache and gets the room.
- **f4: one more constraint breaks it.** Asking for the reset synchroniser
  mid-die (the canon put it at R39C55, the right edge) left 284 nets
  unrouted at placement 1 and cost 28.6 MHz at placement 3. The reset path
  is an RTL fix (ranked item 2), not a placement one.

So the floorplan is a property of the L2 design, not something to add to the
canon, and it is still fragile: +0.504 ns at one placement, +0.008 ns at
another, on a chip where one pinned register changes everything. It should
be adopted together with L2 and with the area work that gives it margin.

## Adopting L2 with the floorplan

Done later the same day: [THREE-CLOCK-PORT](2026-11-06-THREE-CLOCK-PORT.md)
(84.447 MHz from source, board-passing, 1.056x on the board's classifier).
What it was expected to take, as written before that:

1. Apply `l2-src.patch` and `l2-cache.patch`
   ([evidence/2026-11-05-load-use/](evidence/2026-11-05-load-use/)), build
   from source with `SDRAM_REGION_CST` set to the generated fragment at
   placement 3, and confirm the netlist reproduces 84.447 MHz. The fragment
   names registers by bit index, so it must be regenerated whenever the
   `Machine` or `Pipe` layout changes; the preset would run
   `floorplan_cst.py` rather than store a `.cst` (presets currently forbid
   `SDRAM_REGION_CST`).
2. The RTL checks, both cache regressions at three clocks and the Verilator
   CPU check (they passed for L1 + L2 on 2026-11-05).
3. Board: processor, M and I checks, the FP-RISC suite, and the classifier
   on the same binary. The simulation says 1.106x; at 81 MHz that is about
   IPC 0.42 and 34 MIPS on the board.

## Using the DSPs

22 of the 24 DSP macros are idle. Each macro holds two 18 x 18 multipliers
and one 54-bit ALU (`ALU54D`: `A +/- B`, accumulate with a reload input
`ACCLOAD`, a 55-bit cascade `CASI`/`CASO`, optional input and output
registers). GowinSynthesis only maps logic into a DSP around a multiplier
(SUG550 4.3: multiply, multiply-add, multiply-accumulate, pre-add), so a
plain counter or subtractor never lands there by inference: the `ALU54D` has
to be instantiated, in a Verilog wrapper beside the core, the way the
multiply operand and product registers already are.

What can move, all of it slow-path logic that is wide and arithmetic:

| Logic | Today | In DSPs |
|---|---|---|
| `mcycle` and `mtime`, each kept twice (`cpuCycle`/`heldCycle`, `devMtime`/`heldMtime`), and `minstret` | `heldState` 461 LUTs, `cpuInstret` 196, the rest inside `cpuDevices` and the CSR group | one accumulator each: `ACCLOAD` is the CSR write, the cascade carries bit 54 to a short fabric tail, or two macros per counter |
| The divide unit's 33-bit add/subtract and its two fix-up negations | part of `cpuMulDiv`'s 869 LUTs | one `ALU54D` in `A +/- B` mode with registered output (the unit already commits its adder result in a separate step) |
| The `mtime >= mtimecmp` compare | three registered compares in `cpuDevices` | the sign of a 64-bit subtract |
| The shift-and-add multiply in `cpuMulDiv` | still synthesized, although every multiply on this image takes the pipeline's DSP path (`e2MultFast`) and only divisions enter the unit | nothing: make the unit divide-only on the pipelined image (to be checked that no handover reaches it with a multiply) |

A rough target is 600 to 900 LUTs, to be confirmed by building: the counters'
carry chains and the divide unit's adder go, their write and select muxes
stay. The DSP is not for pipeline logic: its sites are fixed rows, and the
multiplier's DSP path was one of the six 75-78 MHz limiters until it was
registered ([CPU81-TIMING](2026-11-02-CPU81-TIMING.md)). A probe build
(`dsp-probe/probe.v`: a 54-bit accumulator with a CSR-style load in one
`ALU54D`, registered output, and a 10-bit fabric tail on its 55th bit)
answers two questions:

- **It is fast enough.** The probe closes at 203.9 MHz against a 125 MHz
  constraint; the slowest path into the DSP (a fabric register through the
  load mux to an `A` pin) takes 3.1 ns, and the accumulate loop inside the
  block is not among the reported paths.
- **There is a second DSP row.** The probe's ALU went to `DSP_R19[0][A]`
  (R19C2); the core's multipliers are in row R37. A counter moved into a DSP
  pulls its CSR read mux toward that row, so the DSP rows are natural anchors
  for a slow-path region.

The mode parameter is `ALUD_MODE`, as in the simulation model
(`simlib/gw2a/prim_sim.v`); the DSP guide's instantiation template calls it
`ALUMODE`.

Not yet done: a simulation of the probe against Gowin's `ALU54D` model, to
confirm that `CASO[54]` is the carry the tail needs. Timing only is
established.

## Ranked work

Ordered by what the builds above showed. Items 1 to 3 give the floorplan
margin; item 4 can also go first, since it already closes timing.

1. **Take logic out of the slow path**, starting with the DSPs (above) and
   a divide-only unit, then the trap registers (about 4 LUTs per bit),
   `cpuPendingWrite` and the bus response mux. 2,500 LUTs out brings the chip
   to about 60% logic, where a placement has room to be steered.
2. **Take reset out of the stage enables.** Nearly every payload flop has a
   synchronous reset (3,698 of the core's registers are `DFFRE`), 2,328 of
   the canon's 3,000 reported paths run from the reset synchroniser to enable
   pins, and on the floorplanned L2 build that net is the limiter. Only
   valid bits need a reset; a payload register needs neither the reset nor
   reset in its enable.
3. **Finish the slow path's boundary.** Four registers stand between the
   slow path and a clean one: register `cpuInterruptDue` and the three
   `cpuBusResponse` bits once more on the pipeline side (the interrupt is
   already a cycle late by design), and the slow path can take multicycle
   constraints and sit anywhere.
4. **Adopt L2 with the floorplan** (the section above), and widen its
   margin with 1 to 3: today it passes at two placements, one of them by
   0.008 ns.
5. **Small first-level caches next to the core** in the six free block RAMs
   (instruction and data apart), with the 64 KiB array unchanged as the
   second level on its four-clock port. This aims at load-use, the shared
   fetch/data port and restart refill together. It needs a hit-rate replay
   first, and it adds logic, so it follows 1.
6. **Schedule for this pipeline in FP-RISC.** Loads hoisted away from their
   uses, and likely paths laid out as fall-through to reduce the 796K taken
   branches the BTB misses. No area.

None of these is built; only L2 is priced (2026-11-05).

## Evidence

[evidence/2026-11-06-area-and-floorplan/](evidence/2026-11-06-area-and-floorplan/):
`area-census.txt` and `.json`, `layout.json`, the plans and generated
constraint fragments, `timing.txt` (every run), `canon.posp` (block RAM and
DSP sites of the canon) and `dsp-probe/` (source, constraints, site and
Fmax of the `ALU54D` counter).
