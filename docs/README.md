# docs/: a chronological record

Kind: index. Every document in this directory is named
`YYYY-MM-DD-NAME.md`, dated by the day it was first written, so a listing of
the directory is the timeline of the project's thinking. Older and newer pages
are not reconciled with each other: a page says what was true or intended when
it was written, and a later page may supersede it without the earlier one
being rewritten. When two pages disagree, the later date wins.

Raw board logs, manifests and hashes that a page cites live under
`evidence/`, in a directory named after the page's date and topic.

Component guides stay beside the code they describe: the repository
[README](../README.md) and the [Tang Nano 20K build guide](../boards/tangnano20k/README.md)
with its [SDRAM](../boards/tangnano20k/sdram/README.md) and
[RV64](../boards/tangnano20k/rv64/README.md) notes.

## Adding a page

Name it with today's date, add one line to the end of the list below, and say
near the top what kind of page it is and what state of the code it applies to.
Do not rename a page when it changes: its date is when it began, and the record
of what changed goes in dated sections inside it. Do not fold an older page
into a newer one to make them agree; write the newer one and point back.

Pages written before 2026-10-21 came from HaskPlayground, where they moved into docs/ on 2026-10-20; they keep the date already in their name, or else the date of their first commit.

## The record, oldest first

| date | page | what it is |
|---|---|---|
| 2026-10-05 | [SIMPLE-RISC-ROADMAP](2026-10-05-SIMPLE-RISC-ROADMAP.md) | SimpleRisc roadmap from tested RV32IM to a real RISC-V core, with progress against each step |
| 2026-10-05 | [TANGNANO20K-CLOCK-SWEEP](2026-10-05-TANGNANO20K-CLOCK-SWEEP.md) | clock sweep on the board: 114 MHz passes with the registered two-stage shifter |
| 2026-10-05 | [TANGNANO20K-MACHINE-MODE](2026-10-05-TANGNANO20K-MACHINE-MODE.md) | roadmap step 1: precise exception entry, CSRs and trap return |
| 2026-10-05 | [TANGNANO20K-SYSTEM-BUS](2026-10-05-TANGNANO20K-SYSTEM-BUS.md) | system separation, first slice: an explicit exit device |
| 2026-10-06 | [TANGNANO20K-EXECUTE-TIMING](2026-10-06-TANGNANO20K-EXECUTE-TIMING.md) | registered execution experiment: 108 MHz vendor timing with one extra instruction clock |
| 2026-10-06 | [TANGNANO20K-GOWIN-TIMING](2026-10-06-TANGNANO20K-GOWIN-TIMING.md) | Gowin vendor timing baseline for the registered-data-bus core |
| 2026-10-11 | [TANGNANO20K-BOOT-ROM](2026-10-11-TANGNANO20K-BOOT-ROM.md) | roadmap step 3: boot ROM, RAM at `0x8000_0000` |
| 2026-10-11 | [TANGNANO20K-INTERRUPTS](2026-10-11-TANGNANO20K-INTERRUPTS.md) | roadmap step 2: CLINT, minimal PLIC, machine interrupts, WFI |
| 2026-10-11 | [TANGNANO20K-SD-PPP](2026-10-11-TANGNANO20K-SD-PPP.md) | microSD and PPP over the USB UART on the 96 MHz BRAM image |
| 2026-10-12 | [TANGNANO20K-BRANCH-TARGET](2026-10-12-TANGNANO20K-BRANCH-TARGET.md) | branch-target prefetch at ExecuteFinish |
| 2026-10-12 | [TANGNANO20K-DECODE-AHEAD](2026-10-12-TANGNANO20K-DECODE-AHEAD.md) | decode-ahead: the first overlap of two instructions' stages (`pipeline` branch) |
| 2026-10-12 | [TANGNANO20K-FAST-MEMORY](2026-10-12-TANGNANO20K-FAST-MEMORY.md) | the block-RAM load/store fast path |
| 2026-10-12 | [TANGNANO20K-FETCH-OVERLAP](2026-10-12-TANGNANO20K-FETCH-OVERLAP.md) | fetch overlap: prefetching pc + 4 while the RAM port is idle |
| 2026-10-12 | [TANGNANO20K-IO-COMPLEX](2026-10-12-TANGNANO20K-IO-COMPLEX.md) | the I/O complex: UART FIFOs, an I/O port and SPI DMA |
| 2026-10-12 | [TANGNANO20K-MEMORY-PORT](2026-10-12-TANGNANO20K-MEMORY-PORT.md) | the memory port driven from registers: 99 to 117 MHz (`memport` branch) |
| 2026-10-12 | [TANGNANO20K-PIPELINE](2026-10-12-TANGNANO20K-PIPELINE.md) | a real pipeline, first version (`real-pipeline` branch) |
| 2026-10-12 | [TANGNANO20K-REFERENCE-MODEL](2026-10-12-TANGNANO20K-REFERENCE-MODEL.md) | the RV32IM + Zicsr reference model for differential testing |
| 2026-10-12 | [TANGNANO20K-REGFILE](2026-10-12-TANGNANO20K-REGFILE.md) | the register file in RAM, and `main` at 93 MHz |
| 2026-10-12 | [TANGNANO20K-STAGES](2026-10-12-TANGNANO20K-STAGES.md) | stage registers, step 1: decoded control travels with the instruction (`stages` branch) |
| 2026-10-16 | [TANGNANO20K-SDRAM-PIPELINE](2026-10-16-TANGNANO20K-SDRAM-PIPELINE.md) | the pipelined RV32 core over all 8 MiB of SDRAM through a fixed-latency cache port |
| 2026-10-18 | [TANGNANO20K-BASE-LOADER](2026-10-18-TANGNANO20K-BASE-LOADER.md) | the RV32 SDRAM ROM accepts the FP-RISC Base uploader protocol |
| 2026-10-18 | [TANGNANO20K-SDRAM-CLOCKS](2026-10-18-TANGNANO20K-SDRAM-CLOCKS.md) | split CPU/SDRAM clock experiment: 72 MHz CPU over 54 MHz SDRAM |
| 2026-10-18 | [TANGNANO20K-SDRAM-IO](2026-10-18-TANGNANO20K-SDRAM-IO.md) | SDRAM I/O timing model audit: the QN88 profile is incomplete |
| 2026-10-18 | [TANGNANO20K-SDRAM-IO-VENDOR-REQUEST](2026-10-18-TANGNANO20K-SDRAM-IO-VENDOR-REQUEST.md) | the support request sent to Gowin for the missing SDRAM AC timing |
| 2026-10-18 | [TANGNANO20K-SDRAM-PHASE-SWEEP](2026-10-18-TANGNANO20K-SDRAM-PHASE-SWEEP.md) | physical phase sweep at 54 MHz: four passing PLL steps |
| 2026-10-18 | [TANGNANO20K-SDRAM-SD-SPI](2026-10-18-TANGNANO20K-SDRAM-SD-SPI.md) | the microSD SPI byte port on the SDRAM pipeline |
| 2026-10-19 | [TANGNANO20K-ARCH-TESTS](2026-10-19-TANGNANO20K-ARCH-TESTS.md) | roadmap step 4: riscv-arch-test under RISCOF against Spike |
| 2026-10-19 | [TANGNANO20K-INTEGRATION](2026-10-19-TANGNANO20K-INTEGRATION.md) | branch integration, timing and regressions at CPU72/SDRAM54 MHz; evidence in `evidence/2026-10-19-integration/` |
| 2026-10-19 | [TANGNANO20K-SDRAM-CACHE](2026-10-19-TANGNANO20K-SDRAM-CACHE.md) | the 64 KiB cache and asynchronous-FIFO clock bridge: classifier 2.33 times faster |
| 2026-10-19 | [TANGNANO20K-SDRAM-WRITE-UPDATE](2026-10-19-TANGNANO20K-SDRAM-WRITE-UPDATE.md) | write-update on the board: narrow BSRAM slices; evidence in `evidence/2026-10-19-bsram-rdw/` and `evidence/2026-10-19-write-update-board/` |
| 2026-10-21 | [FPRISC-48-PRESET](2026-10-21-FPRISC-48-PRESET.md) | fixed 48 MHz development preset, fresh Gowin timing and full physical FP-RISC example suite |
| 2026-10-25 | [FPRISC-BOARD-DEPENDABILITY](2026-10-25-FPRISC-BOARD-DEPENDABILITY.md) | priorities and acceptance criteria for board identification, reliable uploads, crash reports, endurance and reproducible releases |
| 2026-10-28 | [FORMAL-CACHE-CONTRACTS](2026-10-28-FORMAL-CACHE-CONTRACTS.md) | refill progress, three-tag eviction coverage, per-search formal gates and RTL CI checks |
| 2026-10-28 | [CONTROLLED-BENCHMARK](2026-10-28-CONTROLLED-BENCHMARK.md) | fixed-binary eight-case predictor/cache/bridge matrix, six 48 MHz board runs and replayable evidence |
| 2026-10-28 | [CONTROL-FANOUT-AND-AREA](2026-10-28-CONTROL-FANOUT-AND-AREA.md) | control-net source tracing and RAM-backed cache replacement state: 18.79% fewer logic cells with identical classifier cycles |
| 2026-10-28 | [INDEPENDENT-TIMING-REVIEW](2026-10-28-INDEPENDENT-TIMING-REVIEW.md) | second reading of the committed timing reports: routing-dominated stage-select and DSP-input paths, ranked fixes, what is unverified |
| 2026-10-28 | [ROM-IDENTITY-AND-VERIFIED-UPLOAD](2026-10-28-ROM-IDENTITY-AND-VERIFIED-UPLOAD.md) | the boot ROM's `I`/`U`/`C`/`G` identity and CRC32 upload protocol, what `id=` does and does not identify, and why `U` is still unqualified on hardware |
| 2026-10-29 | [SDRAM-PIPELINE-FOUR-CYCLE-PORT](2026-10-29-SDRAM-PIPELINE-FOUR-CYCLE-PORT.md) | a register after the cache's BSRAM read, so external-memory images get a four-logical-clock port; placement-target, region-constraint and placement-sweep build knobs |
| 2026-10-29 | [MODULE-SPLIT](2026-10-29-MODULE-SPLIT.md) | `SimpleRisc.hs` split into `SimpleRisc.Types`, `.Decode` and `.Uart` behind a re-exporting umbrella, with the dependency measurement that shows the cut is acyclic |
| 2026-10-29 | [STAGE-ENABLES-AND-REGISTERED-HOLD](2026-10-29-STAGE-ENABLES-AND-REGISTERED-HOLD.md) | per-stage enable registers and a hold that is a clock enable, not a machine-wide next-state select: 16.5% fewer logic cells at parity Fmax, with the limiter moving to the cache MRU lookup |
| 2026-10-29 | [HOLD-ENABLE-AND-MRU-LOOKUP](2026-10-29-HOLD-ENABLE-AND-MRU-LOOKUP.md) | the replacement bit moved into block RAM and the hold enable shortened to one LUT; then `-route_option 1` and `-map_option 3` take the same netlist from 54.9 to 74.5 MHz, and a 54 MHz board image passes the full suite |
| 2026-10-30 | [STRUCTURAL-EXPERIMENTS](2026-10-30-STRUCTURAL-EXPERIMENTS.md) | the structural experiment goal, measurement contract and progress |
| 2026-10-30 | [STRUCTURAL-BASELINE](2026-10-30-STRUCTURAL-BASELINE.md) | named observations, endpoint-pin evidence, the unaligned-BSS startup trap and the 60 MHz receive-versus-readback split |
| 2026-10-30 | [STRUCTURAL-VARIANTS](2026-10-30-STRUCTURAL-VARIANTS.md) | separate BTB banks retained, narrow E2 rejected, the 60 MHz failure isolated to read capture (112.5 degree phase passes) |
| 2026-10-30 | [QUEUE-AND-EFFECT-CONTRACTS](2026-10-30-QUEUE-AND-EFFECT-CONTRACTS.md) | queue ownership contracts, the rejected expanded-queue bank, owned-store effect checks |
| 2026-10-30 | [STALL-BREAKDOWN](2026-10-30-STALL-BREAKDOWN.md) | every classifier cycle attributed to one cause: IPC 0.272, mispredicts 33.5% and operand hazards 24.4% of cycles |
| 2026-10-30 | [STALL-SPLIT](2026-10-30-STALL-SPLIT.md) | hazards by producer and redirects by kind; a replayed predictor model that matches the core per instruction; ranked structural fixes |
| 2026-10-30 | [RETURN-STACK-AND-STRADDLE](2026-10-30-RETURN-STACK-AND-STRADDLE.md) | return stack, straddling-branch install and an assembly-stage correction: 1.18x fewer cycles; a 4-entry stack with pointer restore passes 60 MHz at all placements (Fmax x IPC 1.21x) |
| 2026-10-30 | [BTB-64](2026-10-30-BTB-64.md) | 64-entry BTB, mapped by Gowin to block RAM: 1.069x fewer cycles (1.26x over the pre-predictor core); 60 MHz passes at all placements; the BTB loop is now the critical path |
| 2026-10-30 | [BTB-128](2026-10-30-BTB-128.md) | 128-entry BTB: 1.036x fewer cycles than 64 (1.306x over the pre-predictor core); passes 60 MHz everywhere but with 0.07 ns worst slack |
| 2026-10-31 | [FREQUENCY-STRUCTURE-PLAN](2026-10-31-FREQUENCY-STRUCTURE-PLAN.md) | plan: path census at 81/99 MHz, what-if cuts, loops vs feed-forward, IPC price of extra cycles, core and memory apart, routing, SDRAM phase on the board |
| 2026-10-31 | [PATH-CENSUS](2026-10-31-PATH-CENSUS.md) | all 3,000 setup paths at 96 MHz: six structures fail at 75-78 MHz (front end, execute, cpuFast select, hold enable, multiplier, cache); cutting the two control fan-outs alone gives 79.7 MHz with 10 endpoints failing at 84 |
| 2026-10-31 | [SDRAM-OPERATING-ENVELOPE](2026-10-31-SDRAM-OPERATING-ENVELOPE.md) | standalone and integrated physical phase sweeps at 48/54/60 MHz, repeated passing windows, sampled margins and recovery evidence |
| 2026-11-01 | [UPLOAD-DEBUG](2026-11-01-UPLOAD-DEBUG.md) | root-causing and fixing `U` framed CRC32 upload `ERR HDR` failures: stack-free boot ROM (`0` stack loads), multi-line ROM substitution fix in `sdram/build.sh`, and host error-drain recovery |
| 2026-11-01 | [LOOP-PRICING-AND-80MHZ-FIXES](2026-11-01-LOOP-PRICING-AND-80MHZ-FIXES.md) | 96 MHz loop vs. feed-forward census, exact `Vperf_tb` classifier cycle counts across 6 loop-pricing variants (`btb_nobypass` +0.00004%, `redirect_plus1` +0.80%, `e2_forward` -7.32%), and zero-IPC-cost structural fixes |
| 2026-11-01 | [FPRISC-72-PRESET](2026-11-01-FPRISC-72-PRESET.md) | `SDRAM_PRESET=fprisc-72` (CPU 72 / SDRAM 48): FP-RISC suite passes on the board; hardware 1.23x faster than the rejected 72/54 image on the same binary, today's FP-RISC 1.19x slower on the classifier |
| 2026-11-02 | [NEXT-STEPS](2026-11-02-NEXT-STEPS.md) | ranked plan: 81 MHz board close, E2->D forwarding, memory-envelope decision, congestion, reliability |
| 2026-11-02 | [CPU81-TIMING](2026-11-02-CPU81-TIMING.md) | CPU81/SDRAM48 closes on the board: bridge multicycle constraints, placement sweep, pipelined DSP multiply; 30,720 M + 38,400 I checks pass |
| 2026-11-02 | [E2D-FORWARDING](2026-11-02-E2D-FORWARDING.md) | E2->D forwarding: sim-verified (+test, +tb race fix), then board-passing at 81 MHz on placement 1 (2026-11-04: FP-RISC suite 7/7, classifier -4.5%); fprisc-81 preset moved to placement 1; margin +0.036 ns |
| 2026-11-05 | [SHIFTS-IN-E1](2026-11-05-SHIFTS-IN-E1.md) | shifts complete in E1 and forward from E2: 1.041x fewer cycles (IPC 0.382 -> 0.397), 81 MHz closes with more margin (+0.247 ns); the M-stage shift fields removed |
| 2026-11-05 | [SDRAM-CLOCK-DECISION](2026-11-05-SDRAM-CLOCK-DECISION.md) | Gowin replied but could not help with the SDRAM data; the canonical profile is the CPU/SDRAM clock split with the SDRAM at 48 MHz; higher CPU clocks are the goal, canon now 81 MHz (`fprisc-81`) |
| 2026-11-05 | [LOAD-USE](2026-11-05-LOAD-USE.md) | load-use priced: a three-clock cache port with commit forwarding is 1.118x in simulation but does not place at the 81 MHz canon (best 78.9 MHz); not adopted, floorplanning first |
| 2026-11-05 | [IPC-PLAN-81MHZ](2026-11-05-IPC-PLAN-81MHZ.md) | next IPC goals at the 81 MHz canon (board IPC 0.380, 30.8 MIPS): floorplanning, splitting the 14% front-end bucket, then prediction and cache |
| 2026-11-06 | [AREA-CENSUS-AND-FLOORPLAN](2026-11-06-AREA-CENSUS-AND-FLOORPLAN.md) | where the core's LUTs go (about 40% is the slow path, placed in the middle of the die); the correct Gowin region-constraint syntax with `floorplan_cst.py` and `pnr_only.sh`; a two-region floorplan closes the three-clock cache port at 81 MHz in place and route (84.447 MHz, +0.504 ns; not yet adopted) but hurts the canon; a plan for the 22 idle DSP macros with an `ALU54D` probe |
| 2026-11-06 | [THREE-CLOCK-PORT](2026-11-06-THREE-CLOCK-PORT.md) | the cache's CPU port back to three logical clocks, adopted with the generated `fprisc-81.plan` floorplan at placement 3: 84.447 MHz, +0.504 ns from source, board checks and the FP-RISC suite pass, the classifier 1.056x faster on the same binary (6.799 s against 7.179 s) |
| 2026-11-07 | [ARCHITECTURAL-REFACTOR](2026-11-07-ARCHITECTURAL-REFACTOR.md) | staged state ownership, DSP, reset and clock-boundary refactor; first division-only service change |
| 2026-11-08 | [BTB-FRONTEND-FLOORPLAN](2026-11-08-BTB-FRONTEND-FLOORPLAN.md) | census-sized front-end region and adjacent BTB RAM sites; completed 15-setting baseline/candidate placement sweep; candidate fails routability; frequency-option duplicates identified |
| 2026-11-08 | [E1-PAYLOAD-RESET](2026-11-08-E1-PAYLOAD-RESET.md) | isolated E1 reset removal, warm-reset equivalence and matched physical measurements |
| 2026-11-08 | [FOUR-REFACTOR-TRIALS](2026-11-08-FOUR-REFACTOR-TRIALS.md) | combined payload reset, bounded floorplans, DSP counter and division-service trials |
| 2026-11-08 | [LOOP-CENSUS](2026-11-08-LOOP-CENSUS.md) | six trial netlists re-routed with 3,000-path reports (each reproduces its recorded Fmax): the pipeline loops are 7-9 levels at 0.4 ns a level and 5.6-9.5 ns of wire, depth is invariant across netlists while slack swings 1-3 ns; routing length, not logic depth, is the limiter; `loop_census.py` |
| 2026-11-08 | [AGGREGATE-AREA-CANDIDATE](2026-11-08-AGGREGATE-AREA-CANDIDATE.md) | branch `aggregate-area`: division-only dispatch plus mcycle, mtime and minstret in three ALU54D counters outside the core, -454 whole-design LUTs (-3.0%), all functional gates pass; below the 1,500 threshold, not routed as a distribution, not adopted; the CSR-settle variant moves logic rather than removing it |
| 2026-11-08 | [BTB-PLACEMENT-ABLATIONS](2026-11-08-BTB-PLACEMENT-ABLATIONS.md) | separate BTB anchors and front-end grouping across five placements; anchors route all five with 3 passes versus baseline 2; broad grouping rejected |
| 2026-11-08 | [BTB-FEEDBACK-REGION](2026-11-08-BTB-FEEDBACK-REGION.md) | 37-cell BTB feedback region routes all five but passes 2 versus anchors-only 3; A-to-F routing regressions outweigh local gains |
| 2026-11-08 | [A-TO-F-VALIDITY-REFACTOR](2026-11-08-A-TO-F-VALIDITY-REFACTOR.md) | A-valid fanout 142 to 32 and -202 synthesis logic; functional gates pass, but 0/5 timing passes and higher CLS, not adopted |
