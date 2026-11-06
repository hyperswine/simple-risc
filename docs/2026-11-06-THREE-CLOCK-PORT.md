# The three-clock cache port, adopted with a floorplan

Kind: core and cache change, build flow, timing build and board run,
2026-11-06. Applies to the commit that carries this page (on top of
d8b97dc). Follows [LOAD-USE](2026-11-05-LOAD-USE.md), which priced the change
as L2 and could not place it, and
[AREA-CENSUS-AND-FLOORPLAN](2026-11-06-AREA-CENSUS-AND-FLOORPLAN.md), whose
two-region floorplan closed it in place and route.

## Result

The cache's CPU port is three logical clocks again, and `fprisc-81` is built
with a floorplan generated from the pipeline's field names:

- **Timing:** the preset built from source closes **84.447 MHz, +0.504 ns**
  at the 81 MHz constraint (the four-clock canon: 82.651 MHz, +0.247 ns). It
  is the same result, to the last digit, as the place-and-route-only run on
  the 2026-11-05 netlist.
- **Board:** `check_processor.py`, `check_rv32m.py` (30,720) and
  `check_rv32i.py` (38,400) pass at 81 MHz, and the FP-RISC suite passes 7/7
  through the official runner.
- **Speed:** the 512/128 classifier, the same binary on both images, takes
  **6.799 s per run against 7.179 s: 1.056x**. From the 30.8 MIPS measured on
  the four-clock canon that is about 32.5 MIPS and IPC about 0.40.
- **Simulation:** the frozen 128/64 classifier at 48/48 takes 89,927,551
  cycles, exactly the figure priced for L2 (1.106x fewer than the four-clock
  core's 99,472,799, IPC 0.439), with the reference output. At the canon's
  own clocks, 81/48 through the bridge, it takes 106,126,406.

## What changed

- **Cache** (`pipeline_cache.v`): `cpu_rdata` is `cpu_word`, the word
  selected after the BSRAM read. The second register that repeated it
  (2026-10-29, [SDRAM-PIPELINE-FOUR-CYCLE-PORT](2026-10-29-SDRAM-PIPELINE-FOUR-CYCLE-PORT.md))
  is gone.
- **Core** (`SimpleRisc.hs`): `inflightArrival` is 2 for every memory, and a
  load waits two cycles in the commit stage instead of three. External and
  internal memory now have the same port timing; `pInflight` keeps its fourth
  entry, unread, so the `Pipe` layout is unchanged (synthesis removes it).
- **Preset** (`preset.sh`, `preset_manifest.py`): `fprisc-81` is placement 3
  with `SDRAM_FLOORPLAN=boards/tangnano20k/sdram/fprisc-81.plan`, and
  `fprisc-72` takes the same plan and placement (see
  [The other presets](#the-other-presets)). `fprisc-48` refuses a floorplan.
- **Build** (`build.sh`): with a floorplan, the Gowin script runs synthesis,
  then `floorplan_cst.py` on the synthesized netlist, appends the generated
  `GROUP`/`GRP_LOC` statements to `pins.cst`, then runs place and route. The
  constraints name registers by bit index, so they are regenerated on every
  build and never stored.
- **Manifest:** the configuration records `placement=3` and
  `floorplan='fprisc-81.plan'`; the hashed inputs now include the plan, the
  floorplan tools, `tools/PipelineLayout.hs` and the core's sub-modules
  (`src/SimpleRisc/*.hs` were missing since the 2026-10-29 module split);
  `pins.cst` is a hashed artifact.
- **FP-RISC** (`tools/run_tangnano20k_examples.py`): its copies of the
  `fprisc-72` and `fprisc-81` configurations match the new ones, or the
  runner refuses the manifest.

The plan:

```
free    ^pipeline
csr     R[2:9]C[2:55]     ^machine: csr, trap, counters
bus     R[38:53]C[2:19]   ^machine: bus and devices
```

437 CSR, trap and counter registers go to the top band and 284 bus and
device registers to the bottom-left corner; 159 more match but are left free
because they are one LUT cone from the pipeline.

## Checks

| Check | Result |
|---|---|
| `cabal test` | passes |
| `check_pipeline_cache.py` (bench at three clocks) | 18 pass |
| `check_cache_mru.py` | 5 pass |
| `check_clock_bridge.py` | 7 pass |
| `check_fence_assertion.py` | 3 pass |
| `formal/check_formal.py` and its gate tests | pass |
| loader, upload, preset, perf-guard and parser unit tests | pass (preset tests: 14, two new) |
| `check_pipeline_rtl.py` on fresh IMC and IM cores, Verilator: two-way guest at 7 and 11 line bits, `U` upload at one-way 12 and 7 line bits, zero-payload upload, raw readback | 12 of 12 pass |

The pipeline guest finishes sooner than on the four-clock port (706 us of
simulated time against 724 us), as it should.

The same checks under Icarus, which is what CI's `build` job runs for three
of them, did not finish inside the script's 240 s limit here. That is not
new: the job has failed on the last four pushes to `main`, since 2026-10-31,
and the latest log ends in the same `TimeoutExpired` on
`pipeline-rtl-w2-l7-iverilog`. It is left as it is in this change.

## Board

The image was loaded into FPGA SRAM (flash unchanged). Classifier, 512/128
rows, ten runs in one process, FP-RISC aee02d8, the same binary
(`879d96fb`, 74,932 bytes) on both images, the FPGA reprogrammed before
each:

| Image | Bitstream | Per run (last of ten) | Ten runs |
|---|---|---:|---|
| four-clock canon (187c637) | `3a57681a` | 7.179 s | 7.179 to 7.184 s |
| three-clock port with the floorplan | `e2419677` | 6.799 s | 6.799 to 6.802 s |

Both produce the reference result (481/512 and 116/128, digests 354774 and
434626). The board gain is smaller than the simulated one for the reason
[SHIFTS-IN-E1](2026-11-05-SHIFTS-IN-E1.md) gives: at CPU 81 / SDRAM 48
cache-miss holds are a larger share of the time than in the 48/48
simulation, so a cycle saved per load and per restart buys less.

The image is the committed tree's: build id `7823d65e96ccd595`. An earlier
build of the same core (`bcb98cb1`, before `fprisc-72` was given the
floorplan, which changes the preset files the build id covers) passed the
same checks and ran the classifier in the same 6.799 s; the four-clock row
was measured against that one.

`check_tangnano20k_dtree.py --bitstream` records the bitstream's hash and
does not program the FPGA. A first comparison run without reprogramming
gave the same time for both images; the table is from the repeat.

## What is fragile

- **Placement.** The floorplan passes at placement 3 (+0.504 ns) and
  placement 0 (+0.008 ns) and fails at 1 and 2 (78.8 MHz); without it the
  three-clock port reaches 61.9 to 69.6 MHz. One more pinned register breaks
  it. A core change can move this, as every change does on this chip; the
  area work ranked in
  [AREA-CENSUS-AND-FLOORPLAN](2026-11-06-AREA-CENSUS-AND-FLOORPLAN.md) is
  what gives it margin.
- **The plan's regions are sized for today's slow path.** If the CSR or bus
  logic grows past its region's slices the router stops converging (run f1
  there).

## The other presets

The cache and the core are shared, so `fprisc-48` and `fprisc-72` have the
three-clock port too. Neither was loaded on the board; these are timing
builds.

| Preset | Build | Result |
|---|---|---|
| `fprisc-48` (single clock, one-way cache) | unchanged: placement 2, no floorplan | 51.875 MHz, +1.556 ns |
| `fprisc-72` | its old shape: placement 0, no floorplan | does not route: 309 unrouted nets |
| `fprisc-72` | the plan, placement 0 | 72.037 MHz, +0.007 ns |
| `fprisc-72` | the plan, placement 3 | 74.935 MHz, +0.544 ns |
| `fprisc-72` | the preset as it now is (plan, placement 3), built from source | 74.935 MHz, +0.544 ns, manifest ready |

So `fprisc-72` now builds like `fprisc-81`: placement 3 with the plan. Its
four-clock image closed 74.6 MHz, +0.488 ns
([FPRISC-72-PRESET](2026-11-01-FPRISC-72-PRESET.md)).

## Evidence

[evidence/2026-11-06-three-clock-port/](evidence/2026-11-06-three-clock-port/):
`fprisc-81-build-manifest.json`, `timing.txt`, `floorplan.log`,
`rtl-checks.txt`, `processor-checks.txt`, `suite-results.json`,
`classifier-four-clock.json` and `classifier-three-clock.json` (the
same-binary pair), `fprisc-72-build-manifest.json` and the simulation
`results-*.json`.
