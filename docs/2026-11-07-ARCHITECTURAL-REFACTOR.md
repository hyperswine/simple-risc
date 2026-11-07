# Architectural refactor for predictable routing at 81 MHz

Kind: implementation plan and first bounded change, 2026-11-07.
Baseline: `dcd220d`, three-clock cache port with the generated floorplan.

## Objective and baseline

Refactor the pipelined implementation into independently owned state and
registered interfaces. Preserve RV32IM(C) behavior and the CPU/cache 81 MHz,
SDRAM 48 MHz split. First obtain lower fabric use and reliable placement at
81 MHz with unchanged workload performance; pursue higher clocks and IPC
once that foundation is measured. This is a staged replacement of hardware
boundaries, not just a file split or a simultaneous rewrite.

The [area census](2026-11-06-AREA-CENSUS-AND-FLOORPLAN.md) measured about
40% of core logic outside the pipeline, 86% occupied slices, and routing at
78% of delay over 3,000 paths. These figures describe its four-clock baseline;
repeat the census for each new implementation. The
[current three-clock port](2026-11-06-THREE-CLOCK-PORT.md) closes at
84.447 MHz (+0.504 ns) with placement 3, passes the board suites and runs the
same-binary 512/128 classifier in 6.799 seconds. Its floorplan is fragile.
These are recorded baseline results, not fresh qualification of refactored RTL.

## Target composition

```text
81 MHz: front end -> decode / execute -> commit and register file
                                           |
                                 registered command / completion
                                           |
                                 CSR / traps / divide / MMIO

        continuously running counters, UART and SPI
        pipeline <-> three-logical-cycle cache <-> ordered CDC bridge
                                                           |
48 MHz:                                             SDRAM controller
```

The cache stays in the CPU domain. Only refill and posted-write traffic
crosses to SDRAM. The service unit initially also runs at 81 MHz; multiple
cycles per operation do not imply a third clock domain.

Separate state owners should replace the synthesized dependence on the broad
`Machine` record. Retain the multi-cycle core as a reference and share decode
and arithmetic semantics. Simulation mirrors belong in adapters, not in the
production state interface. Keep old and new compositions runnable until the
replacement passes equivalent checks.

## Contracts that must survive

- Commit remains in order. A service request carries the operation, operands,
  instruction PC/raw instruction, destination and continuation needed for
  precise faults and completion. Initially allow one outstanding command.
- A command is accepted once; completion remains available until consumed.
  Flush, Ctrl-C and reset must cancel uncommitted register writes and prevent
  duplicate MMIO effects. Already accepted external writes cannot be undone;
  define their ordering and drain behavior explicitly.
- Counter writes, retirement ticks and physical-clock ticks retain their
  existing priorities. `mcycle` and `mtime` advance through cache holds;
  `minstret` advances only on retirement. CSR halves and overflow remain exact.
- Cache lookup stages and the pipeline advance together in logical time.
  Retain three-clock port timing during the initial state refactor. Encapsulate
  that agreement in one named contract used by the wrapper and tests.
- Preserve posted-write ordering, byte masks, refill/store conflicts, fence
  behavior and the bridge's single outstanding read. Both CDC resets assert
  together, with locally synchronized release.
- Reset control and validity, and omit payload resets only where invalid data
  cannot affect a branch, memory request, writeback or device side effect.
  Synthesis must not reintroduce reset through the payload enable cone.
- Multicycle exceptions require a proved launch/capture and stability contract.
  The current clock-scoped CDC exceptions assume the bridge is the only
  crossing. Audit that assumption after any topology change.

## Placement and fanout lessons to apply

The adopted floorplan improved the three-clock design at placement 3 from
61.904 to 84.447 MHz by moving loosely coupled CSR/counter state into a top
band and bus/device state into the bottom-left. Keep pipeline-coupled registers
free. This is evidence for separating state, not for pinning every stage:
the same constraints made the older four-clock design worse, and pinning one
reset register caused unrouted nets or 55.850 MHz timing.

The cache occupies 36 BSRAMs across three rows. There is no single nearby
cache location for the entire core. Measure bank-to-consumer paths and place
registered interfaces near their consumers. Keep BRAM banking and synchronous
read structure explicit; preserve the separate BTB write interface and the
registered multiplier boundaries. Evaluate hard-block locality together with
fabric congestion, not as a distance-only optimization.

Global reset/hold control remains an RTL problem. Reset validity/control first;
remove payload reset only with invalid-data safety checks. Do not combine
complex per-stage advance logic into a high-fanout hold enable: that previously
increased the enable cone. Track reset/hold fanout, CE endpoints, logic depth,
routing share, and congestion after each change. Lower LUT count alone does
not establish lower fanout or better routing.

For physical comparisons use identical ROM contents, clock constraints,
placement options and floorplan-generation rules. Build IDs embedded in ROM
can otherwise perturb placement. Compare synthesized cell counts and attributed
logic, then route both designs at the same placement. Extend to multiple
placements before claiming robustness. Keep failure results and regenerate
constraints from each netlist rather than copying instance indices blindly.

## Work sequence and acceptance

### 0 Preserve the baseline

Use `dcd220d` and its checked-in evidence as the immutable source baseline.
Keep experimental build output separate from canonical preset output. Before
claiming savings, compare fresh baseline and candidate synthesis with identical
options, tools and observation settings. Record manifests, netlists, census,
worst paths, routing share, utilization and placement results.

### 1 Specialize the iterative service to division

The pipeline already uses DSP partial products for MUL/MULH/MULHSU/MULHU;
only DIV/DIVU/REM/REMU hand over to the iterative unit. Give the latter a
2-bit division-only operation port, with the division selector constant at
elaboration, while the multi-cycle reference keeps the full M unit. Preserve
state layout and cycle timing for this first change. This should make the
unused iterative multiply cone removable without disturbing floorplan metadata.

Gate: all eight opcodes take the correct path and match independent integer
semantics; division latency matches the old unit, including zero divisors and
signed overflow. Follow with generated RTL tests and synthesis to establish
whether the expected logic removal actually occurs. Do not infer LUT savings
from the source change alone.

### 2 Give physical time and devices independent ownership

Extract counter transitions and their command interface first, then give each
counter one physical register owner. Remove the `HeldState` reinjection of
counter state incrementally. Keep UART/SPI and receive buffering live through
holds. Preserve break behavior and device-reset semantics.

Gate: randomized holds, counter-half writes, carry/overflow, simultaneous
retirement/write, interrupt timing, UART receive during holds and Ctrl-C.
Compare retirement traces and observable I/O against the old composition.

### 3 Separate validity and payload storage

Start with the SDRAM wrapper's E1 payload register: it is on the baseline's worst reset-to-enable path, and its validity is already owned separately
in `Pipe`. Introduce unreset payload storage with resettable
valid/control bits, retaining the existing logical advance behavior. Inspect
inferred flop types and reset/hold fanout before expanding to other stages.
Do not repeat the earlier per-stage-enable change: combining stage advance
with the global hold cone previously worsened routing.

Gate: invalid payloads cannot issue effects; flush/restart, memory holds and
emergency break pass RTL checks. Measure reset-to-enable paths and total mux
cost, not merely reset-pin counts.

### 4 Replace phase handover with an explicit service interface

First wrap existing CSR/trap/divide/MMIO phase behavior behind registered
command and completion records. Then move its private state out of `Machine`.
Keep register-file arbitration and architectural commit local to the pipeline.
Register interrupt status at that boundary with defined sampling semantics.

The measured slow path has only four register bits feeding pipeline registers
through combinational logic, making this a promising boundary. The result must
still be checked after extraction; record partitioning alone does not enforce
physical separation. Regenerate layout-based floorplans after every field change.

Gate: precise exceptions, interrupts at handover, WFI/MRET, CSR side effects,
MMIO backpressure, cancellation and exactly-once completion. No blanket timing
exceptions merely because a block is called slow.

### 5 Introduce DSP implementations behind arithmetic interfaces

Provide behavioral and Gowin implementations with the same cycle contract.
Start with a counter, then trial the divider subtractor/fix-up arithmetic.
Validate ALU54D carry/cascade behavior against the vendor model before using
it for 64-bit counters. Test high/low CSR writes and carries explicitly.

The existing probe establishes timing feasibility only. The census's estimated
600-900 LUT saving is a hypothesis. Compare complete-core routing: DSPs have
fixed sites, and their input/output routes can offset arithmetic savings.
Keep the already registered pipeline multiplier behavior intact.

### 6 Make board composition explicit

Replace clock-topology source substitutions with explicit single-clock and
split-clock wrappers/configuration. Use unambiguous CPU_HZ and MEM_HZ naming.
Generate RTL configuration, SDC and manifest values from the same validated
configuration. Preserve PLL phase, reset coordination and CDC constraints.
Keep constraints reproducible from semantic layout metadata rather than frozen
bit indices. Re-evaluate region sizes as state and arithmetic move.

Gate: preset/configuration tests, CDC RTL tests at 81/48 and other supported
ratios, constraint coverage, timing and generated-manifest consistency.

### 7 Reconsider cache hierarchy after area recovery

Replay workload traces to price small separate instruction/data caches near
the pipeline before implementation. Include added control, available BSRAM,
store coherence and FENCE.I costs. The large current array spans the die;
adding a level is a separate architectural experiment, not a prerequisite for
clean state ownership.

## Validation and adoption

For each bounded change run relevant Haskell properties and generated-RTL
regressions. Before adoption, run cache, bridge, fence and formal checks where
their contracts are affected, then fresh synthesis and place/route. Compare
placements 0-4, reporting failures as well as the best result. A useful initial
robustness target is at least three placements closing 81 MHz with positive
margin; this is a target, not achieved status.

Board adoption requires processor, RV32I and RV32M checks, the FP-RISC suite,
and same-binary workload comparisons. Measure at 81/48, not only 48/48: cache
miss time changes the benefit of saved pipeline cycles. Preserve canonical
artifacts until the candidate passes. A functionally passing source refactor
is not yet a qualified replacement bitstream.

The existing Icarus full-core timeout is recorded in the three-clock-port
report; report simulator-specific results accurately rather than counting a
timeout as a pass. Electrical SDRAM qualification remains limited to the
existing board evidence; the refactor does not strengthen that evidence.

## First implementation on 2026-11-07

Implemented step 1's division-only entry point in `SimpleRisc.Decode`, used
only by the pipelined phase handler. The general multi-cycle handler retains
`mulDivStep`. The shared arithmetic and state layout remain unchanged; the
new port fixes the high function bit and admits only the four division modes.

Added properties that exercise all eight M operations through the pipeline,
check which operations enter the iterative phase, compare stored results
with integer semantics, and compare division results and latency with the
original unit. Validation results follow.

Validation:

- Haskell suite: 74 SimpleRisc properties and 8 PsramRegs properties pass.
  The new dispatch property checks all eight opcodes for each of 100 operand
  pairs; the division equivalence property passes 400 cases. Cabal reported
  PASS, then failed to append its global cache log under the filesystem sandbox;
  the test suite itself completed successfully.
- Fresh IMC Clash generation succeeds, including production and observed tops.
- Verilator executing-guest regression passes with the two-way 64 KiB cache
  and CDC bridge, including Ctrl-C during a miss and the corrupt-response,
  duplicate-store and wrong-path-store negative controls. This regression uses
  the bench's offset half-speed memory clock, not an 81/48 performance run.
- `git diff --check` passes.

Logs: [evidence/2026-11-07-refactor/](evidence/2026-11-07-refactor/).
At this checkpoint step 1 was functionally checked but not physically measured.
The matched synthesis and routing experiment below supersedes that status.
Board programming and performance qualification remain pending.


## Physical comparison on 2026-11-07

Fresh production RTL from `dcd220d` and the division-only candidate was built
with identical ROM bytes and the fprisc-81 clock/map/route settings. Both
used the same state layout and freshly generated semantic floorplan: 437 CSR
and 284 bus registers, with only one synthesized bus instance renamed.
Neither the observed top nor a different ROM identity enters this comparison.

| Synthesis metric | Baseline | Division-only | Change |
|---|---:|---:|---:|
| Core LUT4 equivalents | 12,834 | 12,498 | -336 (-2.6%) |
| Iterative arithmetic attributed LUT equivalents | 889.8 | 612.0 | about -278 |
| Whole-design logic usage | 15,074 | 14,725 | -349 (-2.3%) |
| Registers | 5,436 | 5,435 | -1 |
| BSRAM | 40 | 40 | unchanged |
| MULT18X18 / MULTADDALU18X18 cells | 1 / 2 | 1 / 2 | unchanged |
| Direct reset input-pin loads inside core | 3,849 | 3,847 | effectively unchanged |
| Largest direct CE-pin load inside core | 487 | 487 | unchanged |

Logic usage and core attribution use different scopes and accounting; neither
is the occupied-slice count. At placement 3 occupied CLS falls only from
8,717 to 8,664 (-0.6%). Much of the logic saving does not translate into freed
slices after packing.

| Placement | Baseline Fmax / slack | Division-only Fmax / slack |
|---|---|---|
| 3 | 84.447 MHz / +0.504 ns | 80.043 MHz / -0.148 ns; 10 setup violations |
| 0 | 81.055 MHz / +0.008 ns | 65.247 MHz / -2.981 ns; 79 setup violations |

Both baseline results reproduce the historical measurements exactly. At
placement 3, the candidate's worst path is fetch to instruction PC; cache,
assembly and reset-to-enable paths also fail. Routing accounts for 84.6% of
the 25 reported setup paths' delay on average, against 79.9% in the baseline.
Peak reported congestion rises from 0.917 to 0.931. These are each design's
reported worst paths, not a paired comparison of identical endpoints or a
3,000-path census: the tool emitted 25 despite the requested report count.

Placement 0 finished on 2026-11-08 and also regressed. Its occupied CLS
increases from 8,687 to 8,790 despite the smaller logic count. Neither tested
placement supports adopting the area reduction as a standalone timing
improvement. Both candidates route fully and have no hold violations, but
both fail the 81 MHz setup gate. Placements 1, 2 and 4 were not tested. Reset/control distribution remains almost
unchanged. Prioritize a bounded validity/payload reset separation experiment
before broad counter ownership changes, using this same matched-build method.
The floorplan must be evaluated for the new netlist; reducing arithmetic alone
does not preserve a previously successful placement.

Evidence and reproduction notes:
[evidence/2026-11-07-refactor/physical/](evidence/2026-11-07-refactor/physical/).


### Default activation deferred on 2026-11-08

The adopted placement-3 preset fails timing with the division-only call, so
the default pipelined handler has been restored to `mulDivStep`. The new
`divideOnlyStep` helper and its properties remain available. The measured
candidate is preserved as a source patch in the physical evidence directory;
its call-site hunk can be reapplied for the next experiment. No preset or
canonical bitstream was replaced.

The resulting default tree passes all 82 Haskell properties. As before, Cabal
reports PASS before its unrelated global-log append is denied by the sandbox.
The physical candidate's earlier generated-RTL checks remain in the evidence;
its synthesis/routing measurements must not be attributed to the restored
default call site.


### Experiment outcome

Retain the area-saving helper and reproducible patch, but defer default
activation. The two matched placements demonstrate an area saving and a
routing/timing regression, not a general impossibility of placing the smaller
netlist. Do not select a new preset solely from these runs. Test E1 payload
reset separation independently on the passing baseline before combining it
with the division-only change. Continue the same checks of occupied slices,
reset/enable fanout, setup/hold endpoints and routing congestion; preserve
failed experiments alongside passing ones.

All four runs completed. Elapsed driver times were about 85/837 seconds for
baseline/candidate at placement 3 and 331/721 seconds at placement 0. Some
runs overlapped, and times include licence checkout and report generation;
these times are operational observations, not controlled router-speed results.
No board programming, new DSP implementation or frequency claim follows from
this experiment. Changes remain local and uncommitted.


## E1 reset experiment on 2026-11-08

[E1-PAYLOAD-RESET](2026-11-08-E1-PAYLOAD-RESET.md) tests the next bounded
step independently of division specialization. It passes the Haskell suite,
the full cache/CDC guest, and a new warm-reset equivalence test with a failing
negative control. All 309 E1 payload global-reset connections disappear, while
validity remains resettable; direct core reset fanout falls 8%.

Nevertheless both matched placements regress: 72.794 MHz at placement 3 and
78.219 MHz at placement 0, versus baseline 84.447 and 81.055 MHz. Area rises
slightly and other control/front-end paths become limiting. Default E1 reset
is restored; retain the patch and test infrastructure. Step 3 has now been
experimented with, but is not adopted. A coherent multi-stage payload/control
trial and its floorplan remain hypotheses to price, not proven improvements.


## Four-trial follow-up on 2026-11-08

[FOUR-REFACTOR-TRIALS](2026-11-08-FOUR-REFACTOR-TRIALS.md) completes the
combined payload-reset, bounded floorplan, integrated DSP counter and
registered division-service experiments. All functional gates used for the
prototypes pass. Seven of eight routes complete; combined-reset placement 0
hits the 1,200-second bound without a timing report.

Combined reset cuts core reset loads 29%, but increases logic and fails the
existing placement-3 gate. A wider slow-region floorplan recovers 81.247 MHz;
removing the floorplan falls to 67.682 MHz. One model-validated ALU54D counter
saves 88 whole-design logic units and 33 registers, reaching 77.540 / 81.256 MHz
at placements 3 / 0. The registered divider adds 192 logic units and 69
registers, reaching 78.986 / 81.272 MHz. Baseline remains 84.447 / 81.055 MHz.

Keep the passing default. The DSP boundary is the strongest candidate for
further placement and board qualification; neither it nor the division service
improves timing robustly across the two placements. Wide enable distribution
remains, and the limiting paths shift to BRAM feedback or pipeline control.
The trial report retains patches, model tests, functional receipts, constraints,
area/fanout counts, hard-block placements and timing/congestion evidence.

## Acceptance method, revised on 2026-11-08

The three experiment records above judged each change by Fmax at placement 3
and placement 0 against the baseline's 84.447 and 81.055 MHz. That cannot
separate a design effect from placement: the baseline netlist itself spans
78.8 to 84.4 MHz across placement options 0 to 3 with the same floorplan
([THREE-CLOCK-PORT](2026-11-06-THREE-CLOCK-PORT.md)); the combined-reset
netlist spans 67.7 to 81.2 MHz across three floorplans at one placement; the
DSP counter is behind the baseline at placement 3 and ahead at placement 0.
Every change re-rolls the placement, and the median roll is below the
baseline's best, so the method reports a regression for any change at all.
None of the recorded "regressions", and none of the "improvements", is
established by those runs. From here:

1. **Intermediate steps are judged on deterministic metrics only**: the
   functional gates (Haskell properties, the Verilator cache/CDC guest, the
   warm-reset equivalence bench where reset or state ownership changes, the
   vendor model where a hard block is used); synthesized core LUT4
   equivalents by structure (`area_census.py`), whole-design logic and
   registers; direct reset and clock-enable loads; and logic levels per
   pipeline loop from a 3,000-path census at one placement. Occupied slices
   and Fmax from a single placement are recorded but decide nothing.
2. **Routing is measured as a distribution, never a draw.** Baseline and
   candidate are each routed at placement options 0 to 4 and placer targets
   87, 89 and 91 MHz (the tool has no seed; these fifteen settings are the
   available draws), with regenerated floorplans. Report the pass count at
   81 MHz and the median Fmax; a candidate is "not worse" when both are
   within one pass and 1 MHz of the baseline's, and "better" only when the
   whole distribution moves. Report every failure.
3. **Only aggregates are routed.** A candidate earns a routing distribution
   when it removes at least 1,500 LUT4 equivalents, or cuts the logic depth
   of a limiting loop, or changes the floorplan rules. Smaller steps are
   combined first and judged by item 1.
4. **Floorplans are regenerated for each netlist and sized from the
   census**: each region should get about 1.5 times the slices its group's
   logic needs at the design's packing. Today the plan carries fixed rows;
   deriving them from the census is the next change to `floorplan_cst.py`.
5. Unchanged: identical ROM bytes for comparisons, fresh preset builds with
   their own ROM identity for adoption, and the board gates.

The 3,000-path census needs the `report_timing` line in the SDC;
`pnr_only.sh` writes it under `PNR_REPORT_PATHS` since 8cc61ed. The three
records' 25-path samples came from runs without it.
