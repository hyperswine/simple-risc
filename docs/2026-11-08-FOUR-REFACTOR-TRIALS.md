# Four structural refactor trials

Kind: goal execution, isolated prototypes and measurements, 2026-11-08.
Follows [ARCHITECTURAL-REFACTOR](2026-11-07-ARCHITECTURAL-REFACTOR.md) and
[E1-PAYLOAD-RESET](2026-11-08-E1-PAYLOAD-RESET.md). The goal is to execute all
four trials, not to require each hypothesis to improve the design.

## Trials and controls

1. Remove D/E1/E2/M payload reset together, retaining resettable validity and
   existing logical hold behavior. Compare against the passing baseline at
   placements 3 and 0.
2. On that same synthesized netlist, compare the existing floorplan, no
   floorplan, and one bounded adjustment at placement 3: CSR rows 2-11 instead
   of 2-9, bus rows 36-53 instead of 38-53, with columns and free-boundary rules
   unchanged. This is a small comparison, not an optimal-floorplan search.
3. Validate an ALU54D counter using the vendor simulation model, then move
   physical `mcycle` ownership outside the broad Machine/HeldState composition
   and into that counter. Preserve partial writes, delayed carry and ticking
   through memory holds. Compare integrated synthesis and routing.
4. Move division execution into a registered command/completion service with
   independent state and explicit cancellation/consumption. Keep the original
   iterative arithmetic, so this trial does not combine the earlier
   division-only optimization with the boundary change.

All prototypes live in isolated source snapshots under
`output/refactor-four-2026-11-08/`. The default source and canonical presets
remain unchanged. Baseline is `dcd220d`; the retained unused helper affects
only generated source-location comments, as the preceding control verified.
CPU/cache 81 MHz and SDRAM 48 MHz, identical stamped ROM bytes, target 89 MHz,
map 3, route 1, route fanout 8. Generate constraints from each netlist.

Tests use observed RTL; physical measurements use production RTL. Routing
reports contain 25 setup paths, so reported routing-share averages describe
that sample. Run times include overlapping jobs and licence/report overhead.
A timing pass is not board adoption or SDRAM electrical qualification.

## Combined payload reset and placement

The combined variant passes the cache/CDC guest including corruption and
cancelled/duplicate-store controls. It also passes warm-reset equivalence,
including processor-level writes/reads of both `mcycle` halves: 20 warm resets,
seven asserted while held, 493 retirements and 130 stores match. Ignoring the
candidate's warm resets is rejected after the first reset.

Direct core reset input loads fall from 3,849 to 2,737 (-29%). Core LUT
equivalents rise from 12,834 to 12,910; whole-design synthesis logic from
15,074 to 15,150. Register count remains 5,436.

| Combined reset configuration | Fmax | Setup slack | Setup violations |
|---|---:|---:|---:|
| Existing floorplan, placement 3 | 75.231 MHz | -0.947 ns | 39 |
| Existing floorplan, placement 0 | timeout at 1,200 s | no report | unknown |
| No floorplan, placement 3 | 67.682 MHz | -2.429 ns | 211 |
| Wider slow regions, placement 3 | 81.247 MHz | +0.038 ns | 0 |

The wider regions recover a passing result on the identical netlist, but with
much less margin than the baseline's 84.447 MHz / +0.504 ns. This supports
measuring structure and placement together; it does not justify replacing the
canonical image. Occupied CLS is 8,752 / 8,837 / 8,778 for the three placement-3
rows respectively, against baseline 8,717. Lower reset fanout did not reduce
packing cost.

## DSP counter

The old 54-bit accumulator probe's `CASO[54]` stays high after overflow; it is
registered accumulator state, not a pulse suitable for adding to the tail on
every clock. A vendor-model check reproduces that behavior.

The revised counter uses one registered ALU54D in A+B mode. Feed back only the
low 32 bits, add the increment, and expose bit 32 as the registered carry.
The fabric high word applies that carry next cycle, exactly matching
`tickCounter`. Writes suppress increment; low writes drain an earlier carry,
while high writes replace it. The vendor-model test passes 10,015 checks,
including overflow, writes, increment pauses and resets.

The integrated trial injects this counter's state into the core and exports
its CSR-write command. The old cycle state is constant in Machine/HeldState,
so synthesis removes it. A Verilog wrapper contains the counter. Production
synthesis uses the hardware primitive; simulations use the vendor model.
The floorplan targets `core/logic_core` inside the wrapper.

The integrated cache/CDC guest passes. Warm-reset/CSR-write equivalence also
passes (20 resets, 493 retirements, 130 stores), with the failing negative
control. Whole-design synthesis logic falls from 15,074 to 14,986 (-88),
registers from 5,436 to 5,403 (-33). The core-module census excludes the new
external counter, so whole-design resources are the fair comparison.

The synthesized design contains one ALU54D. Placement 3 reaches 77.540 MHz
(-0.551 ns, five setup violations), below the 81 MHz gate. Placement 0 passes
at 81.256 MHz (+0.039 ns, no setup/hold violations), slightly above baseline
placement 0 at 81.055 MHz (+0.008 ns). Occupied CLS is 8,759 / 8,754 at
placements 3 / 0, versus baseline 8,717 / 8,687: the logic saving does not
translate into fewer occupied slices. No new DSP bitstream has been
board-qualified.

## Registered division service

The service accepts a command only when idle, registers opcode and operands,
executes the existing iterative unit, and holds a registered result until the
CPU can consume it. Cancellation wins over command acceptance and completion.
The pipeline retains precise destination/continuation context; service state
is independent of Machine. Completion may wait through a cache hold.

A pure service test passes 2,196 opcode/operand cases against integer semantics,
including zero divisors and signed overflow, held completions, consumption,
and cancellation at every execution cycle. The initial RTL build exposed a
Clash backend issue with equality on the custom one-hot CpuPhase type; an
explicit case match avoids it. This does not change the phase encoding.

The integrated cache/CDC guest passes, including precise traps and corruption,
duplicate-store and cancelled-store negative controls. Whole-design synthesis
logic rises to 15,266 (+192), registers to 5,505 (+69); core reset loads fall
to 3,717, while the largest direct clock-enable load remains 487. Placement 3
reaches 78.986 MHz (-0.315 ns, one setup violation); placement 0 passes at
81.272 MHz (+0.041 ns, no setup/hold violations). Occupied CLS rises to
8,800 / 8,868 at placements 3 / 0. This is a small placement-0 timing gain
with an area cost and a placement-3 regression.
This service changes
latency, so cycle-for-cycle baseline equivalence is not its acceptance test;
use architectural results and side-effect checks instead.

## What the paths show

At placement 3, the combined-reset and DSP worst paths return from a core
BRAM output to its address input, rather than originating at reset or the
new DSP counter. The division-service worst path runs from the M-slot valid
bit (`pipeState[6079]`) to D blocked state (`pipeState[7205]`), a nine-level
control path. This is evidence that local arithmetic/reset changes still
leave front-end and pipeline control routing as the limiting work.

Across the 25 reported setup paths, mean routing share is 67.4% for combined
reset with the existing floorplan, 68.7% without it, and 61.4% with wider slow
regions. DSP is 73.1% and division service 67.7%. These samples describe
critical paths, not total device wiring or global-routing utilization. The
largest direct core clock-enable load stays 487 in every variant; this set
of changes does not solve the wide enable distribution. Baseline mean routing
share is 79.9%, but its paths have different endpoints and still meet timing
with more margin; a lower routing percentage alone is not a speed improvement.

The tool-reported whole-design reset-net fanout is 4,071 at baseline, 2,959
for combined reset, 4,039 for DSP and 3,939 for division. This differs from
the core-only pin census above, especially for the external DSP counter.
Peak reported grid congestion at placement 3 is 0.917 baseline, 0.903 combined
reset/existing floorplan, 0.931 no floorplan or wider regions, 0.944 DSP and
0.931 division. The wider-region timing pass therefore does not demonstrate
a general reduction in device congestion.

## Evidence and adoption

Source patches, preparation scripts, model tests, generated-input hashes,
functional receipts and synthesis/routing reports are retained in
[evidence/2026-11-08-four-trials/](evidence/2026-11-08-four-trials/).
All four trials are complete. Combined-reset placement 0 exceeded its
1,200-second routing limit after routing phase 1 and produced no timing report;
this is incomplete routing, not a measured setup/hold result. Other seven
routes completed. None of the prototypes is activated in the default source. The DSP counter is the strongest follow-up candidate:
correct vendor-model behavior, reduced synthesis logic/registers, and one
integrated 81 MHz timing pass. It still needs placement robustness and board
qualification. The division service establishes a working architectural
boundary, but its area increase and mixed timing do not justify adoption.
The reset/floorplan experiment shows how much placement can change timing,
without proving an area or congestion improvement.


Changes and evidence remain local and uncommitted. No board programming was
performed. The source patches apply independently to baseline `dcd220d`;
the default core implementation and canonical presets are unchanged.
