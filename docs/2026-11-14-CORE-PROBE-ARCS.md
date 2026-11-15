# Core-structure probes: seven arcs measured alone

Kind: timing measurement, 2026-11-14. Seven standalone probes in
`src/CoreProbes.hs`, each modeling one arc of the RV32IM canon (8f83a6d)
with the core's own functions (`compareOperands`, `aluCandidates`,
`selectedAlu`, `loadValue`, `storeLanes/storeMask`, `partialProducts`,
`productHalf`, `btbIndex/btbTag`, `decodeExecuteControl`). The question:
which individual structure sets the 84 MHz core ceiling, and how fast could
each part clock in isolation? [Method follows FAST-CLASH-PROBES](2026-11-09-FAST-CLASH-PROBES.md)

## Result

**Every arc clocks well above the core's 84 MHz.** The slowest arc (the BTB
fetch loop) reaches 114–123 MHz across five placements of one frozen netlist;
the fastest (the two-way cache read with load merge) reaches 240–262 MHz. The
core's 84 MHz ceiling is therefore not any single datapath — it is the
composition: cross-arc control paths (M-valid to pDBlocked, the hold enable,
the cpuFast select), shared machine state, and routing congestion at ~84%
slice occupancy that no isolated arc sees.

| Probe | Arc modeled | Fmax MHz (5 placements) | Logic | Regs | BSRAM | Worst levels | Max cell ns | Max route ns |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| btb | pc → BTB read → tag compare → target/pc+4/redirect → pc | 114–123 | 216 | 106 | 2 | 10 | 2.98 | 5.31 |
| alu | operands → compareOperands + aluCandidates + selectedAlu → result (feeds back) | 127–136 | 502 | 111 | 0 | 11 | 3.75 | 4.48 |
| shift | full single-cycle 5-level barrel shifter, 3 kinds | 136–138 | 452 | 98 | 0 | 6 | 2.13 | 5.24 |
| branch | compareOperands + branchTakenPrepared + target adder | 140–147 | 260 | 131 | 0 | 7 | 2.38 | 4.73 |
| mul | four 17×17 DSP partial products → registered → 66-bit sum → half select | 195–210 | 88 | 115 | 0 | 4 | 1.05 | 3.83 |
| hazard | consumer packet vs three producer slots (E1/E2-forwards/M-final) + dual-read regfile + forwarding | 207–211 | 197 | 69 | 1 | 4 | 1.52 | 3.22 |
| load | 2-way cache read (tags+data RAMs) → hit/way → loadValue → store merge | 240–262 | 87 | 69 | 0 | 3 | 1.31 | 2.79 |

Constraints: Gowin V1.9.12.04, GW2AR-18C C8/I7, 216 MHz SDC, placer target
240 MHz, map 3, route 1, route fanout 8, one synthesis per probe, placements
0–4 of that exact netlist (SHA-256 verified). Fmax is the vendor's
setup-derived maximum. The −1.195 ns minimum-pulse-width slack at 216 MHz is
the known cross-corner artifact ([PULSE-WIDTH](2026-11-09-PULSE-WIDTH-INVESTIGATION.md);
slow/slow passes +1.312 ns), so `passes` is false everywhere by construction
and setup/hold is the meaningful gate. The `branch` probe shows 64 setup
violating endpoints at the 216 MHz constraint because its derived Fmax
(140–147) is below the constraint — that is the measurement working, not a failure.

## What the arcs say about the core

- **No single datapath is the wall.** Even the slowest arc (BTB loop,
  114 MHz) clears the core's 84 MHz by 36%. The 87 MHz misses on the real
  core are therefore composed paths — the placement-0 miss ran the BTB read
  address through the cache and address select (synchronized reset!), and the
  placement-4 miss was the memory-stage hazard path into decode — not the BTB
  compare or the hazard compare alone ([CORE-FEEDBACK](2026-11-13-CORE-FEEDBACK-TRIALS.md)).
- **The ALU execute arc (127 MHz) is slower than the raw adder work should
  be.** Its 11 levels come from the split-compare qualification, the legal
  gate and the funct3 result mux all feeding the feedback register — matches
  the CORE-FEEDBACK finding that qualifying operands with producer logic
  costs more than the arithmetic.
- **The full single-cycle barrel shifter is cheap enough** (136–138 MHz,
  6 levels): merging shifts into E1 does not by itself set a ceiling.
- **The load/store hit arc is the fastest of the eight structures**
  (240–262 MHz, 3 levels): compressing the three-clock cache port to one
  cycle would not be datapath-limited — the earlier load-use trial that
  failed to place was defeated by area/occupancy, not arc depth
  ([LOAD-USE](2026-11-05-LOAD-USE.md)).
- **The multiply's two-cycle arc clocks 195–210 MHz** — the DSP pipeline is
  never the limiter.

## Limits

These probes are isolated: no shared machine state, no `cpuFast` select, no
hold enable, no cross-arc paths, and ~3–7% device occupancy versus the core's
~84% slices. Their numbers are upper bounds for single arcs and an attribution
tool, not predictions of core Fmax after restructuring. Board operation was
not run: these are setup-derived vendor estimates under the default corner,
with the MPW artifact noted above. The probes model the uncompressed 32-bit
canon (no compressed-fetch straddle logic) and omit CSR/trap slow-path arcs.

## Reproduction

```sh
cabal run -v0 clash -- -isrc -hide-package simple-risc src/CoreProbes.hs \
  --verilog -fclash-clear -outputdir output/tangnano20k/core-probe-generated
python3 boards/tangnano20k/core-probes/run_probe_sweep.py \
  --out output/tangnano20k/core-probe-sweep --freq 216 --target 240
```

[Evidence](evidence/2026-11-14-core-probes/) holds `results.json` (all 35
routes with Fmax, slack, levels, cell/route split, MPW and area per
placement), the sweep runner and generated-RTL SHA-256s. Local builds are
under `output/tangnano20k/core-probe-sweep/` and
`output/tangnano20k/core-probe-generated/`. Nothing was committed or pushed;
no board programming was performed.
