# The aggregate area work on the IM core, and 87 MHz

Kind: branch `aggregate-im` (the `aggregate-area` source commit on top of
the RV32IM canon), measured by synthesis, functional gates and a placement
sweep at 84, 87 and 90 MHz, 2026-11-08. Follows
[FPRISC-84](2026-11-08-FPRISC-84.md) and
[AGGREGATE-AREA-CANDIDATE](2026-11-08-AGGREGATE-AREA-CANDIDATE.md).

## Result

The question was whether the aggregate's savings (division-only dispatch,
mcycle, mtime and minstret in `ALU54D` counters outside the core) would turn
87 MHz from two placements into four. They do not, and they cost 84 MHz its
robustness:

| CPU clock | IM canon: placements closing | IM + aggregate: placements closing |
|---:|---|---|
| 84 | **4 of 4** (+0.22 to +0.32 ns) | 2 of 4: placement 3 +0.12, placement 4 +0.08; placements 0 and 1 at 74.6 and 75.6 MHz |
| 87 | 2 of 4 (placements 1 and 3) | 2 of 4: placement 3 +0.17, placement 4 +0.33; placement 0 at 72.7 MHz, placement 1 -0.47 ns |
| 90 | 2 of 4 (placements 1 and 3) | 1 of 4: placement 4 +0.30 ns; placement 3 -0.25, placement 1 -1.09, placement 0 at 71.5 MHz |

Synthesis explains it. On the IMC core the aggregate removed 454 whole-design
logic units; on the IM core it removes none:

| | IM canon | IM + aggregate |
|---|---:|---:|
| Whole-design logic | 12,684 | 12,765 (+81) |
| Registers | 5,316 | 5,216 (-100) |
| ALU54D | 0 | 3 |
| Core module LUT4 equivalents | 10,547 | 10,048 (-499) |
| Occupied slices, placement 3 at 87 MHz | 8,053 (at 84) | 8,124 |

The core loses 499 (`heldState` 406 to 14, `cpuInstret` 179 to 0,
`cpuMulDiv` 807 to 606), the three `dsp_counter` wrappers put 481 back, and
sharing inside the core shifts by another 99: Gowin maps each counter's
32-bit high word and its write muxes to LUT5 pairs rather than a carry chain,
132 to 216 LUT4 equivalents per counter around one `ALU54D`
(`wrapper-cells.txt`). The DSP holds 33 bits of a 65-bit counter; the fabric
still holds the rest. On the IMC core the same wrappers cost the
same, but the core's own savings were larger (973) because its removed logic
had been shared with front-end structures that no longer exist.

Functionally the branch is sound on the IM core: 82 Haskell properties, the
Verilator cache/CDC guest and the warm-reset equivalence bench against the IM
observed core (20 resets, 485 commits, 127 stores, cycle-exact) all pass.

## Decision

Not adopted, and the branch should not be merged as it stands. The
division-only call site is still a correct simplification (-201 LUTs in the
divide unit) and can be taken on its own if wanted; the counters should not
be moved to DSPs in this form. A counter that pays would put all 64 bits in
DSP logic (two cascaded `ALU54D` per counter, six of the 22 idle macros) and
leave only the write command in fabric; that is a different experiment,
priced here as at most about 500 LUTs across the three counters.

The branch is kept for its tests and the `circuitWith` plumbing, which an
all-DSP counter would reuse.

## Evidence

[evidence/2026-11-08-aggregate-on-im/](evidence/2026-11-08-aggregate-on-im/):
`sweep.txt`, `synthesis-totals.json`, `area-census*.txt/json`,
`wrapper-cells.txt`, `functional-checks.txt`, `reset-check.json`,
`floorplan.log`. Builds under `output/tangnano20k/aggregate-im-20261108/`.
