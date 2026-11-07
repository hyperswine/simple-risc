# Matched physical experiment

Baseline source is `dcd220d`; candidate is the division-only service change
recorded in the parent plan. Both fresh Clash invocations use the production
`SdramPipeline` top, IMC, the same compiler and `-fclash-clear`. The observed
top is not used for resource or timing measurements.

`measure.py` and `route.py` are the executed experiment drivers, run from the
repository root. They use `output/refactor-2026-11-07/` for generated RTL,
synthesized netlists and build output. `measure.py` accepts optional variant
names to retry a failed licence checkout without repeating completed work.
The baseline source was extracted with `git archive dcd220d src
boards/tangnano20k/bootrom`; its package database points at the existing
workspace dependencies. The candidate uses current `src/`.

Both variants use identical stamped ROM bytes copied from the existing
canonical build; hashes are recorded. No experiment bitstream should be used
as a board release: this deliberately fixes the embedded identity for the
controlled comparison. Normal preset generation must restore the correct
identity before board adoption.

The generated experiment configuration matches fprisc-81: CPU/cache 81 MHz,
SDRAM 48 MHz, 135-degree phase, two-way 64 KiB cache, target 89 MHz, map 3,
route 1, route fanout 8. Floorplans are freshly generated from each synthesized
netlist using the existing semantic plan. State layout is unchanged. The
baseline reproduces canonical placement-3 timing exactly.

The scripts request 3,000 critical paths, but the default report contains
25 setup paths. Route-share statistics in this experiment describe those
reported paths, not an all-path census. Raw timing reports also retain the
vendor high-fanout and congestion summaries. `fanout.py` independently counts
direct synthesized core input-pin loads, excluding clocks/constants; these
are not post-route replicated fanout counts.

Saved synthesis reports, area attribution, hashes, generated constraints and
logs establish provenance without checking in large generated netlists.
The runtime scripts contain local paths; regenerate from the current root
when reproducing on another machine. `summarize.py` parses the raw reports;
`physical-summary.json` is the compact comparison.


The candidate is preserved as `divide-only.patch` against `dcd220d`. The
working tree retains its helper and tests but restores the default pipeline
call after the placement-3 timing regression. To reactivate the measured
candidate in that tree, apply only the `src/SimpleRisc.hs` hunk with
`git apply --include=src/SimpleRisc.hs docs/evidence/2026-11-07-refactor/physical/divide-only.patch`.
The patch and archived hashes describe the measured candidate, not the final
default call site.
