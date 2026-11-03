# E2->D forwarding: design, verification, and the thin-margin question

Kind: experiment record, 2026-11-02. Applies to: the working tree's
`e2Value`/`e2Forwards` change (see diff of `src/SimpleRisc.hs`,
`src/SimpleRisc/Decode.hs`, `test/SimpleRisc.hs`).
Follows: [NEXT-STEPS](2026-11-02-NEXT-STEPS.md) item 2,
[LOOP-PRICING-AND-80MHZ-FIXES](2026-11-01-LOOP-PRICING-AND-80MHZ-FIXES.md)
(`e2_forward`: -7.3% window cycles).

## Design

E2 results whose value is ready forward straight to decode's operand mux:

- `e2Value :: ExecuteTwo -> Word32` (new, `src/SimpleRisc.hs`) computes a
  jump's link, LUI, AUIPC or the selected ALU output from E2's registered
  payload. Both the E2->M edge and the D mux take it from here (the edge
  previously inlined the identical expression).
- `e2Forwards` (an existing, always-`False` bit) is now set at the E1->E2
  edge: writes-rd, `Plain` action, and not a load, shift or multiply.
  Illegal encodings, fetch faults, misaligned jumps, CSRs, divides and
  handovers all take non-`Plain` actions or don't write, so they never
  forward; E2-computed `Raise` (taken-branch misalignment) only affects
  non-writing branches.
- `decodeHazard` no longer stalls on a forwarding E2 producer; the D mux
  tries E2 (youngest) before M, pending writeback and the register file.
- Safety under flush is the pre-existing discipline: `restartPipe`
  cancels D/E1/E2/M together, so a consumer that took a forwarded value
  is discarded with its producer on any handover or redirect.

## Verification (sim)

- New maintained test `prop_pipelined_e2_forwards_chained_alu`: ten
  chained ALU/LUI/AUIPC dependents check exact results and pin 29 cycles
  (36 before; the 7 saved stalls are exactly the chained pairs), plus a
  load-use program pinning exact results and an unchanged 19 cycles.
  Proven failing pre-change (36) via stash; green post-change.
- Full Haskell suite: 71 + 8 pass, including the 300-program pipeline
  differential and the hazard-consistency property (which follows the
  changed function).
- Verilator `check_pipeline_rtl.py --compressed`: green, after fixing a
  real testbench race the faster CPU exposed (the Ctrl-C break trigger
  gated on STATUS landing in tb RAM; a first-touch trigger on the two
  spin lines replaces it; see `pipeline_cpu_tb.v` comment). HEAD
  baseline passes the same check.

## Timing: harder to place

The E2D netlist routes slower and closes worse than the pre-E2D one.
CPU81/SDRAM48, fprisc-81-equivalent options
(`evidence/2026-11-02-e2d/`):

| placement | Fmax | worst setup slack | violations |
|---|---:|---:|---:|
| 0 | 78.307 | -0.425 | 71 |
| 1 | 81.133 | +0.020 | 0 |
| 2 | 81.133 | +0.020 | 0 |
| 3 | (preset dir) 78.572 | -0.381 | 4 |
| 3/4 (sweep) | pending | | license server unreachable |

The preset-place3 failures are the new L5 shapes: E2 candidates ->
forward select -> E1 op2 (-0.359), hazard check -> `pDBlocked`
(-0.381, route-dominated with one 4.4 ns net), forward -> held
operands (-0.060), plus fetch->A knock-on (-0.050). Place1/2 pass with
the limiter moved to **cache->cache** (+0.020, tag RAM -> word select),
a structure E2D does not touch: congestion displaced cache routing.

## Board: open margin question

On place1 (+0.020 ns): `check_processor.py` 3/4 (one post-load glitch),
`check_rv32m.py` 30,720, `check_rv32i.py` 38,400 and FP-RISC `hello`
pass; the classifier and larger cases halt silently with no output
while the same binaries pass on the pre-E2D image (classifier control:
PASS). The M/I suites and sim evidence say the forwarding logic is
right; the workload correlation (small/low-pressure passes,
cache-heavy fails) plus the +0.020 ns cache limiter point at **timing
margin under real switching activity**, but the decisive test (another
E2D placement on the board) is queued behind access: serial/JTAG and
the license server all became unreachable mid-session.

## Next

1. Restore access; load place2 (same RTL, +0.020 ns) and run the
   classifier twice plus numeric *with* the suite's `--input/--env`
   (the hand-runs omitted them, which alone explains those failures).
2. Finish place3/4; if a fatter pass appears, re-point the preset at
   the winner, rebuild, and re-run everything including the FP-RISC
   suite for the classifier cycle saving.
3. If no placement gives margin, trim RTL: the catalogued options are
   selecting E2's ALU result at the E1->E2 edge into a registered
   `e2Selected` (shortening E2->D at the cost of the E1->E2 edge), or
   floorplanning cache vs core apart.

## Board result (2026-11-04): passes; preset moved to placement 1

The full working tree (E2->D forwarding, the flattened cache way select,
the D.fPc cut, the pipelined multiply and the bridge multicycle
constraints) works on the board at CPU 81 / SDRAM 48 MHz.

| Build (CPU 81 unless noted) | Fmax | Worst setup slack |
|---|---:|---:|
| placement 3 (the old preset setting) | 70.927 MHz | -1.753 ns, 33 endpoints, all front end (queue read -> assembly -> `pInstructionPc`/`pA`/`pFQueue`, 73-77% routing) |
| placements 1 and 2 (identical) | 81.238 MHz | +0.036 ns |
| CPU 72 with the fprisc-72 settings | 73.085 MHz | +0.206 ns (0.488 before E2D) |

Before the board: Haskell suite 71 + 8, Verilator
`check_pipeline_rtl.py --compressed`, `check_pipeline_cache.py` (18 cases)
and `check_cache_mru.py` all pass.

On the placement-1 image: `check_processor.py`, `check_rv32m.py` (30,720)
and `check_rv32i.py` (38,400) pass at 81 MHz, and so does the whole FP-RISC
suite (7/7), first through a hand driver and then through the official
runner on the rebuilt `fprisc-81` preset (now placement 1). The classifier
and larger cases that halted on the earlier E2D image all pass; every
classifier run matches the reference.

Same classifier binary (`93e027cc347b`, ten runs each):

| Image | Per run |
|---|---:|
| pre-E2D, `cpu81-mulpipe` | 7.680 s |
| E2D, `fprisc-81` placement 1 | 7.338 s (-4.5%) |

Simulation predicted -7.3% window cycles; the board run includes setup and
heap work outside that window.

The margin is the open item: 0.036 ns, and this flow has already missed one
real board failure (the multiplier, see CPU81-TIMING). Items 2-3 of Next
above (a fatter placement, or trimming the E2->D select) remain the way to
earn margin. Evidence: [evidence/2026-11-04-e2d-board/](evidence/2026-11-04-e2d-board/).
