# BTB/front-end placement evidence

The [report](../../2026-11-08-BTB-FRONTEND-FLOORPLAN.md) defines the frozen
candidate, sizing assumptions, comparison protocol and results.

`protocol.json` identifies the shared netlist and ROM, fixed constraints,
placement/target grid and per-attempt timeout. `regions.json` contains the
census sizing. `baseline.cst` and `candidate.cst` are the two fragments.
Per-run JSON receipts distinguish timing failures, timeouts and tool errors;
logs and post-place files retain placement evidence. `summary.json` and
`loop-census.json` contain compact timing/resource and structural summaries.

Full 3,000-path reports remain in
`output/btb-floorplan-2026-11-08/VARIANT-tTARGET-pPLACEMENT/impl/pnr/`;
`timing-sha256.txt` identifies each. The frozen netlist remains under that
output directory's `frozen/impl/gwsynthesis/`; its hash is in the protocol.
No vendor models or bitstreams are distributed in this evidence directory.

Reproduction uses the original pinned `dcd220d` netlist preserved by the
November 7 baseline experiment. Run `python3 boards/tangnano20k/sdram/frontend_floorplan.py` with that netlist,
its layout and baseline placement-3 resource report, writing `candidate.cst`
and `regions.json` under the output directory. Copy `sweep.py`, `summarize.py`
and `archive.py` there and run from the repository root. `sweep.py` regenerates
and verifies baseline constraints, freezes inputs, prepares each target and
runs `pnr_only.sh` with a 3,000-path request. It requires the installed Gowin
IDE and license access. It resumes completed receipts; use a fresh directory
and adjust its explicit root for an independent new experiment.

The aborted illegal-site preflight is excluded from the measured grid. The
candidate and all final settings were frozen before the clean sweep started.
Both arms share the same RTL, so no functional behavior change is claimed or
new simulation required. STA here is not board or SDRAM electrical signoff.

The driver receipts retain raw subprocess status. The summary reclassifies
Gowin PR0004 as `unrouted` and records the net count; other tool errors remain
separate. Timeout entries have no measured Fmax. `input-audit.json` verifies
the frozen hashes and all 30 constraint/option sets.
