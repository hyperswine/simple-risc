# SimpleRisc

An RV32IM soft processor written in [Clash](https://clash-lang.org), with an
optional compressed (C) frontend, machine mode, a CLINT and PLIC, a boot ROM,
and SDRAM and PSRAM variants, all tested on the Tang Nano 20K. Unmodified GCC
output and the FP-RISC runtime run on the board; the core passes the official
riscv-arch-test suites that fit its RAM.

- [boards/tangnano20k/README.md](boards/tangnano20k/README.md): building,
  flashing, the clock speeds reached, the regression scripts, and a known
  USB-UART bridge issue.
- [The SDRAM report](boards/tangnano20k/sdram/README.md) and
  [the RV64 variant](boards/tangnano20k/rv64/README.md).
- [The roadmap](docs/2026-10-05-SIMPLE-RISC-ROADMAP.md) from tested RV32IM to
  a full RISC-V core, with progress against each step, and the dated reports
  behind it indexed in [docs/README.md](docs/README.md). Raw board evidence
  is under `docs/evidence/`.

## Build

The project builds with cabal (GHC 9.8.2, which ghcup installs):
`cabal.project` pins the compiler and `cabal.project.freeze` every
dependency's version. `cabal.project` also writes the GHC environment file
that the Clash compiler uses to find the project's packages.

```bash
cabal build all
cabal test
cabal run clash -- -isrc -hide-package simple-risc src/SimpleRisc.hs --verilog
```

The board scripts under `boards/tangnano20k/` run the last command for you
and then the open-source (yosys, nextpnr, openFPGALoader) or vendor (Gowin)
flow; see the board README. Generated bitstreams and reports go to `output/`,
which is not tracked.

## Layout

| path | what it is |
|---|---|
| `src/SimpleRisc.hs` | the core, its devices and the BRAM top entity |
| `src/RiscVCompressed.hs` | the RV32C decoder |
| `src/SdramSimpleRisc.hs`, `src/SdramPipeline.hs` | the serial and pipelined 8 MiB SDRAM images |
| `src/PsramRegs.hs` | the PSRAM register experiment |
| `test/` | the independent `Rv32Model` reference interpreter and Hedgehog differential tests |
| `boards/tangnano20k/` | constraints, build scripts, C test programs, the boot ROM, the SDRAM controller and cache, the RV64 variant, RISCOF plumbing |
| `docs/` | the dated record of every experiment |

`boards/tangnano20k/sdram/sdram.v` derives from nand2mario's Apache-2.0 SDRAM
controller; the `LICENSE` file beside it keeps that license. Everything else
is GPL-3.0-only.

## History

SimpleRisc was split out of [HaskPlayground](https://github.com/hyperswine/HaskPlayground)
on 2026-10-21 with its history. The sibling [fprisc](https://github.com/hyperswine/fprisc)
repository's Tang Nano tests expect this checkout at `../simple-risc`.

## FP-RISC development preset

`SDRAM_PRESET=fprisc-48 boards/tangnano20k/sdram/build.sh` builds the RV32IMC
SDRAM pipeline at CPU/SDRAM 48/48 MHz with the 64 KiB cache and 135-degree
memory phase. Conflicting settings are rejected. A completed build writes
`output/tangnano20k/fprisc-48/build-manifest.json` with source/artifact hashes
and the internal timing gate. SDRAM I/O qualification remains open.

From the sibling `fprisc` checkout, `python3 tools/run_tangnano20k_examples.py
--target qemu` builds and checks seven example cases. To run physically, use
`--target board --fpga-manifest
../simple-risc/output/tangnano20k/fprisc-48/build-manifest.json`; this loads the
recorded bitstream into FPGA SRAM. See the
[FP-RISC preset guide](../fprisc/docs/2026-10-21-TANGNANO20K-PRESET.md).
