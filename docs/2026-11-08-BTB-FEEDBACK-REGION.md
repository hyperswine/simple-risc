# A small region for the BTB feedback logic

Kind: frozen-netlist physical experiment on canonical `dcd220d`.
Status: complete, 2026-11-08.

Follows the [isolated anchors/grouping sweep](2026-11-08-BTB-PLACEMENT-ABLATIONS.md).
That sweep made every anchors-only route complete, but BTB feedback remained
the worst path. The broad front-end register group made routing worse.

## Hypothesis and fixed candidate

Keep the two BTB RAM anchors at `BSRAM_R28[12]` and `BSRAM_R28[13]` and add
one small region for the combinational feedback logic. This isolates the
incremental effect of grouping feedback logic against anchors-only; baseline
provides a second reference. It is not a test of this region with unanchored RAMs.

The generator walks the scalarized netlist graph forward from both BTB `DO`
ports and backward from both BTB `ADB` ports, stopping at sequential/hard-block
boundaries. Their intersection selects 37 primitive cells, including the full
seven-cell carry chain; carry-chain closure adds no further cells. There are
15 LUT5, nine LUT4, three LUT3, three LUT2 and seven ALU primitives: 52 LUT4
equivalents. It does not group all 200 cells in the address fan-in, or the
1,150 front-end registers from the previous trial. Side inputs and other
consumers remain free, so shortening the loop can lengthen other paths.

The region is **R[27:29]C[35:46]**, non-exclusive. Its 12-column band is centered
on column 40, the rounded median observed column of the selected cells across
the five anchors-only timing reports. Each observed cell/location is counted
once per report, not once per timing path; placements 1 and 2 are known duplicate
implementations. This empirical center is not a verified physical-column
mapping of BSRAM indices. Rows straddle the fixed RAM row 28 with at least
one fabric row on each side.

At baseline placement-3 packing (1.7403 logic/CLS), 52 LUT equivalents with
50% allowance require 45 CLS. Excluding hard-block row 28 and estimating four
CLS per tile gives 96 CLS in the selected region. This is a capacity estimate,
not an exhaustive legal-packing or routing guarantee. The earlier broad
region estimated 2,880 CLS. The new region and membership are fixed before
routing and will not be tuned to the results.

Gowin's installed `SUG1541-1.0E` physical-constraint guide, section 2.5.1,
documents primitive groups including LUTs. The CST contains explicit primitive
names and both `GROUP` and `GRP_LOC`; tool diagnostics and reported cell
locations will be checked. Hard-block `.posp` files alone do not verify LUT
placement; timing-path locations provide a partial observation of the region.

## Matched protocol

Five new runs use placements 0–4, execution order 3, 0, 1, 2, 4, up to three
concurrent jobs and the same 1,800-second timeout per attempt as the preceding
sweep. Ten controls are imported with hashes: five canonical baseline and
five anchors-only results. They are reused measurements, not fresh runs.

All use the same frozen netlist and ROM, 81 MHz CPU/cache and 48 MHz SDRAM,
frequency options 89, map 3, route 1, route fanout 8, and 3,000 reported paths.
Canonical CSR R[2:9]C[2:55] and bus R[38:53]C[2:19] constraints remain byte-for-byte
unchanged. Feedback differs from anchors-only by exactly two CST statements.
There is no RTL, default-preset or board-programming change.

Report all five outcomes per arm, pass counts, routing failures, conditional
Fmax medians, matched-placement changes, occupied CLS, path structures and
absolute routing delay. Timing samples can change endpoints; compare matching
BTB source/destination pins separately where possible. No Fmax is assigned to
unrouted or timed-out runs. The fixed grid is not five independent random seeds.

## Results

Five new feedback-region attempts are complete. The ten baseline and
anchors-only controls are imported from the preceding sweeps.

| Arm | Passes / 5 | Timing failures | Unrouted | Timeouts | Timing reports | Median completed Fmax |
|---|---:|---:|---:|---:|---:|---:|
| baseline | 2 | 2 | 1 | 0 | 4 | 79.911 MHz |
| anchors | 3 | 2 | 0 | 0 | 5 | 81.171 MHz |
| feedback | 2 | 3 | 0 | 0 | 5 | 76.389 MHz |

Medians exclude failures without timing reports and are therefore conditional,
not full-grid medians when fewer than five reports exist.

| Placement | Baseline (imported) | Anchors only (imported) | Anchors + feedback region |
|---:|---|---|---|
| 0 | 81.055 MHz / +0.008 ns (pass) | 81.171 MHz / +0.026 ns (pass) | 81.480 MHz / +0.073 ns (pass) |
| 1 | 78.766 MHz / -0.350 ns (timing-fail) | 81.520 MHz / +0.079 ns (pass) | 66.678 MHz / -2.652 ns (timing-fail) |
| 2 | 78.766 MHz / -0.350 ns (timing-fail) | 81.520 MHz / +0.079 ns (pass) | 66.678 MHz / -2.652 ns (timing-fail) |
| 3 | 84.447 MHz / +0.504 ns (pass) | 78.977 MHz / -0.316 ns (timing-fail) | 76.389 MHz / -0.745 ns (timing-fail) |
| 4 | 557 unrouted nets | 78.037 MHz / -0.469 ns (timing-fail) | 81.064 MHz / +0.010 ns (pass) |

## Area and routing

No synthesis change was made: this is the same logic, registers, DSPs and
BRAMs. Logical fanout is unchanged. Occupied CLS can change through packing; a
lower CLS count on a failed route is not a usable area win.

| Placement | Baseline CLS | Anchors CLS | Feedback CLS | Feedback peak reported congestion |
|---:|---:|---:|---:|---:|
| 0 | 8687 | 8776 | 8833 | 0.944 |
| 1 | 8649 | 8718 | 8782 | 0.944 |
| 2 | 8649 | 8718 | 8782 | 0.944 |
| 3 | 8717 | 8694 | 8665 | 0.931 |
| 4 | 8629 | 8823 | 8858 | 0.931 |

Matched completed placement comparisons:

- Versus baseline: 4 matched reports, 1 faster and 3 slower; median paired Fmax change -10.073 MHz.
- Versus anchors: 5 matched reports, 2 faster and 3 slower; median paired Fmax change -2.588 MHz.

Placements 1 and 2 duplicate each other in both control arms. Report fingerprints
compare the parsed timing paths and hard-block sites, not every placed fabric cell.

| Arm | Distinct passing report fingerprints |
|---|---:|
| baseline | 2 |
| anchors | 2 |
| feedback | 2 |

## Feedback-path observations

| Completed feedback placement | Worst structure | Worst slack | Worst-path routing | Observed grouped cells / 37 | BTB DO-to-ADB paths in sample |
|---:|---|---:|---:|---:|---:|
| 0 | A -> F | +0.073 ns | 8.268 ns | 14 | 0 |
| 1 | A -> F | -2.652 ns | 12.812 ns | 14 | 0 |
| 2 | A -> F | -2.652 ns | 12.812 ns | 14 | 0 |
| 3 | A -> F | -0.745 ns | 8.985 ns | 23 | 0 |
| 4 | M -> D | +0.010 ns | 8.274 ns | 14 | 0 |

All observed grouped-cell coordinates in completed feedback runs lie inside
R[27:29]C[35:46]; all completed runs retain the requested RAM anchors. The
reports do not expose every grouped cell, so this is partial location validation.

| Placement | Comparison | Matching BTB endpoint pairs | Median route-delay change |
|---:|---|---:|---:|
| 0 | Feedback versus baseline | 0 | Unavailable |
| 0 | Feedback versus anchors | 0 | Unavailable |
| 1 | Feedback versus baseline | 0 | Unavailable |
| 1 | Feedback versus anchors | 0 | Unavailable |
| 2 | Feedback versus baseline | 0 | Unavailable |
| 2 | Feedback versus anchors | 0 | Unavailable |
| 3 | Feedback versus baseline | 0 | Unavailable |
| 3 | Feedback versus anchors | 0 | Unavailable |
| 4 | Feedback versus anchors | 0 | Unavailable |

An absent BTB feedback path in the 3,000-path sample is not a measured zero
delay or a quantified improvement. The worst reported path can move elsewhere
without proving all BTB paths improved. Matching endpoint pins also does not
guarantee identical intermediate arcs or transition polarity.

## Decision

Do not adopt this feedback region. It routes all five options, matching
anchors-only, but passes two rather than three. Placements 0 and 4 improve
against anchors-only by +0.309 and +3.027 MHz; placements 1 and 2 lose
14.842 MHz each and placement 3 loses 2.588 MHz. The completed-grid median
falls from 81.171 to 76.389 MHz. These are different statistics from the
median paired change above. Placements 1 and 2 also duplicate each other in
the feedback arm, so the five options are not independent observations.

The two passing margins are only +0.073 and +0.010 ns. Occupied CLS rises
in four of five placements against anchors-only, with medians 8,782 versus
8,718. There is no area or fanout win. The canonical preset remains unchanged;
anchors-only retains its earlier status as an optional candidate.

The targeted group changes the limiting path without delivering an overall
improvement. All five new worst paths lie outside the 37 constrained cells:
A-to-F for placements 0–3 and M-to-D for placement 4. At placement 1, the
worst path has just five logic levels, 1.918 ns of cell delay and 12.812 ns
of routing delay (85.631% of its arrival data-path delay). This supports an
adverse change in surrounding placement/routing, not a claim that the BTB
feedback cone itself remains critical. It does not identify a unique router
mechanism or quantify how much the unreported BTB feedback paths improved.

This negative result applies to this fixed 37-cell region, anchors and frozen
netlist, not every possible feedback floorplan. Before more geometry sweeps,
a useful next investigation would obtain targeted post-route BTB timing and
trace the shared address-mux side inputs and A-to-F control/data routes.
Broadening the region again is not justified by these results.

## Evidence and validation

Input hashes, all 15 netlist/constraint/option combinations, imported-control
provenance and the exact two-statement addition were checked. The graph-selected
cone covers the intermediate cells in all reported BTB DO-to-ADB paths. Tool
logs contain the constraint acceptance and route outcomes. Python compilation
and whitespace checks pass. Functional simulation was not rerun because no RTL
or synthesized netlist changed. No board was programmed and no preset changed.

[Evidence, scripts and manifests](evidence/2026-11-08-btb-feedback/) retain the
compact reports and full-report hashes. Full timing reports remain under
`output/btb-feedback-2026-11-08/`. Changes are local and uncommitted.
