# E1 payload reset removal

Kind: bounded RTL experiment and physical comparison, 2026-11-08.
Baseline: `dcd220d`, with the passing three-clock cache port and its generated
floorplan. Follows [ARCHITECTURAL-REFACTOR](2026-11-07-ARCHITECTURAL-REFACTOR.md).

## Change and hypothesis

Only the SDRAM wrapper's `stageE1` changes from `regEn` to `delayEn`.
`delayEn` has a clock and enable but no reset input. It retains the existing
initial value and hold enable. `Pipe` still owns and resets the E1 validity
bit; an invalid payload is not an instruction. The division-only activation
remains deferred, so this experiment isolates reset removal on the passing
pipeline configuration.

The hypothesis is that removing E1 payload reset reduces reset fanout and
reset-to-enable paths without adding stage-advance logic to the global hold
cone. Check actual netlist and routing, rather than assuming the primitive
change guarantees this: next-state logic can reintroduce reset dependencies.

## Functional checks

The Haskell suite checks architecture but does not alone verify the changed
physical register. Fresh generated RTL is therefore checked with both:

- The existing executing guest with the two-way 64 KiB cache and CDC bridge,
  including timer interrupts, precise traps, masked stores, FENCE.I and Ctrl-C
  during a miss, plus corruption and duplicate/cancelled-store controls.
- A new baseline/candidate observed-core comparison through repeated warm
  resets and pseudo-random memory holds. A shared two-stage memory model plus
  the core's request register supplies arithmetic, multiply, divide, load,
  store and branch instructions. Compare valid retirements, fetches, stores
  and peripheral outputs. Vary reset spacing and pulse width and require
  execution between resets. A negative control ignores candidate warm resets
  and must diverge after the first warm reset.

This comparison verifies equivalence to the baseline for the exercised traces;
it is not a replacement for independent ISA tests or a formal proof. Physical
measurements use the production top, never the observed top.

## Physical controls

Use the preceding experiment's frozen baseline netlist and its reproduced
placement-3 and placement-0 results (84.447 and 81.055 MHz). Verify saved hashes
before reuse. CPU/cache 81 MHz, SDRAM 48 MHz, phase 135 degrees, two-way 64 KiB
cache, target 89 MHz, map 3, route 1, route fanout 8. Keep stamped ROM bytes
identical and generate the floorplan from each netlist's field metadata.

Measure core LUT equivalents, whole-design resources, occupied slices,
reset and CE pin loads, resettable/unreset flop counts, setup/hold endpoints,
worst-path structure, routing share and congestion. Report both placements,
including failures. The default timing report supplies 25 setup paths; scope
path-share statistics to that sample. Direct core fanout counts and the vendor
whole-design routed-net report have different scopes.

No experiment bitstream is a release: its ROM identity is deliberately fixed
for comparison. Board qualification and a normal correctly stamped preset
build are separate adoption gates.

## Results

Functional results: all 82 Haskell properties pass; the cache/CDC guest and
its three negative controls pass. The new equivalence test completes 20 warm
resets (seven asserted while held), with 569 matching retirements and 68 stores.
Ignoring candidate warm resets is rejected at epoch 1. Cabal's suite reports
PASS before its global cache-log append is denied by the sandbox.

Fresh baseline production RTL is byte-identical to the frozen baseline RTL;
saved baseline netlist, RTL and ROM hashes also verify.

| Synthesis metric | Baseline | E1 unreset payload |
|---|---:|---:|
| Core LUT4 equivalents | 12,834 | 12,890 |
| Whole-design logic usage | 15,074 | 15,137 |
| Registers | 5,436 | 5,436 |
| Direct reset input loads in core | 3,849 | 3,540 |
| E1 payload direct global-reset loads | 309 | 0 |
| E1 validity direct global-reset loads | 1 | 1 |
| Largest direct CE-pin load in core | 487 | 487 |
| `cpuFast` direct input loads | 863 | 908 |

The 8% drop in direct core reset fanout is real, but area is slightly higher.
Of the 309 payload flops, 286 become DFFE; the others retain reset-capable
cells whose reset inputs implement local logic or constants. These are not
global reset connections. Netlist attribution counts validity together with
payload, so the E1 group has 310 registers.

Logs and the exact candidate patch are saved under
[evidence/2026-11-08-e1-reset/](evidence/2026-11-08-e1-reset/).


A second control regenerates the current working tree with only E1 reset
restored. It is identical to the frozen production RTL after removing source-
location comments (the unused division helper shifts source line numbers).
`control-verification.json` records raw and normalized hashes. No logic or
signal naming changes come from retaining that helper.


## Routing result and decision

| Placement | Baseline Fmax / slack | E1 unreset Fmax / slack | Candidate setup violations |
|---|---|---|---:|
| 3 | 84.447 MHz / +0.504 ns | 72.794 MHz / -1.392 ns | 104 |
| 0 | 81.055 MHz / +0.008 ns | 78.219 MHz / -0.439 ns | 34 |

Both candidates fully route and have zero hold violations, but neither closes
81 MHz. At placement 3 occupied CLS increases from 8,717 to 8,730; at placement
0 it increases from 8,687 to 8,822. Whole-design routed logic usage rises from
15,170 to 15,233. Peak reported congestion at placement 3 rises from 0.917 to
0.944; average routing share among the 25 reported setup paths rises from
79.9% to 82.3%. These samples contain different worst endpoints.

At placement 3 the E1 enable net has +0.105 ns worst slack, but other paths
fail: assembly to fetch queue (-1.392 ns), E1 to E2 arithmetic (-1.368 ns),
reset to M enable (-1.214 ns), and the BTB loop (-1.213 ns). Twenty of the 25
reported setup paths are now reset to M enable. The global reset connection
to E1 payload was removed as intended, but the remaining global control and
placement interactions dominate the resulting design. At placement 0 the
worst paths are fetch to assembly, assembly to fetch queue and fetch control.

**Do not adopt this isolated change.** The experiment establishes functional
safety for the tested traces and a direct reset-fanout improvement, but a timing
regression at both matched placements. Restore `stageE1=regEn` in the default
source. Retain the exact `delayEn` patch and the reusable warm-reset comparison
for subsequent work. No preset or canonical bitstream changes.

The next hypothesis should address a coherent set of payload/control boundaries
and the residual M/reset and front-end loops, rather than assuming that each
independent reset removal improves timing. A combined D/E1/E2/M payload trial
could test that hypothesis, but is not implemented or claimed here. Treat
floorplan/packing as part of each experiment and retain these negative results.

Both physical runs completed: about 847 seconds at placement 3 and 406 seconds
at placement 0, including licence/report overhead and overlapping work. These
are not controlled speed measurements. Placements 1, 2 and 4 were not tested.
All functional checks above apply to the candidate before default restoration;
the baseline was the other side of the warm-reset equivalence test.
