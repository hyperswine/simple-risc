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
