# Loop census: logic depth against routing on six netlists

Kind: measurement, 2026-11-08. Applies to the baseline `dcd220d` and the five
trial netlists of [ARCHITECTURAL-REFACTOR](2026-11-07-ARCHITECTURAL-REFACTOR.md),
[E1-PAYLOAD-RESET](2026-11-08-E1-PAYLOAD-RESET.md) and
[FOUR-REFACTOR-TRIALS](2026-11-08-FOUR-REFACTOR-TRIALS.md), re-routed at
placement 3 with their regenerated floorplans and a 3,000-path report. Step 2
of the revised method in the proposal.

## Result

Every re-route reproduces the trial's recorded Fmax to the last digit
(84.447, 80.043, 72.794, 75.231, 77.540 and 78.986 MHz), so a netlist maps to
one placement and the census compares like with like.

**The pipeline loops are shallow and routing-bound.** The limiting structures
run 7 to 9 logic levels at about 0.4 ns a level, 3 to 3.5 ns of cell delay in
a 12.3 ns period; their routing is 5.6 to 9.5 ns. Across the six netlists a
structure's depth hardly changes while its slack swings by 1 to 3 ns:

| Structure (max levels / worst slack, ns) | baseline | division-only | E1 reset | all reset | DSP counter | division service |
|---|---|---|---|---|---|---|
| BTB table to BTB table | 9 / 0.60 | 8 / 0.95 | 9 / -1.21 | 8 / -0.95 | 8 / -0.55 | 7 / 1.10 |
| fetch to fetch (queue read to instruction pc) | 9 / 0.90 | 9 / -0.15 | 9 / -1.01 | 9 / -0.71 | 9 / 0.97 | 9 / 0.48 |
| BTB table to fetch pc | 9 / 1.75 | 8 / 1.16 | 9 / 0.20 | 8 / 1.08 | 8 / 1.87 | 7 / 1.91 |
| fetch to assembly | 8 / 1.24 | 8 / -0.13 | 9 / -0.94 | 8 / -0.93 | 9 / 0.58 | 8 / 0.54 |
| assembly to fetch queue | 9 / 2.15 | 9 / -0.02 | 9 / -1.39 | 10 / 0.19 | 8 / -0.51 | 9 / 0.44 |
| E1 to E2 (candidates) | 11 / 2.49 | 9 / 1.09 | 10 / -1.37 | 10 / 1.62 | 9 / 0.13 | 10 / 1.16 |
| E1 to D blocked | 12 / 1.37 | - | - | 12 / -0.06 | - | - |
| M to D blocked | - | 8 / 0.85 | 10 / 0.13 | - | 9 / -0.41 | 9 / -0.32 |
| reset synchroniser to E1 enables | 4 / 0.50 | 4 / -0.11 | 4 / 0.10 | 4 / 1.18 | 4 / 3.28 | 4 / 4.03 |
| reset synchroniser to F enables | 4 / 0.86 | 4 / 0.18 | 4 / 0.46 | 4 / 4.09 | - | 4 / 2.96 |
| reset synchroniser to M enables | 4 / 2.14 | 4 / 0.96 | 4 / -1.21 | 4 / 1.15 | 4 / 3.11 | 4 / 4.35 |
| paths under 0.5 ns slack, of 3,000 | 0 | 185 | 299 | 64 | 13 | 4 |

(A dash means the structure is not among that report's 3,000 paths.)

Cell and routing delay, medians over each structure's paths in the baseline:

| Structure | Paths | Levels | Cell | Route | Cell per level |
|---|---:|---:|---:|---:|---:|
| BTB to BTB | 14 | 9 | 3.44 ns | 5.61 ns | 0.39 ns |
| fetch to fetch | 105 | 7 | 3.03 ns | 6.17 ns | 0.40 ns |
| BTB to fetch pc | 24 | 9 | 3.23 ns | 4.32 ns | 0.39 ns |
| fetch to assembly | 29 | 8 | 3.31 ns | 6.39 ns | 0.41 ns |
| assembly to fetch queue | 76 | 9 | 3.55 ns | 5.65 ns | 0.41 ns |
| E1 to E2 | 13 | 8 | 3.45 ns | 5.41 ns | 0.41 ns |
| E1 to D blocked | 1 | 12 | 5.26 ns | 5.45 ns | 0.44 ns |
| reset to E1 enables | 301 | 4 | 1.78 ns | 7.24 ns | 0.45 ns |
| reset to F enables | 256 | 4 | 1.78 ns | 9.43 ns | 0.45 ns |

The other five netlists give the same cell figures within 0.3 ns and the
same per-level cost; only the routing column moves (`cross-table.txt`).

## What this says

- **Depth is not the lever I suggested in the review.** A loop cut from nine
  levels to five saves about 1.6 ns of cell delay, the size of the routing
  swing the same loop shows between two netlists of near-identical logic.
  Depth cuts are placement-insensitive, as claimed, but small; they would
  matter at 100 MHz, not at 81.
- **Routing length is the limiter**, and it is set by where the placer puts
  each structure relative to its block RAM and to the rest of the pipeline.
  The fetch loop closes through the BTB block RAMs (R28[13] and R10[15] in
  the canon), whose sites are fixed by the placer; the F queue and the
  assembly stage follow. Two placements of the same netlist put 1 to 3 ns
  more wire on these paths.
- **The reset-to-enable paths are the same shape**: 1.8 ns of cell delay and
  7 to 9 ns of wire from one synchroniser flop to several hundred enable
  pins across the die. They fail or pass by routing alone.
- **The six netlists are the same design for timing purposes.** Their loop
  depths differ by at most two levels and their cell delays by 0.3 ns; the
  recorded 72.8 to 84.4 MHz spread is routing, consistent with
  [THREE-CLOCK-PORT](2026-11-06-THREE-CLOCK-PORT.md)'s spread across
  placements of one netlist.

So the question for every candidate is wire length, measured as a
distribution, not Fmax from one placement, and the levers are the ones that
shorten wire: fewer cells competing for the centre (area), block RAM sites
pinned next to the logic that loops through them (the BTB RAMs first),
coherent regions for the front end, and a duplicated reset synchroniser so no
enable pin is 9 ns from its source. These are what the aggregate candidate
and the next floorplan should be judged on.

## Tools

`loop_census.py REPORT.tr ... --layout layout.json` groups a long report by
structure and prints paths, failures, worst slack, median and maximum levels
and median routing share, marking loops; `--json` keeps it all.
`pnr_only.sh` with `PNR_REPORT_PATHS=3000` produces the report from an
existing netlist.

## Evidence

[evidence/2026-11-08-loop-census/](evidence/2026-11-08-loop-census/):
`routes.txt` (the six re-routes), `loop-census.txt` and `.json` (every
structure per report), `cross-table.txt` (the two tables above for all six
netlists). The 3,000-path reports stay under
`output/tangnano20k/loop-census-20261108/`.
