# BTB anchoring versus front-end grouping

Kind: isolated placement experiments on baseline `dcd220d`.
Status: complete, 2026-11-08. Separates two components of the failed
[combined floorplan](2026-11-08-BTB-FRONTEND-FLOORPLAN.md).

## Controlled comparison

All three arms use the frozen `dcd220d` synthesized netlist, identical ROM
bytes, CPU/cache 81 MHz and SDRAM 48 MHz, map 3, route 1, route fanout 8,
and the same timing constraints. The frequency options stay at 89 MHz;
the preceding sweep showed that 87/89/91 did not add distinct baseline
outcomes in this frozen-netlist flow.

| Arm | Change from canonical floorplan |
|---|---|
| Baseline | None; CSR R[2:9]C[2:55], bus R[38:53]C[2:19], pipeline-coupled slow registers left free |
| Anchors only | Add `RAM_1_RAM_1_0_0_s` at `BSRAM_R28[12]` and `RAM_1_RAM_1_0_1_s` at `BSRAM_R28[13]`; no front-end group |
| Grouping only | Add the 1,150-register fetch/A/F/BTB group in R[17:36]C[16:55]; leave both BTB RAM sites free |

Both candidates retain the canonical slow-region geometry. In particular,
neither carries over the combined trial's bus expansion to R[36:53]. Each
candidate therefore differs from baseline by exactly two CST statements.
The front region is the preceding census-sized region: 3,318 attributed LUT
equivalents, 2,860 CLS required at the measured packing plus 50% allowance,
and an estimated 2,880 CLS capacity. This remains a non-exclusive register
region, not an explicit constraint on every feeding LUT.

The earlier combined candidate changed three things (anchors, front group,
and bus size). These two ablations isolate anchors and grouping against the
canonical baseline; they are not a full factorial test of all three choices.

## Runs and acceptance

Each arm is compared across placement options 0–4. Ten new PNR jobs test the
two candidates. Five baseline controls are imported from the preceding
sweep's target-89 runs, with source paths and hashes recorded explicitly.
Those baseline timing outcomes were reproduced at all three frequency-option
settings. No imported result is described as a new run.

The fixed order is placements 3, 0, 1, 2, 4, interleaving the two candidates,
with three concurrent jobs and a 1,800-second route limit per tool attempt.
All jobs request 3,000 setup paths and hard-block placement output. License
retries may add elapsed time. Elapsed routing time is not a controlled speed
benchmark. No candidate tuning occurs during the sweep.

Report pass counts out of five, every unrouted/timeout result, and median
Fmax conditional on completed timing reports. A full-grid Fmax median is
unavailable when routes do not produce timing reports. Also compare matched
placements, critical path structures and absolute route-delay samples where
both reports exist. These are fixed tool configurations, not independent
random samples. No preset adoption follows from one successful placement.

## Results

Ten new routes are complete; the five imported baseline controls provide
a matched reference across the same five placement options.

| Arm | Passes / 5 | Timing failures | Unrouted | Timeouts | Timing reports | Median completed Fmax |
|---|---:|---:|---:|---:|---:|---:|
| baseline | 2 | 2 | 1 | 0 | 4 | 79.911 MHz |
| anchors | 3 | 2 | 0 | 0 | 5 | 81.171 MHz |
| grouping | 0 | 1 | 4 | 0 | 1 | 67.992 MHz |

Medians are conditional on completed timing reports. Baseline has four
reports, anchors has five; missing routes are not assigned zero Fmax. The
median paired Fmax change for anchors on the four mutually completed
placements is +1.435 MHz, with three faster and one slower.

| Placement | Baseline (imported) | Anchors only | Grouping only |
|---:|---|---|---|
| 0 | 81.055 MHz / +0.008 ns (pass) | 81.171 MHz / +0.026 ns (pass) | 3,759 unrouted nets |
| 1 | 78.766 MHz / -0.350 ns (timing-fail) | 81.520 MHz / +0.079 ns (pass) | 3,525 unrouted nets |
| 2 | 78.766 MHz / -0.350 ns (timing-fail) | 81.520 MHz / +0.079 ns (pass) | 3,525 unrouted nets |
| 3 | 84.447 MHz / +0.504 ns (pass) | 78.977 MHz / -0.316 ns (timing-fail) | 67.992 MHz / -2.362 ns (timing-fail) |
| 4 | 557 unrouted nets | 78.037 MHz / -0.469 ns (timing-fail) | 1,333 unrouted nets |

Occupied CLS reported by the placer (including failed routes):

| Placement | Baseline CLS | Anchors CLS | Grouping CLS |
|---:|---:|---:|---:|
| 0 | 8687 | 8776 | 8511 |
| 1 | 8649 | 8718 | 8487 |
| 2 | 8649 | 8718 | 8487 |
| 3 | 8717 | 8694 | 8608 |
| 4 | 8629 | 8823 | 8620 |

## What the isolation shows

**Anchoring is a viable placement candidate, with a tradeoff.** It completes
all five routes and passes three options, versus four completed routes and
two passes for baseline. It improves placements 0, 1 and 2 and makes
placement 4 routable, but loses the baseline placement-3 pass. Its best
margin is +0.079 ns versus baseline +0.504 ns; its passing margins are only
+0.026 to +0.079 ns. These are gains on the tested grid, not an across-the-board
improvement or a board-qualified replacement.

Placements 1 and 2 have identical timing/site fingerprints in both baseline
and anchors. Both arms therefore still have two distinct *passing* reported
implementations. The 3/5 pass count is useful for these tool settings, but
it is not three independent passing placements.

**The anchors do not eliminate the BTB feedback bottleneck.** Every anchored
worst path returns from a BTB RAM output to a BTB RAM address input. At
placement 3, median sampled BTB-to-BTB routing delay rises from 5.615 to
6.306 ns despite the adjacent sites. At placement 1, the failing baseline
fetch loop (-0.350 ns) and reset-to-E2-enable paths (-0.249 ns) recover;
anchored reset-to-E2-enable slack is +0.932 ns and BTB feedback becomes
limiting at +0.079 ns. The evidence points to a changed overall placement,
not a demonstrated shortening of the BTB return path.

**This front-end region is harmful on the tested grid.** At placement 3 it
reaches only 67.992 MHz with 255 setup violations, and its reported peak
congestion is 0.972 versus baseline 0.917. The worst path is A to F. The
sampled median route delay grows from 6.172 to 8.492 ns for fetch-to-fetch,
and 6.390 to 9.153 ns for fetch-to-A. The register rectangle does not bind
every feeding LUT; free BTB RAMs land at R10[8] and R10[7], above the
R17–36 front region in that run. Restricting the state did not achieve the
intended improvement in physical locality.

The critical-path samples can contain different endpoints across runs.
Their medians are diagnostic samples, not all-wire statistics or proof of
a particular congestion mechanism. The identical netlist gives no synthesis
area or logical fanout reduction. Occupied CLS is not uniformly lower with
anchors (for example, placement 0 rises from 8,687 to 8,776).

Anchors alone and grouping alone both produce a routed timing report at
placement 3; the earlier combined experiment did not. That supports testing
constraint interactions, but does not identify a unique cause: the combined
experiment also widened the bus region. No full factorial test was run.

## Decision and evidence

Keep the canonical preset. Retain anchors-only as an optional candidate for
further qualification, particularly when testing future netlists. Do not
adopt this broad front-end group. A more targeted investigation should
examine the BTB feedback logic and its locality rather than assuming that
adjacent RAMs or a large register rectangle shorten the complete loop.

Constraint membership, imported-control provenance and frozen hashes were
checked. The post-place files verify both requested anchor sites on every
completed anchored route (`CST_BSRAM` marks constrained sites). All reports
request 3,000 paths, and the same 81/48 MHz timing gate is used. No RTL or
default preset changed; no board was programmed. New functional simulation
was unnecessary for the identical frozen netlist.

[Scripts, constraints, receipts and summaries](evidence/2026-11-08-btb-ablation/)
are retained with hashes. Full timing reports remain under
`output/btb-ablation-2026-11-08/`, with imported baseline report origins
explicitly recorded. Changes remain local and uncommitted.
