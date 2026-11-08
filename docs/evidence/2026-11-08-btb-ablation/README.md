# Isolated BTB anchoring and front-end grouping

See [the report](../../2026-11-08-BTB-PLACEMENT-ABLATIONS.md).

`protocol.json` records the frozen netlist and ROM hashes, three CST fragments,
settings and imported baseline sources. `baseline-p*.json` explicitly mark the
five reused controls; the other ten receipts are new runs. The baseline had
already been reproduced in the preceding sweep. No control is presented as a
new measurement. The raw baseline placement-4 return code is normalized from
`tool-error` to `unrouted` in `summary.json` using Gowin PR0004.

`input-audit.json` records checks of all 15 constraint files, timing constraints,
tool options, frozen input hashes and imported-control provenance.

`summary.json` contains results and resources. `loop-census.json` groups the
3,000 reported setup paths by structure and records cell/routing delay samples.
Samples can contain different endpoints between runs; their medians do not
represent all device wiring. No Fmax is assigned to a timeout or unrouted run.
Constrained hard-block sites appear with a `CST_` prefix in `.posp`; free sites
use `PLACE_`. The summary checks both BTB anchor locations when timing exists.

Full timing reports and the frozen netlist remain in
`output/btb-ablation-2026-11-08/`. Per-run timing hashes identify reports.
Imported baseline directories are symlinks to the preceding sweep. Compact
reports, constraints, logs and receipts are copied here with a hash manifest.

To reproduce the experiment, retain the preceding sweep's frozen inputs and
verified baseline controls. Copy `sweep.py`, `summarize.py`, `audit.py`, and `archive.py`
into `output/btb-ablation-2026-11-08/` and run them from the repository root.
The driver builds each candidate by adding exactly two statements to the
canonical fragment, holds a lock against duplicate drivers, runs the installed
Gowin tool through `pnr_only.sh`, and resumes existing receipts. Use a fresh
output root (adjust the explicit path in each script) for an independent run.
Gowin license access is required. No default preset or RTL is modified.
