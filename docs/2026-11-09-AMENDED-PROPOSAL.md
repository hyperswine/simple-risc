# Amended proposal: structure, not ownership, and the plan for 87 MHz

Kind: plan, 2026-11-09. Supersedes the objective and work sequence of
[ARCHITECTURAL-REFACTOR](2026-11-07-ARCHITECTURAL-REFACTOR.md); keeps its
acceptance method as revised on 2026-11-08. Applies to the RV32IM canon:
`fprisc-84` ([FPRISC-84](2026-11-08-FPRISC-84.md)), and `fprisc-81` of the
same shape.

## What two days of measurement established

Fourteen bounded experiments against the three-clock IMC baseline, then the
IM core, say the following, each with its own record:

1. **The baseline was a lucky draw.** Across placement options the IMC
   canon passed 81 MHz at two of four distinct implementations, one by
   0.008 ns, and routed in 3 to 46 minutes. Nine candidates routed at its
   best placement all came out slower; this measured the lottery, not the
   candidates.
2. **Routing length is the limiter, not logic depth.** The pipeline loops
   are 7 to 9 levels at 0.4 ns a level with 5.6 to 9.5 ns of wire, and a
   structure's depth stays put while its slack swings 1 to 3 ns between
   netlists ([LOOP-CENSUS](2026-11-08-LOOP-CENSUS.md)).
3. **Area in LUTs does not reach the placer; occupied slices do.** Every
   small saving (-200 to -450 logic units) left occupied slices between
   8,600 and 8,870; the A-to-F refactor cut 202 LUTs and *raised* slices.
4. **Region constraints on registers do not shorten the wires**; the
   placer's own front-end solution beat every rectangle tried, and one more
   pinned register could leave hundreds of nets unrouted.
5. **Removing a structure did what nothing else did.** Without RVC the core
   lost 2,390 logic units and 664 slices, every placement closed 81 MHz
   with margin, and routing took under a minute
   ([IM-ONLY-BUILD](2026-11-08-IM-ONLY-BUILD.md)). The price, 7% of
   classifier time at the same clock, is instruction fetch, and 84 MHz
   recovers 2.1 points of it ([IM-CANON](2026-11-08-IM-CANON.md),
   [FPRISC-84](2026-11-08-FPRISC-84.md)).
6. **A boundary that adds logic costs what it adds.** The DSP counters as
   built hold 33 of 65 bits in the DSP and 132 to 216 LUTs of fabric each;
   on the IM core they are area-neutral and cost 84 MHz two of its four
   placements ([AGGREGATE-ON-IM](2026-11-08-AGGREGATE-ON-IM.md)).

## The amended objective

Make the canon's clock a property of the design rather than of the
placement, and raise it by removing what the design does not need. The
unit of progress is **occupied slices and the wire length of the loops that
set the clock**, measured as **four of four placements closing** with
margin. Separation of state, registered service interfaces and DSP
implementations are means that earn their place only when they remove
slices or shorten a loop; none is a goal.

From the 2026-11-07 sequence this keeps: the matched-build method and its
2026-11-08 revision; step 1 (division-only dispatch, a clean -201 that has
not yet been adopted alone); the A-to-F validity patch and the
warm-reset bench as verified primitives; the `circuitWith` plumbing and the
vendor-model counter test. It drops: payload-reset separation as an aim
(no routing effect, slices up); register-group floorplans beyond the two
slow regions; the DSP counters in their present form; the service boundary
as a first step. It defers the CSR/trap/divide service to the point where
the slow path behind it is small enough that a boundary is cheaper than the
logic it fences, and it moves the one architectural item, a narrower RVC
front end, to after 87 MHz, to be built against the IM core with the 7%
fetch cost as its target.

### Acceptance, restated

- Functional gates before anything physical: the Haskell properties, the
  Verilator cache/CDC guest on fresh observed RTL, the warm-reset
  equivalence bench where state or reset moves, the vendor model where a
  hard block is used.
- Synthesis census by structure (`area_census.py`), whole-design logic and
  registers, direct reset and enable loads, and the loop census
  (`loop_census.py`) of one placement for depth and cell delay.
- Routing as a distribution over placement options 0, 1, 3 and 4 (2
  duplicates 1 on this tool), reported as pass count and margins. The
  requested-frequency option does not perturb place and route; the only
  honest perturbation beyond the placement option is a different netlist.
- A candidate is "not worse" when its pass count holds and its median
  margin is within 0.1 ns; "better" when the pass count rises.
- Board adoption as before: a preset, the processor and ISA checks, the
  FP-RISC suite, the classifier against the previous canon. SDRAM
  electrical qualification stays at the existing 48 MHz evidence.

## Closing 87 MHz on the IM core

At 87 MHz the canon netlist passes placements 1 and 3 and misses 0 and 4 by
**0.039 and 0.003 ns**, one path each; at 90 it misses by 0.067 and 0.343.
These are not placement accidents in the sense of item 1: the same two
structures lose at both clocks and both placements, and they are loops.

| Clock, placement | Worst path | Levels | Cell | Route | Slack |
|---|---|---:|---:|---:|---:|
| 87, placement 0 | BTB table output to BTB table address | 7 | 2.12 ns | 7.12 ns | -0.039 |
| 87, placement 4 | M-slot valid to D-blocked | 9 | 3.50 ns | 7.73 ns | -0.003 |
| 90, placement 0 | BTB table output to BTB table address | 6 | 1.94 ns | 6.94 ns | -0.067 |
| 90, placement 4 | M-slot valid to D-blocked | 9 | 3.15 ns | 8.04 ns | -0.343 |

The reported arcs show what the cells are. The BTB loop is the table's
data output, then an **eight-cell ALU carry chain**, then two LUTs into the
fetch pc: the 8-bit tag equality (`btbTag`) has been mapped as arithmetic.
The hazard path is the M-slot valid bit, three LUTs of selection
(`nextM`, `result`, `instructionRs1Out`), a **three-cell carry chain** for a
5-bit register-index equality, and three more LUTs into `pDBlocked`. A
carry chain is placed as a column and adds a cell per bit; an equality as a
LUT tree is two levels for 8 bits and crosses no column. These are
deterministic depth cuts, the kind the loop census said are small but
placement-insensitive, and here the shortfall is small.

The plan, in order, each step gated as above and routed at the four
placements at 87 before the next is combined with it:

1. **Equalities as LUT trees on the two loops.** Write the BTB tag compare
   and the register-index compares of the hazard check so Gowin maps them to
   XNOR-reduce rather than subtraction (in Clash, `reduceOr (a xor b) == 0`
   or an explicit `xnor` fold instead of `==` on `Unsigned 8` / `Index 32`).
   Expected: the BTB loop from 7 levels to about 4 and the hazard path from
   9 to about 6, roughly 0.5 to 1 ns of cell delay and a shorter physical
   span on each; no IPC change; no functional change if the properties and
   the guest agree. Verify in the census that the chains are gone before
   routing.
2. **Hazard inputs a stage earlier.** `pDBlocked` still derives rs1/rs2 from
   `fWord` through three LUTs after the M-slot valid arrives. `Fetched`
   already carries `fUsesRs1`/`fUsesRs2`; carry the 5-bit indices too and
   compare registered against registered. Expected: another level or two
   off every hazard path (E1 to D is 11 to 12 levels, the deepest in the
   design); no IPC change.
3. **Division-only dispatch alone** (-201 LUTs in the divide unit, the
   call-site hunk on branch `aggregate-im` without the counters). A slice
   saving in the slow path, which is where the two regions sit; judged by
   slices and the four placements, expected neutral to slightly positive.
4. **The bus response path.** `cpuBusResponse` is 35 registers fed by a
   20-way one-hot select of 32-bit device words (311 LUTs on the IMC
   census, similar here). A registered two-level select (device class,
   then word) removes most of it from the critical cone of
   `cpuPendingWrite` and the slow regions. Expected -150 to -250 LUTs;
   needs the bus RTL checks and the guest.
5. **Only then the floorplan**: regenerate the two regions sized from the
   census of the resulting netlist (about 1.5 times its slices) and check
   the margins at 87 and 90 across the four placements.

Steps 1 and 2 are the ones that address the measured shortfall; 3 and 4
are the area that makes the result robust rather than exact; 5 is
housekeeping. If 1 and 2 alone give four of four at 87 with 0.2 ns, the
canon moves to 87 and is qualified like 84 was (a preset, the board checks,
the suite, the classifier against 7.128 s); 90 is then the next sweep.

## After 87

- **IPC on the IM core**, now that placements route in a minute: load-use
  forwarding L1 (1.010x priced on the IMC core), the E1-to-D hazard depth
  (also step 2 above), and the front-end items of
  [IPC-PLAN-81MHZ](2026-11-05-IPC-PLAN-81MHZ.md), each as a distribution.
- **A narrower RVC front end** built against the IM core: expand
  compressed pairs in the fetch stage with a one-halfword carry and no
  assembly stage or F queue. Target: most of the 7% fetch cost at a fraction
  of the 2,390 logic units the old front end cost; judged first by slices
  and placements, then by the classifier.
- **DSP counters only all-in**: two cascaded `ALU54D` per counter so no
  fabric high word remains; otherwise not at all.
- **FP-RISC**: today's head cannot build rv32 bare-metal images and both
  recent compilers produce classifier images that take 1.45x the cycles of
  the 30 October one. Both are outside this repository and both matter more
  to the board number than anything above.

## Evidence

The paths quoted are from the 2026-11-08 IM clock sweep
([evidence/2026-11-08-im-canon/sweep.txt](evidence/2026-11-08-im-canon/sweep.txt)),
reports under `output/tangnano20k/im-sweep-20261108/`; the cell-level arcs
are in those reports' setup analysis (`f87-p0`, `f87-p4`, `f90-p0`,
`f90-p4`).
