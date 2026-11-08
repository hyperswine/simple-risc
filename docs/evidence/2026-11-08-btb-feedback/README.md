# BTB feedback-region evidence

See [the report](../../2026-11-08-BTB-FEEDBACK-REGION.md).

`protocol.json` identifies the frozen netlist/ROM/SDC, imported controls and
constraint fragments. Baseline and anchors-only receipts explicitly identify
reused measurements. Five `feedback-p*.json` receipts are new measurements.
The baseline placement-4 raw tool error is classified as unrouted from PR0004.

`feedback-region.json` records every selected primitive, graph-selection rule,
capacity estimate, reference-report hashes and region. The generator expands
vector ranges before connectivity traversal; it stops at registers and RAMs
and closes whole carry chains. Reference reports provide a column-center
heuristic, not a physical mapping of the RAM site index to fabric columns.

`input-audit.json` checks all 15 netlist, constraint and option combinations.
All run SDC files match byte-for-byte. The PNR wrapper appends the same three
report-only commands to the frozen SDC; the audit checks this exact addition.
`summary.json` has timing outcomes and resources; `loop-census.json` has the
critical-path census. `feedback-diagnostics.json` checks observed constrained
cell coordinates and that reported BTB feedback paths are covered by the
selected cone. Unobserved cells are explicitly listed. `.posp` independently
verifies the hard-block anchor sites, but does not list every fabric cell.
Matching BTB source/destination pins uses each report's worst-slack path for
that pair; intermediate arcs and transition polarity may still differ.
There is no assumption that critical-path samples represent all device wires.

Full timing reports and frozen netlist remain under
`output/btb-feedback-2026-11-08/`; per-run report hashes are retained here.
Compact reports, constraints, logs and scripts have a SHA-256 manifest.

To reproduce, preserve the preceding ablation's frozen inputs and ten control
runs. Generate `feedback-group.cst` and `feedback-region.json` with
`boards/tangnano20k/sdram/btb_feedback_floorplan.py`, using all five anchors-only
`.tr` files and baseline placement-3 `.rpt.txt`. Copy the runner/analysis
scripts into `output/btb-feedback-2026-11-08/`; run `sweep.py`, `summarize.py`,
`diagnose.py`, `audit.py`, then `archive.py`. `finalize.py` writes the report.
The runner resumes completed receipts; an independent run needs a fresh
output directory and the explicit script paths adjusted. Gowin license
access is required. Default presets and RTL are unchanged.
