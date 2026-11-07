# Aggregate area candidate: division-only and three DSP counters

Kind: candidate on branch `aggregate-area`, judged by area and census only,
2026-11-08. Baseline `dcd220d`. Step 3 of the revised method in
[ARCHITECTURAL-REFACTOR](2026-11-07-ARCHITECTURAL-REFACTOR.md); follows
[LOOP-CENSUS](2026-11-08-LOOP-CENSUS.md).

## Result

Division-only dispatch plus all three 64-bit counters (mcycle, mtime,
minstret) in `ALU54D` counters outside the core removes **454 LUT4
equivalents from the whole design (15,074 to 14,620, -3.0%)** and 100
registers, with every functional gate passing. That is a third of the
1,500 the method asks for before a candidate earns a routing distribution,
so this candidate is not routed as a distribution and is not proposed for
adoption. It is kept on its branch as the base for the rest of the area work.

Settling the CSR write value in the read phase, tried as the trap-register
and bus-response "mux work", moves logic rather than removing it (-48 whole
design, +209 on the register it settles into) and is not kept.

## What the candidate contains

- **Division-only service** (`divideOnlyStep` at the pipelined handler's
  call site): the iterative unit loses its shift-and-add multiply, which
  only the multi-cycle reference core can still reach.
- **External counters.** `SdramPipeline.circuitWith` takes an optional
  triple of `Counter64` signals; with them, `Machine`'s own copies are written
  back as constants (so synthesis removes them, and `HeldState`'s two counter
  halves with them) and the injected values take their place in `running`
  every cycle. The core exports `CounterCommands`: the registered CSR write
  for mcycle and minstret, minstret's retirement pulse and its load enable
  (not while held), and the CLINT write for mtime, which `Machine` now
  carries as `cpuTimeWrite`, set combinationally each step and never read
  back. `DspCountersTop.hs` is the top with those ports;
  `package_dsp_counters.py` wraps it in three `dsp_counter` instances
  (`dsp_counter.v`, the vendor-model-validated counter of
  [FOUR-REFACTOR-TRIALS](2026-11-08-FOUR-REFACTOR-TRIALS.md)) under the usual
  `sdram_pipeline_risc` name, and appends the Gowin simulation models to the
  observed copy only.
- `floorplan_cst.py` now finds the core module and its instance path in the
  netlist, so the same plan constrains `core/logic_core/...` under the
  wrapper.

The default top (`SdramPipeline.topEntity`) still keeps the counters inside
`Machine`; only the branch's call site change and the extra `cpuTimeWrite`
field reach it.

## Area

Whole-design synthesis, identical options (fprisc-81 settings, 81/48 MHz):

| | Baseline | Candidate | Change |
|---|---:|---:|---:|
| Logic (LUT + ALU + RAM16) | 15,074 | 14,620 | -454 (-3.0%) |
| of which LUT / ALU | 13,981 / 901 | 13,560 / 868 | -421 / -33 |
| Registers | 5,436 | 5,336 | -100 |
| ALU54D | 0 | 3 | +3 of 24 |
| Core module LUT4 equivalents (census) | 12,834 | 11,861 | -973 |
| Direct reset loads in the core | 3,723 | 3,527 | -196 |
| Largest clock-enable load | 487 | 486 | 0 |

The core-module census falls by more than the whole design because the
counters' high words and write muxes now live in the wrapper. By field:
`heldState` 458 to 13, `cpuMulDiv` 890 to 617, `cpuInstret` 199 to 0,
`cpuPendingWrite` 471 to 432, `request` 40 to 102 (the cache request slot
now also carries the counter commands' timing).

Register and enable fan-out are unchanged in shape: the hold enable still
drives 486 pins directly and the reset synchroniser 3,527, so the candidate
does nothing for the routing-bound paths the loop census identifies.

## Checks

| Check | Result |
|---|---|
| `cabal test` (82 properties, including the two division-only ones) | pass |
| Verilator cache/CDC guest on fresh observed RTL (timer interrupts, counters, Ctrl-C during a miss, three negative controls) | pass |
| Warm-reset equivalence against the baseline observed core | 20 warm resets, 7 while held, 493 commits and 130 stores match; the ignored-reset control is rejected |
| `dsp_counter` against the vendor `ALU54D` model | 10,015 checks pass |

The warm-reset bench matches cycle for cycle, which is the intended contract:
division latency, counter timing and CSR semantics are unchanged.

## One routing draw, recorded

For the record and not as a judgment: the candidate with its regenerated
floorplan at placement 3 reaches 69.778 MHz, -1.986 ns, 67 setup endpoints,
after 23 minutes of routing; occupied slices are 8,720 against the baseline's
8,717, so the 454 fewer LUTs freed no slices after packing. The loop census
of that route (`loop-census-p3.txt`) shows the same structures as the six
netlists in [LOOP-CENSUS](2026-11-08-LOOP-CENSUS.md) at the same depths; the
worst paths are routing. By the revised method this is one of fifteen draws
and the candidate did not qualify for the other fourteen.

## Where the rest of the area is

The census of the candidate, largest first: E2 1,464 (`e2Candidates` 806),
bus and devices 1,259 (`systemBus` 678, `cpuBusResponse` 311), CSR and traps
1,198 (`cpuTrapRegisters` 531), fetch 1,194 (the two pcs 780), assembly
1,074 (`pA` 763), the unnamed registers 991, E1 802, F 690, D 650, the
divide unit 617. To reach -1,500 the next pieces are the divide unit as a
narrower restoring divider (about 300 more), the bus response path (a
registered, narrower device read instead of a 20-way one-hot select of
32-bit words, about 250), and `e2Candidates` and `pA` on the pipeline side,
each of which needs its own pricing in simulation since they are on the
issue path.

## Evidence

[evidence/2026-11-08-aggregate-area/](evidence/2026-11-08-aggregate-area/):
`aggregate.patch` (the candidate against `dcd220d`), `synthesis-totals.json`,
`area-census*.txt/json` for baseline and candidate, `csr-settle/` (the
rejected variant's census), `rtl-check.txt`, `reset-check.json`,
`dsp-counter-model-test.log`, `haskell-tests.txt`, `floorplan.log`.
Build output under `output/tangnano20k/aggregate-20261108/`.
