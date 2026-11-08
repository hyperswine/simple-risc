# A-to-F validity gating refactor

Kind: isolated RTL experiment and five-placement comparison.
Status: complete, 2026-11-08. Physical baseline is `dcd220d`; existing unrelated
work is retained. Current source also contains an unused division helper.
The [earlier regenerated control](2026-11-08-E1-PAYLOAD-RESET.md) is identical
to the frozen production RTL except source-location comments. This trial
rechecks that equivalence and that current source matches that control except
Haskell line comments before applying the candidate patch.

Follows the [BTB feedback-region experiment](2026-11-08-BTB-FEEDBACK-REGION.md),
which moved the worst path to A-to-F without improving the overall result.

## Trace and hypothesis

The frozen layout maps `pipeState_7808_s0` to the A-stage valid tag, and
`pipeState_7692_s0` to A's `fRaw[14]`. The feedback-region placement-0 worst
path starts at the valid tag and ends in F's predicted-PC payload. Placement 1
instead starts at raw instruction bit 14 and ends in the expanded F word.
Its five logic levels contain 1.918 ns of cell delay and 12.812 ns of routing.
These are two different paths: prediction gating and instruction expansion.

The source uses `fromMaybe (Fetched 0 0 False False 0 0 4) (pA pipe)` before
link arithmetic, raw control decode and predicted-PC selection. That introduces
validity-controlled default payload values before combinational datapaths.
The first bounded trial removes this input gating, not the decompressor or
FIFO architecture. It tests whether moving validity to consumption/storage
reduces the valid signal's fanout and routing impact.

## Isolated candidate

The patch lives under `output/a-to-f-2026-11-08/candidate-source/`; default
source and presets are unchanged.

- Extract A payload with `fromJustX`; invalid payload is deliberately unspecified.
- Feed expansion/prediction from that payload, and write F only under `fPush`,
  which already requires A validity and space and excludes a front redirect.
- Keep RAS update and steering under their existing `fPush` guards.
- Mask the unconditionally stored `pFrontTarget` after target arithmetic:
  valid A stores the target, invalid A stores zero. This preserves the previous
  defined invalid-A value (`rawControl 4 0` has no return and a zero JAL offset).

The correctness requirement is that invalid payload cannot affect any consumed
value or side effect. The change adds no stage, alters no handshake, and does
not remove reset. Host properties, generated-RTL cache/CDC regression with
negative controls, and warm-reset equivalence are gates before routing.

## Matched physical protocol

Use the canonical floorplan policy for both arms. Do not combine the RTL
change with BTB anchors or the feedback region. Generate the slow-region
membership from the candidate netlist with the same plan and pipeline-boundary
exclusions. The `Pipe` and payload types are unchanged, so layout metadata is
unchanged and generated widths must agree.

Copy all wrapper/peripheral inputs from the frozen baseline build, substitute
only the production core RTL, and use identical ROM bytes, clocks and tool
options: CPU/cache 81 MHz, SDRAM 48 MHz, target options 89, map 3, route 1,
route fanout 8, and 3,000 setup paths. Baseline controls are the five previously
measured canonical placements, imported with hashes. Run five new candidate
placements 0–4 in fixed order 3, 0, 1, 2, 4, up to three concurrent jobs,
with a 1,800-second timeout per attempt. No tuning during the sweep.

Compare synthesized area and direct input-pin loads, route completion,
pass counts, Fmax/slack, occupied CLS, and A-to-F path routing/logic delay.
Report failures and conditional medians explicitly. The five placement
options are not independent random seeds; baseline options 1 and 2 duplicate
one another. Critical-path samples can change endpoints and do not describe
all wiring. A successful tool run is not board qualification.

## Functional and synthesis results

The isolated candidate passes all 74 SimpleRisc properties and eight PsramRegs
properties. The test modules were mechanically renamed and their package imports
removed so GHC compiled the candidate source directly, rather than linking the
installed baseline library. Generated observed RTL passes the compressed cache/CDC
guest with the production 64 KiB two-way cache, including corrupt-beat, duplicate-store
and wrong-path-store negative controls. Warm-reset equivalence passes 20 resets
(seven during holds), 493 matching commits and 130 stores; ignoring candidate resets
is correctly rejected.

| Synthesized metric | Baseline | Candidate | Change |
|---|---:|---:|---:|
| A-valid direct input-pin loads | 142 | 32 | -110 (-77.5%) |
| Largest A-register direct fanout | 142 | 79 | -63 |
| A raw bit 14 direct input-pin loads | 69 | 64 | -5 |
| Median A-register direct fanout | 3 | 4 | +1 |
| Core LUT4 equivalents | 12,834 | 12,628 | -206 (-1.6%) |
| Whole-design synthesis logic | 15,074 | 14,872 | -202 (-1.3%) |
| Registers | 5,436 | 5,436 | 0 |
| DSP macros / BSRAMs | 3 / 40 | 3 / 40 | 0 |

Fanout here means direct non-clock input-pin loads in the synthesized core,
not post-route buffer/replica fanout. Reset remains at 3,849 loads. Raw decode
fanout remains significant (`fRaw[12]` is 79 loads versus 84 baseline). The
whole-design logic metric is Gowin's utilization total, including its RAM16
charge; it is not just the hierarchical LUT-plus-ALU sum. The refactor gives a
real structural reduction; the placement-level results follow.

## Results

Five new candidate attempts are complete. Five baseline measurements are
explicitly imported from the earlier canonical sweep.

| Arm | Passes / 5 | Timing failures | Unrouted | Timeouts | Timing reports | Median completed Fmax |
|---|---:|---:|---:|---:|---:|---:|
| baseline | 2 | 2 | 1 | 0 | 4 | 79.911 MHz |
| candidate | 0 | 5 | 0 | 0 | 5 | 68.301 MHz |

Medians exclude attempts without completed timing reports. They are conditional,
not a full-grid median when reports are missing.

| Placement | Baseline | Validity refactor | Baseline CLS | Candidate CLS |
|---:|---|---|---:|---:|
| 0 | 81.055 MHz / +0.008 ns (pass) | 68.301 MHz / -2.295 ns (timing-fail) | 8687 | 8866 |
| 1 | 78.766 MHz / -0.350 ns (timing-fail) | 67.338 MHz / -2.505 ns (timing-fail) | 8649 | 8782 |
| 2 | 78.766 MHz / -0.350 ns (timing-fail) | 67.338 MHz / -2.505 ns (timing-fail) | 8649 | 8782 |
| 3 | 84.447 MHz / +0.504 ns (pass) | 76.327 MHz / -0.756 ns (timing-fail) | 8717 | 8814 |
| 4 | 557 unrouted nets | 80.545 MHz / -0.070 ns (timing-fail) | 8629 | 8747 |

Across 4 mutually completed placements, the candidate is faster in 0; median paired Fmax change is -11.428 MHz.

## A-to-F timing and remaining bottlenecks

| Placement | Baseline sampled A-to-F worst slack | Candidate sampled A-to-F worst slack | Baseline / candidate median A-to-F route delay | Baseline / candidate A-valid paths | Candidate overall worst structure |
|---:|---:|---:|---:|---:|---|
| 0 | +0.299 ns | +1.035 ns | 7.358 / 6.735 ns | 43 / 0 | fetch -> btb |
| 1 | -0.184 ns | +1.265 ns | 6.631 / 5.802 ns | 53 / 0 | btb -> btb |
| 2 | -0.184 ns | +1.265 ns | 6.631 / 5.802 ns | 53 / 0 | btb -> btb |
| 3 | +2.148 ns | -0.289 ns | 5.652 / 7.613 ns | 1 / 0 | btb -> btb |
| 4 | Unavailable | +0.034 ns | Unavailable / 7.315 ns | Unavailable / 0 | M -> D |

These samples can have different endpoints and sizes. Positive sampled A-to-F
slack does not prove every unreported A-to-F path improved. Missing A-valid
paths are not assigned zero delay. Direct synthesized fanout is the independent
evidence that the RTL changed the targeted structure.

| Placement | Matching A-to-F endpoint pairs | Median matched route-delay change |
|---:|---:|---:|
| 0 | 4 | +0.803 ns |
| 1 | 0 | Unavailable |
| 2 | 0 | Unavailable |
| 3 | 0 | Unavailable |

Endpoint matches use source register and destination pin; intermediate arcs
and transition polarities may differ. See `af-paths.json` for all observations.

## Decision

Do not adopt this patch into the canonical preset. All five candidate routes
complete, versus four baseline routes, but none passes the 81 MHz gate. The
best candidate is placement 4 at 80.545 MHz with -0.070 ns slack; baseline
placement 3 remains 84.447 MHz with +0.504 ns. All four mutually completed
placements regress. Placements 1 and 2 have identical timing/site fingerprints
in both arms; these are duplicated reported outcomes, not independent seeds.

The source-level hypothesis is partly confirmed: A-valid direct fanout drops
77.5%, whole-design synthesis logic drops 202, and no candidate A-valid-to-F
path appears in the sample. This does not establish a routing-delay win.
The four matching A-to-F endpoint pairs at placement 0 have a median +0.803 ns
route-delay change. The other matched placements have no shared sampled
endpoint pairs. Sample-wide medians improve at 0–2 but worsen at 3; comparing
them as though they were the same paths would be misleading.

The raw decode bottleneck remains. At placement 3, A.fRaw[9] to F.fUsesRs2
has -0.289 ns slack and 9.249 ns of routing delay. The overall worst paths
are fetch-to-BTB at placement 0, BTB feedback at 1–3, and M-to-D at 4. The
refactor changes the placement of competing loops rather than solving them.
Placement 0 already puts the RAM halves at the previous R28[12]/R28[13]
anchor pair without constraints, yet fails on fetch-to-BTB; RAM adjacency
alone is not an adequate explanation or remedy.

Fewer synthesized logic resources do not translate into a smaller physical
footprint here. Occupied CLS increases at every option; its grid median rises
from 8,649 to 8,782 (including the baseline unrouted placement's packing).
Register, DSP, BSRAM and reset-load counts do not change. Retain the patch as
a verified experimental primitive, not a timing-qualified replacement.

The next RTL hypothesis should address the remaining raw-instruction and
compressed-decode fanout, while monitoring fetch/BTB and M-to-D as competing
limits. This trial provides no basis for combining the patch with the failed
broad front-end or BTB feedback regions. Any new combination needs its own
matched sweep rather than an assumed additive benefit.

## Evidence and validation

The input audit verifies all ten netlist/constraint/option combinations, ROM
and clock equality, imported-control provenance, the candidate source hashes,
and the generated Pipe width against layout metadata. The canonical floorplan
is regenerated and checked for deterministic membership. All non-core wrapper
and peripheral inputs are copied unchanged. Functional receipts retain the
positive and negative controls. Python compilation and whitespace checks pass.

[Patch, scripts, reports and receipts](evidence/2026-11-08-a-to-f/) include
compressed production/observed RTL and the synthesized candidate netlist, with
a SHA-256 manifest. Full timing reports remain in `output/a-to-f-2026-11-08/`;
evidence retains their hashes and compact reports. No board was programmed.
Default source and presets remain unchanged; this experiment is local and
uncommitted.
