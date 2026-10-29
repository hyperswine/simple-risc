# Structural variant evidence

Read [the report](../../2026-10-30-STRUCTURAL-VARIANTS.md) and
[the active goal](../../2026-10-30-STRUCTURAL-EXPERIMENTS.md). Separate BTB
banks are retained, E2 narrowing is rejected, and the 60 MHz phase experiment
is an experimental physical result. The supported preset remains 48 MHz.

## Contents

- `control-sources.tar.gz`: pre-variant working source and its original
  inventory. `e2-sources.tar.gz` and `combined-sources.tar.gz` retain evaluated
  alternatives. `e2.diff` and `btb-only.diff` describe the independent changes.
- `retained-sources.tar.gz`, `source-checkpoint.json`: the final source, tests,
  formal models, diagnostic ROM/host/RTL tools, board files, CI and reports.
  This checkpoint is distinct from the older structural baseline bundle.
- `generated/`: ordinary and named-observation CPU RTL, compressed byte-for-byte.
- `builds/`: vendor mapped netlists, routed detailed reports, constraints,
  PLL/ROM configuration and bitstream hashes. Large bitstreams are omitted.
- `simulation/`: frozen classifier receipts/counters/output; fresh IM/IMC
  instruction/loader/fence checks and corrupt-input refusal; exact-phase
  functional SDRAM pin-delay experiment, including its expected failure.
- `physical/`: independent raw readback/CRC/XOR probes, memory-signature and
  output-mode diagnostics, guest binaries and per-run source snapshots.
- `receipts/`: analyses, variant decisions/comparisons, Haskell/tool logs,
  physical instruction/classifier logs, SRAM programmer/restorer logs and
  orchestration. Programs expect the original output-tree layout and installed
  hardware tools. `pin-delay-exact-results.json` uses exact 112.5°; the older
  exploratory `pin-delay-results.json` used 112° and is not the final pair.
- `rom/`: isolated diagnostic ROM plus normal-ROM binary compatibility control.
- `formal/`: each model's individual search output and checker summary.

The frozen guest and independent oracle are shared with
`../2026-10-28-controlled-benchmark/`. `manifest.json` identifies those inputs
and hashes all bundle files except itself. Hashes identify evidence bytes;
they do not prove correctness. The archives preserve source independently of
later edits to the live checkout. Vendor whitespace and negative logs remain
unaltered.

## Replay and boundaries

1. Extract each source variant separately. Generate `SdramPipeline` for
   hardware and `SdramPipelineObserved` for simulation with the pinned Cabal
   toolchain, `-hide-package simple-risc`, a fresh output directory and
   `-DRISCV_COMPRESSED` for IMC. Use the archived variant's source include path.
2. Run `check_pipeline_rtl.py` with the generated observed directory and an
   explicit `--out`. Use the receipts for exact cache, CDC, loader, ROM and
   pin-model settings. Raw mode requires `--boot-loader --loader-command U
   --upload-pattern sequence --raw-readback --rom-file .../readback.hex`.
3. Use `run_perf.py --profile-cpu` and the frozen binary/ELF at 48/48 MHz,
   `--single-clock`, ways 2, line bits 11, and write update. Compare all metrics
   and validate results with `dtree-oracle.py`, not just the completion marker.
4. Hardware comparisons use ordinary CPU RTL and the exact archived build
   configuration. Phase is 135° for the 48 MHz structural pair and 112.5° for
   the diagnostic-ROM 60 MHz structural pair. The phase-only failure/fix pair
   uses original CPU RTL and changes 135° to 112.5°. Decode the archived
   `build.tcl`, `clocks.sdc`, PLL and ROM files before comparing.
5. Physical replay requires the board, matching UART clock and one owner of
   the descriptor. Follow the retained SRAM-only programming and unconditional
   original-image restoration pattern. Normal ROM lacks diagnostic command D.
   Do not run uploaded bytes after a failed upload/readback CRC.

The source bank property uses the production synchronous-reset domain. The
Maude model is finite abstract refinement, not RTL equivalence. Reported Fmax,
functional delayed-read simulation and physical single-board runs are separate
classes of evidence; none establishes full SDRAM I/O/PVT qualification.
No same-clock workload speedup or hosted CI success is claimed. The final
original 54 MHz restore and all twelve verification probes passed.

`collect.py` documents the selection from the original local output tree.
Re-running it on changed source makes a new checkpoint, so verify this bundle
against its present manifest before modifying or rebuilding it.
