# Four refactor trials: reproduction and scope

See [the report](../../2026-11-08-FOUR-REFACTOR-TRIALS.md) for decisions.
Baseline commit: `dcd220d`. Each `*.patch` applies independently to that commit,
not on top of another trial. Patches include the unused division-only helper
present in the working tree; none activates that earlier optimization.

The generated RTL, synthesis netlists and bitstreams remain under ignored
`output/refactor-four-2026-11-08/`. `input-sha256.json` records RTL/netlist and
Gowin model identities. Vendor model source is not redistributed here.
Production RTL has no embedded vendor model; observed DSP RTL includes the
model for simulation. No experimental bitstream was programmed on the board.

## Reproduce

Use the repository's pinned Cabal/Clash environment and installed Gowin IDE,
Icarus Verilog and Verilator. Scripts use repository-relative paths and expect
the working directory to be the repository root. The historical absolute
paths in receipts identify the measured run, not a portable installation.

1. Create independent baseline source snapshots named `all-reset-source`,
   `dsp-source`, and `division-source` under the output directory. Apply the
   corresponding patch. Give each snapshot the repository's GHC package
   environment and a `dist-newstyle` symlink. Preparation scripts document
   the transformations, but patches are the definitive measured source.
2. From each snapshot, invoke the built Clash executable with `-isrc
   -hide-package simple-risc -DRISCV_COMPRESSED --verilog -fclash-clear`.
   Use `src/SdramPipelineObserved.hs` with output `../VAR-generated` for
   reset/division; use `src/DspCycleTop.hs` and `../dsp-raw-generated` for DSP.
   This generates both annotated production and observed top entities.
3. For DSP, copy `dsp/model-test/counter.v` into the output directory's
   `dsp/counter.v`, then run `scripts/package_dsp.py` from the root.
   Run the model tests with `iverilog -g2012 -s counter_tb` (counter, testbench,
   installed `gw2a/prim_sim.v`) and `vvp`; use `-s cascade_tb` for the separate
   cascade test. The counter test holds global enable high, matching the
   board configuration; its increment input is independently exercised.
4. Run `check_pipeline_rtl.py --generated OUTPUT/VAR-generated/SdramPipelineObserved.topEntity
   --out OUTPUT/VAR-rtl-check --compressed --simulator verilator --cache-ways 2
   --cache-line-bits 11 --cdc-bridge`. For reset and DSP, run the retained
   `tests/check_pipeline_reset.py` with `--baseline` and `--candidate` observed
   RTL files and `--out`; put the retained bench beside that script. Baseline
   observed RTL is recorded by the preceding E1 experiment.
   Division's `ServiceCheck.hs` runs with `runghc -isrc -hide-package=simple-risc`
   from its snapshot. It checks semantics rather than cycle equivalence.
5. Copy scripts into the output root and run `measure.py VAR`, followed by
   `route_variants.py VAR floorplan-p3 floorplan-p0`. For reset placement
   comparisons also run `route_variants.py all-reset none-p3 wider-p3`.
   `measure.py` deliberately reuses the canonical stamped ROM from
   `output/tangnano20k/fprisc-81/bootrom-sdram.hex`; verify its recorded hash. A copy is retained here as `bootrom-sdram.hex`.
   `wider.plan` belongs beside the scripts. Gowin requires license access.
6. Run `fanout.py`, `summarize.py`, and `archive.py` to refresh evidence.
   These experimental scripts assume the original output paths. The separate
   source directories and explicit names prevent variants overwriting defaults.

## Interpretation

`fanout.json` counts direct input loads in the synthesized core, excluding
clocks/constants; it does not measure the final replicated routing tree.
DSP's external counter is outside that core census. Whole-design synthesis
resources include it. `summary.json` samples the 25 reported setup paths;
it is not an all-net routing-length metric. `.posp` retains hard-block sites.
Timing gates inspect both clock domains and setup/hold counts. The 1,200-second
routing limit applies per tool attempt; license retries can add wall time.
Concurrent runs make elapsed times unsuitable as router-performance comparisons.

Functional receipts include deliberately failing corruption and side-effect
controls. They qualify these bounded prototypes, not exhaustive architectural
correctness, reset cancellation in all integrated divider states, global enable
behavior of the DSP counter, SDRAM I/O margins or hardware operation.
