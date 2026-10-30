# Return stack, straddling branches and the assembly-stage correction

Kind: core change, simulation and timing builds, 2026-10-30. Follows
[STALL-SPLIT](2026-10-30-STALL-SPLIT.md), which ranked these as the first two
structural fixes. No board run.

## Result

On the frozen classifier at 48/48 MHz the core takes **1.179x fewer cycles**
(IPC 0.272 to 0.320). The classifier output is correct (train 124/128 digest
21562, test 61/64 digest 909572).

At the next clock step (60 MHz, placer over-constrained to 66 MHz) the new
design passes timing at two of three placements; HEAD passes all three. The
third placement did not route (86 unrouted nets). The design now uses 86% of
the slices, against 82% for HEAD, so routing congestion is the new risk, not
logic depth.

Judged as speed = Fmax x IPC, at each design's worst passing placement:

| Design | Worst passing Fmax | IPC | Fmax x IPC |
|---|---:|---:|---:|
| HEAD | 61.4 MHz | 0.272 | 16.7 |
| This change | 61.5 MHz | 0.320 | 19.7 (1.18x) |

## What changed

- **Straddling branches are installed.** A 32-bit instruction that starts in a
  word's upper half was never trained into the BTB. Its entry is now keyed on
  its second word, at slot 0, which is where fetch looks it up. Assembly takes
  the prediction from the second word.
- **Return address stack, 8 deep, compressed mode only.** Calls (jal/jalr with
  rd in {x1, x5}) push their link and returns (jalr x0 with rs1 in {x1, x5})
  pop, as they leave A for F. That speculative stack is restored from a
  second, in-order stack on every restart. Returns are no longer trained into
  the BTB.
- **Assembly-stage correction.** When A holds a return whose prediction is not
  the stack's top, or a JAL whose prediction is not its target, fetch is
  steered there next cycle. Only fetch, the word queue and A are discarded; F
  onwards keeps running. E2 still checks every prediction.
- **Timing-shaped decision.** The decision reads A's raw bits (`rawControl`,
  no RV32C expansion), compares only the low prediction bits, and the target
  is registered on its own (`pFrontTarget`). The late E2 branch decision no
  longer selects between two targets; fetch picks from registered signals.

## Simulation

| Variant | Cycles | Speedup | IPC |
|---|---:|---:|---:|
| HEAD | 145,460,221 | 1.000 | 0.272 |
| Return stack + straddle | 131,814,145 | 1.104 | 0.300 |
| + JAL correction | 123,246,225 | 1.180 | 0.321 |
| Raw-bit decision (and split register, cycle-identical) | 123,405,043 | 1.179 | 0.320 |

With the return stack, E2 sees 33 return redirects instead of about 970,000.
JAL redirects from E2 go to zero.

## Timing

Two methods were used. The first, 48 MHz builds at five placements, mostly
measures placement luck: HEAD ranged from 66 to 81 MHz. The second is
pass/fail at the next useful clock (60 MHz, the board's SDRAM limit with a
112.5 degree read phase), with the placer aimed at 66 MHz, at three placements.

| 60 MHz build | Placement 0 | Placement 2 | Placement 3 |
|---|---|---|---|
| HEAD | pass, 75.2 | pass, 71.6 | pass, 61.4 |
| Shared redirect register | **fail, 55.7** | pass, 64.8 | pass, 63.0 |
| Split target register (this change) | **no route** | pass, 61.5 | pass, 70.5 |

With the shared register, the worst paths ran from the E2 compare through the
new target mux into `pRedirect`. With the split register, the worst paths are
older ones: the decode hazard check into `pDBlocked`, and the BTB lookup into
the fetch pc.

| Build at placement 0 | Logic | Registers | CLS |
|---|---:|---:|---:|
| HEAD | 14,304 (69%) | 5,308 | 8,488 (82%) |
| This change | 16,056 (78%) | 5,861 | 8,881 (86%) |

Most of the 553 new registers are the two 8 x 32 return stacks.

## Open

- **Size.** The second (in-order) stack exists only to restore the first. A
  single stack with a saved pointer, or 4 entries, would cut most of the new
  registers. The predictor replay model can price a smaller stack before a
  build.
- **Not run on the board.**
- The larger BTB (64 entries) from STALL-SPLIT is the next predictor step, but
  it would add area while area is the constraint.

## Evidence

[evidence/2026-10-30-return-stack/](evidence/2026-10-30-return-stack/):
`results.json` and `run.log` (simulation), `timing-48mhz.txt`,
`timing-60mhz.txt`, the build scripts, `resources.txt`, and `rtl.sha256` for
the netlists built.
