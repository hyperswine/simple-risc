# Return stack, straddling branches and the assembly-stage correction

Kind: core change, simulation and timing builds, 2026-10-30. Follows
[STALL-SPLIT](2026-10-30-STALL-SPLIT.md), which ranked these as the first two
structural fixes. No board run.

## Result

On the frozen classifier at 48/48 MHz the core takes **1.178x fewer cycles**
(IPC 0.272 to 0.320). The classifier output is correct (train 124/128 digest
21562, test 61/64 digest 909572).

With a 4-entry return stack restored by its pointer only (the final version,
see [Smaller stack](#smaller-stack)), the design passes timing at 60 MHz
(placer over-constrained to 66 MHz) at all three placements, as HEAD does. The
first version, with two 8-entry stacks, passed at two and did not route at the
third.

Judged as speed = Fmax x IPC, at each design's worst passing placement:

| Design | Worst passing Fmax | IPC | Fmax x IPC |
|---|---:|---:|---:|
| HEAD | 61.4 MHz | 0.272 | 16.7 |
| Two 8-entry stacks | 61.5 MHz (2 of 3 pass) | 0.320 | 19.7 (1.18x) |
| One 4-entry stack | 63.0 MHz (3 of 3 pass) | 0.320 | 20.2 (1.21x) |

## What changed

- **Straddling branches are installed.** A 32-bit instruction that starts in a
  word's upper half was never trained into the BTB. Its entry is now keyed on
  its second word, at slot 0, which is where fetch looks it up. Assembly takes
  the prediction from the second word.
- **Return address stack, compressed mode only.** Calls (jal/jalr with rd in
  {x1, x5}) push their link and returns (jalr x0 with rs1 in {x1, x5}) pop, as
  they leave A for F. The first version was 8 deep and restored from a second,
  in-order stack on every restart; the final one is 4 deep and restores only
  its pointer (see [Smaller stack](#smaller-stack)). Returns are no longer
  trained into the BTB.
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

## Smaller stack

The first version's 86% slice use made routing the risk. Most of its new
registers were the second, in-order stack, kept only to restore the first.

The replay model priced depth first (returns that still redirect, classifier):

| Depth | Return redirects |
|---:|---:|
| 8 | 38 |
| 4 | 4,687 |
| 3 | 61,251 |

The final version keeps one 4-entry stack. Execute keeps only the pointer
(`pRasResolvedTop`, moved by calls and returns as they leave E2), and a restart
resets the top to it. Entries are not restored, so a discarded return followed
by a discarded call overwrites a live entry; E2 then catches the wrong return.
On the classifier this never cost anything: the simulation shows 4,687 return
redirects, exactly the model's committed-order figure.

| Version | Cycles | Speedup | Logic | Registers | CLS (placement 0) |
|---|---:|---:|---:|---:|---:|
| HEAD | 145,460,221 | 1.000 | 14,304 | 5,308 | 82% |
| Two 8-entry stacks | 123,405,043 | 1.179 | 16,056 | 5,861 | 86% |
| One 4-entry stack | 123,432,187 | 1.178 | 14,835 | 5,475 | 85% |

| 60 MHz build | Placement 0 | Placement 2 | Placement 3 |
|---|---|---|---|
| One 4-entry stack | pass, 63.0 | pass, 75.5 | pass, 67.4 |

The new features now cost 531 LUTs and 167 registers over HEAD, against 1,752
and 553 for the first version.

## Open

- **Not run on the board.**
- A program with deeper recursion than 4 calls, or more wrong-path
  return-then-call sequences, would lose more than the classifier does.
- The larger BTB (64 entries) from STALL-SPLIT is the next predictor step; the
  area freed here leaves some room for it.

## Evidence

[evidence/2026-10-30-return-stack/](evidence/2026-10-30-return-stack/):
`results.json` and `run.log` (simulation, two 8-entry stacks), `ras4/` (simulation, one 4-entry stack), `timing-48mhz.txt`,
`timing-60mhz.txt`, the build scripts, `resources.txt`, and `rtl.sha256` for
the netlists built.
