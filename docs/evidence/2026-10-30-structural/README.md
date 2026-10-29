# Structural baseline evidence

Read [the findings and limits](../../2026-10-30-STRUCTURAL-BASELINE.md) and
[the active experiment plan](../../2026-10-30-STRUCTURAL-EXPERIMENTS.md) first.
No CPU storage optimization or higher clock is accepted by this bundle.

## Contents

- `baseline-sources.tar.gz`: pre-change Haskell and SDRAM-board source, captured
  at `44fcaf0`; Python bytecode caches are omitted. `baseline.json` is the
  original inventory, which also lists cache files not needed for replay.
- `measurement-sources.tar.gz`: source for named observations, metadata,
  diagnostics, the startup fix and CI at the end of this measurement milestone.
- `generated/`: compressed baseline, ordinary and observed CPU RTL. The IMC
  ordinary and observed simulations run the same frozen guest. The ordinary
  CPU is the only one used for hardware synthesis.
- `builds/`: four retained timing/resource/netlist/configuration sets. Bitstream
  SHA-256 files identify local FPGA images; the large bitstreams are not copied.
  The existing 60 MHz build used synthesis hint 66 MHz, whereas the fresh
  60 MHz build used hint 60 MHz. They are not a controlled optimization pair.
- `baseline/perf/`, `observed/perf/`, `observation-comparison.json`: run/build
  receipts, complete output and independent classifier/counter comparison.
- `hardware/`: raw UART/signature bytes and exact guest binaries; final upload
  comparisons additionally contain their runner, protocol, linker and C sources.
  Older diagnostic runs predate automatic runner snapshotting; their recorded
  runner hashes are retained, but their original runner bytes are not all present.
- `rtl/`, `formal/`, `logs/`: local checks and diagnostics. Source snapshots and
  receipts distinguish these results from hosted CI, which is not claimed.
- `misaligned-reporter-symbols.txt`: the actual pre-fix ELF's BSS symbols.
- `run_upload_comparison.py`: local SRAM-program/probe/restore orchestration;
  it expects the original output-tree layout and installed loader path.

The frozen guest binary/ELF and independent Python oracle already reside in
`../2026-10-28-controlled-benchmark/` as `base.bin.gz`, `base.elf.gz` and
`dtree-oracle.py`. Their hashes are checked in the new comparison receipts.

## Replay outline

1. Extract the source snapshots into separate directories. Use the repository's
   pinned Cabal project/toolchain and the source snapshot as the Clash include
   path, with `-hide-package simple-risc`. Generate `SdramPipeline` for ordinary
   RTL and `SdramPipelineObserved` for simulation; add `-DRISCV_COMPRESSED` for
   IMC. Use a new output directory for every generation.
2. Run `check_pipeline_rtl.py --generated .../SdramPipelineObserved.topEntity`
   with an explicit `--out` per experiment. `--upload-pattern zero` requires
   `--boot-loader --loader-command U`; it checks CRC and backing RAM without
   executing those bytes. The pin-model case used 512 words, 60 MHz, phase 135,
   6 ns tAC, the retained 60 MHz ROM, and the real 868-clock UART divider.
3. Run `run_perf.py` using the frozen binary/ELF, clocks 48/48, `--single-clock`,
   two ways and line bits 11. Add `--profile-cpu` only for observed RTL.
   Source/configuration/binary hashes guard replay and resume.
4. Rebuild hardware with ordinary RTL and all settings from its `build.tcl`,
   `clocks.sdc`, cache/controller sources and ROM. Do not infer the synthesis
   hint from the actual clock. `analyze_implementation.py` retains detailed
   physical endpoint pins and mapped drivers.
5. Physical diagnostics require the correct programmed image, matching clock
   and an idle UART. The diagnostic script itself never programs the FPGA;
   use the retained orchestration's SRAM-only and unconditional restoration
   pattern. A failed CRC is a refusal to execute, not permission to fall back
   to unchecked upload. The signature reporter still uses the UART, so an
   absent reply remains inconclusive.

Raw vendor reports and programming logs are preserved byte-for-byte, including
their original whitespace. Internal STA and functional pin simulation are not
SDRAM I/O/PVT signoff. The board was restored to its pre-task 54 MHz image and
the final twelve upload probes passed.

## Integrity

`manifest.json` hashes all files in this directory except itself, plus the
authored source/doc files in the live checkout and the shared frozen inputs.
The source archives retain the corresponding implementation bytes independently
of later checkout changes. Hash consistency is provenance, not a proof of
correctness or of an unmodelled electrical interface.
