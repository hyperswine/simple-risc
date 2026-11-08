# A-to-F validity refactor evidence

See [the report](../../2026-11-08-A-TO-F-VALIDITY-REFACTOR.md).

`candidate.patch` is the complete RTL-source change. It is an isolated
experiment; the default source is unchanged. `prepare.py` copies the source
snapshot before patching it; `source-manifest.json` identifies that snapshot.
`baseline-control-verification.json` checks the previously regenerated control
against frozen production RTL after removing Verilog line comments, and checks
current source against that control after removing Haskell line comments. The
retained, unused division helper does not change generated logic.

`host-receipt.json` records the 74+8 passing host properties. `host-test/` holds
the mechanically adapted tests: test module names are prefixed with `Test`,
package-qualified imports are removed, and `ghc -hide-package simple-risc -isrc`
compiles the candidate directly. Compile with the candidate snapshot as cwd:
`ghc -O0 -threaded -rtsopts -hide-package simple-risc -isrc -i../host-test ../host-test/Spec.hs -outputdir ../host-obj -o ../host-tests`.
Run `../host-tests +RTS -N4`. This avoids accidentally testing the installed baseline library.

Clash command (from candidate-source): use the repository's built `clash`
executable with `-isrc -hide-package simple-risc -DRISCV_COMPRESSED
src/SdramPipelineObserved.hs --verilog -fclash-clear -outputdir ../candidate-generated`.
Both production and observed top entities are generated. `validate.py` runs
cache/CDC and warm-reset tests, including their negative controls. Receipts
record actual commands, source hashes and exit codes.

`synthesize.py` copies the baseline wrapper/peripheral inputs, substitutes the
candidate production RTL and keeps identical ROM bytes. It regenerates the
canonical floorplan membership for the new netlist. `synthesis-inputs.json`
records provenance. `synthesis-area.json` distinguishes the whole-design
utilization total (including RAM16 charge) from the core LUT-equivalent census.
`fanout.json` counts direct non-clock input-pin loads before PNR replication;
it is not a post-route all-wire statistic.

`sweep.py` runs five new candidate placements after functional gates pass.
The five baseline receipts are explicitly imported from earlier measurements.
`protocol.json` freezes inputs and options; `input-audit.json` checks all ten
comparisons. `summary.json` contains outcomes, resources and critical paths.
`af-paths.json` retains sampled A-to-F paths with source/payload bit attribution,
absolute routing delay and comparisons on shared endpoint pairs. Matching pins
does not guarantee the same intermediate arcs or transition polarity. Missing
paths are not assigned zero delay; absent reports are not assigned zero Fmax.

Scripts expect repository-root cwd and paths under `output/a-to-f-2026-11-08/`.
Preserve the preceding controls and frozen baseline inputs to reproduce. Use a
fresh output root, adjusting explicit paths, for an independent sweep; the runner
resumes existing receipts. Gowin license access is required. Run `summarize.py`,
`af_paths.py`, `area.py`, `fanout.py`, `audit.py`, `finalize.py`, then `archive.py`.

Full `.tr` reports remain in the output directories; their hashes and compact
PNR reports are retained here. Compressed candidate netlist and both generated
RTL variants are under `synthesis/`. All retained files have a SHA-256 manifest.
