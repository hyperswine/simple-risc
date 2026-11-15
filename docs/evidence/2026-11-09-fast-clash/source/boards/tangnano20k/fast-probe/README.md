# Fast Clash timing probes

These independent small circuits separate datapath depth, BRAM output-register
inference, placement and board operation. They do not change the RISC-V core.

- `FastProbe.hs`: LFSR32, counter32, 1024x32 read/write BRAM, BRAM plus add32.
- `FastProbePipeline.hs`: a resettable register before the BRAM add.
- `FastProbeNoReset.hs`: the same extra stage without payload reset (`delay`).
- `reference.v`: independent Verilog LFSR, counter and RAM controls.

## RTL and matched routing

From the repository root:

```sh
cabal run -v0 clash -- -isrc -hide-package simple-risc src/FastProbe.hs --verilog \
  -fclash-clear -outputdir output/tangnano20k/fast-probe-generated
cabal run -v0 clash -- -isrc -hide-package simple-risc src/FastProbePipeline.hs --verilog \
  -fclash-clear -outputdir output/tangnano20k/fast-probe-extra
cabal run -v0 clash -- -isrc -hide-package simple-risc src/FastProbeNoReset.hs --verilog \
  -fclash-clear -outputdir output/tangnano20k/fast-probe-norst
python3 boards/tangnano20k/fast-probe/check_rtl.py
python3 boards/tangnano20k/fast-probe/run_sweep.py \
  --freq 216 --target 240 --out output/tangnano20k/fast-probe-sweep
```

Use a fresh output directory per experiment. Each variant synthesizes once;
options 1–4 route that exact netlist with SHA-256 verification. All output bits
are captured and folded to an observable pin. The common flow is map 3, route 1,
route fanout 8, no floorplan or filler. The script records failing timing as data;
a successful process exit is not timing qualification. The JSON validates the
actual clock constraint and includes setup/hold counts, minimum pulse width,
margins and area. `passes` now requires nonnegative pulse-width slack as well
as setup/hold closure; `setup_hold_passes` is deliberately separate. Historical
raw run JSON predates that audit: use the evidence `reviewed-timing.json` for
the complete classification, not its original `passes` field.

`check_rtl.py` checks six generated circuits against independent models for
20,000 cycles through reset, enable stalls and RAM wrapping. It also simulates
the board UART/window protocol and rejects deliberately wrong RTL, a wrong
signature with a valid checksum, and a bad checksum.

## Optional physical board test

The board harness runs only the LFSR and control synchronizers at the fast clock.
A 27 MHz controller waits for 2 ms of continuous PLL lock, resets the LFSR, opens
a known run window, then freezes it and waits 32 slow clocks before sampling its
32-bit state. Thirty-two windows vary from 65536 to 73472 reference-clock cycles.
UART is clocked from the unchanged 27 MHz source. The host computes expected
states with GF(2) matrix exponentiation and permits only a uniform +/- one-fast-
clock boundary ambiguity; failures are not excused by per-bit reconstruction.

Clock groups are explicitly asynchronous for the control synchronizers and the
held-data snapshot. This is a CDC protocol test, not blanket CDC signoff. The
normal core-clock setup/hold checks still cover the LFSR, reset and enable fanout.
No external I/O delay or explicit PLL jitter uncertainty is added by this probe.

Example (changes FPGA SRAM temporarily, not flash):

```sh
python3 boards/tangnano20k/fast-probe/run_sweep.py --board --variants lfsr \
  --freq 594 --target 625 --placements 0 --out output/tangnano20k/board594
python3 boards/tangnano20k/fast-probe/check_board.py output/tangnano20k/board594 \
  --restore output/tangnano20k/fprisc-84 --out output/tangnano20k/board594-check
```

The checker requires the current board identity to match the restoration
manifest and verifies the restoration bitstream hash before programming. It
keeps one UART descriptor open, restores in `finally`, and verifies the original
identity afterward. The default loader is the local OSS CAD Suite executable.
Pass a particular `ROOT/lfsr/pN` directory to check another placement. Every test
checks all 32 frames; partial reception or a single wrong state fails the run.

Frames are 17 bytes: `FPH1`, little-endian MHz/index/window-cycles/state, then
an XOR checksum. `FPH2` uses half-MHz units for the frequency field (607.5 MHz).
The checksum checks transport; the independent expected LFSR state checks work.
`analyze_boundary.py RESULTS.json` diagnoses failed snapshots after the fact.

The reset-free RAM output probe intentionally does not clear its output payload
on reset. Production use needs an appropriate validity contract; do not replace
resettable registers blindly.

[Results and interpretation](../../../docs/2026-11-09-FAST-CLASH-PROBES.md).
