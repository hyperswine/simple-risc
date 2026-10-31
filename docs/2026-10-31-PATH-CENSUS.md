# Path census: what fails between 72 and 96 MHz

Kind: timing measurement, 2026-10-31. Item 1 of
[FREQUENCY-STRUCTURE-PLAN](2026-10-31-FREQUENCY-STRUCTURE-PLAN.md). Design:
HEAD 9fe276d (4-entry return stack, 128-entry BTB). No change to the core.

## Result

With the core on its own clock (SDRAM at 48 MHz behind the bridge), the
design passes at 72 MHz (72.25 MHz, 0.048 ns spare) and fails at 96 MHz
(75.4 MHz, 1,176 failing endpoints).

**The 75-78 MHz wall is six independent structures, not one loop.** Their
worst paths lie within 0.4 ns of each other, so fixing any one alone moves
Fmax by under 1 MHz. Two of the six are not pipeline logic at all: they are
control signals with very large fan-out.

| Cause | Fails at 96 | at 84 | Worst slack | Its own limit |
|---|---:|---:|---:|---:|
| Front end (fetch, BTB, A, F) | 124 | 27 | -2.849 | 75.4 MHz |
| Decode and execute | 18 | 5 | -2.818 | 75.6 MHz |
| `cpuFast`, the pipeline/multi-cycle select | 267 | 186 | -2.791 | 75.7 MHz |
| Cache hold enable through `cpuInRom` | 638 | 94 | -2.695 | 76.3 MHz |
| Multiplier into M | 23 | 2 | -2.487 | 77.5 MHz |
| Cache read and way select | 40 | 7 | -2.433 | 77.8 MHz |
| Other machine state (phase, interrupt, mul/div) | 59 | 4 | -1.536 | 83.7 MHz |

Removing causes in that order (an estimate from the same placement; it ignores
re-placement and the relief from less congestion) gives 75.6, 75.7, 76.3,
77.5, 77.8, then **83.7 MHz** once the cache is fixed, and about 108 MHz once
the machine state is fixed. The report lists paths only down to 1.41 ns of
slack, so 108 MHz is the edge of what it covers, not a measured ceiling.

## The structures

- **Hold enable (638 endpoints, 54% of all failures).** `holding = memoryHeld
  && not breaking`, and `breaking` (Ctrl-C) reads `cpuInRom`. From that
  register the enable goes through three LUTs with fan-outs of 277, 287 and
  549 to the clock enables of the stage payload registers; the last net alone
  is 4.6 ns. This is feed-forward from registers: computing "break allowed"
  a cycle early leaves `holding` a two-input function. No IPC cost.
- **`cpuFast` (267 paths: 155 clock enables, 112 data).** Every next-state bit
  of the machine (about 12,000) selects between the pipeline's result and the
  multi-cycle phase machine's (traps, CSRs, `mret`, WFI, bus waits). The
  select drives about 1,000 loads, and its paths are 81-85% routing. It also
  steers "keep the old value" enables of the front-end registers (for
  example `pBtbWrite`, `pFrontTarget`) through 120- and 82-load nets. No IPC
  cost to restructure.
- **Front end (124).** The worst is E2's BTB training into `pBtbWrite` (10
  levels), then the queue read pointer through assembly into `pInstructionPc`,
  `pA` and `pFQueue` (9 levels), and the BTB loop to the fetch pc (12
  levels). The BTB loop is a true loop: shortening it costs IPC.
- **Decode and execute (18).** D's pc to E1's fetch fault, E1's operand to
  E2's action (11 levels), E2 to `pRedirect`.
- **Multiplier (23).** Three DSP blocks in a chain with 4.9, 2.6 and 3.2 ns of
  routing between them, into M's value. The multiply already waits in M, so a
  register between the DSPs costs no IPC.
- **Cache (40).** Block-RAM read (2.26 ns clock-to-out), then four LUT levels
  of way select into the CPU word.

High fan-out nets that appear on failing paths: `cpuFast` (999 and 998 loads,
replicated), E2's `ds5_797` (549), `advance` (343), E1's `ds4_173` (310), and
the hold-enable intermediates (277, 287). Routing is 65-89% of every failing
path; the most congested routing cells are at 0.89-0.93.

## What-if: the two control fan-outs removed (item 2)

The same 96 MHz build with every path from `cpuInRom` and `cpuFast` marked
false (`cut-control.sdc`), standing in for fixing both:

| Build at 96 MHz | Fmax | Failing endpoints | Failing at 84 MHz |
|---|---:|---:|---:|
| As is | 75.4 MHz | 1,176 | 324 |
| Control fan-outs cut | 79.7 MHz | 220 | 10 |

The no-re-placement estimate said these two alone were worth almost nothing,
because the other structures sit right behind them. The real build gained
4.3 MHz: without those nets to serve, the placer made everything else
faster. The estimate is a floor, not a forecast.

What remains, from the cut build:

| Cause | Fails at 96 | at 84 | Worst slack | Its own limit |
|---|---:|---:|---:|---:|
| Front end (fetch, BTB, A, F) | 94 | 4 | -2.123 | 79.7 MHz |
| Other machine state (phase, interrupt, mul/div) | 10 | 1 | -2.110 | 79.8 MHz |
| Decode and execute | 18 | 3 | -2.059 | 80.2 MHz |
| Multiplier into M | 12 | 1 | -1.894 | 81.2 MHz |
| Cache read and way select | 84 | 1 | -1.627 | 83.0 MHz |

Beyond those the next reported path is at 106.7 MHz (M into the machine
register). The worst individual paths are E2's BTB training write
(`pBtbWrite`, 10 levels), machine-state updates, E2 to `pRedirect`, E1 to E2's
action, the multiplier, and the queue read pointer through assembly.

## What this changes

The predictor work moved the critical path around inside the front end, but
at 96 MHz the front end is one of six equal problems. The cheapest steps
toward 84 MHz are the two control-signal fan-outs (hold enable and
`cpuFast`), the multiplier register and the cache way select: none of them
costs IPC. The front-end and execute loops come after, and need item 4's IPC
prices.

## Tooling

- `build.sh`: `SDRAM_REPORT_PATHS=N` adds `report_timing -setup -max_paths N
  -max_common_paths 1` and larger fan-out and congestion tables to the SDC.
  (`-num_critical_paths`, now `SDRAM_CRITICAL_PATHS`, does not raise the
  detailed report's 25-path limit.)
- `path_census.py`: maps every setup path's start and end registers to
  pipeline fields with `pipeline-layout`, and groups by structure, end field,
  start field and clock. Marks clock-enable endpoints "(CE)": synthesis turns
  both the cache hold and "keep the old value" registers into enables.
- `census_causes.py`: the root-cause table and removal estimate above.

## Next

- Make the two control fan-out fixes for real (break allowed computed a cycle
  early; the pipeline registers no longer muxed by `cpuFast`) and check they
  match the what-if build.
- Item 4: price an extra cycle in the BTB loop, the redirect path and E1-E2.

## Evidence

[evidence/2026-10-31-path-census/](evidence/2026-10-31-path-census/):
`summary.txt` (72 and 96 MHz builds), `cpu96-census.txt` and `.json` (all
3,000 paths), `cpu96-causes.txt`, the what-if build's `cpu96-cutcontrol-*` and
`cut-control.sdc`, `layout.json`, `census.sh`,
`inputs.sha256`.
