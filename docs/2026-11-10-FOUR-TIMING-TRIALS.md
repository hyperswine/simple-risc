# Clock ceiling, Deflate pipeline, vendor reproducer and continuous capture

All four trials are complete. The simple probe passes the default timing model
at 141 MHz across five placements and fails minimum pulse width at 144 MHz.
Registering the Deflate symbol decode improves every placement, but still does
not close 84 MHz. A small standalone Gowin reproducer is validated and packaged.
The continuous hardware probe passes all 32 snapshot pairs at 621 MHz in four
placements; those remain functional results, not pulse-width signoff.

## 1. Default-model clock ceiling

The small Clash LFSR plus observation registers, not the larger UART harness,
was synthesized independently at each PLL frequency, then routed from one
frozen netlist at placement options 0..4. Gowin V1.9.12.04, C8/I7, map 3, route 1,
route fanout 8, target/global frequency 240 MHz throughout. PLL/SDC agree for
each row. The default slow setup / fast hold models remain enabled.

| MHz | Full timing passes | Worst MPW slack ns | Setup/hold passes |
|---:|---:|---:|---:|
| 108 | 5/5 | +1.120 | 5/5 |
| 135 | 5/5 | +0.194 | 5/5 |
| 141 | 5/5 | +0.037 | 5/5 |
| 144 | 0/5 | -0.037 | 5/5 |
| 162 | 0/5 | -0.423 | 5/5 |
| 216 | 0/5 | -1.195 | 5/5 |

MPW slack is identical across placements at each frequency. This brackets the
model-limited ceiling between 141 and 144 MHz for this clock path. It is not a
fabric performance ceiling, or a complete board/I/O signoff. The +37 ps margin
at 141 MHz is small; 135 MHz has more reported margin. No exceptions or
single-corner substitutions are used for these pass counts.

## 2. Deflate registered symbol decode

`PhSym` now registers the fixed-Huffman symbol and code length; `PhDecoded`
consumes bits and length extras on a later cycle. The bit buffer stays intact
between them. Input may append bits while waiting. A partial peek is not
latched until nine bits are available, unless EOF establishes that the shorter
seven/eight-bit code is all that remains; normal length checks still detect
truncation. Output/backpressure, history RAM and the external interface remain
compatible. This is still an experimental standalone stored/fixed inflater.

Measured against the saved November 9 baseline with the same 84 MHz clock,
92 MHz target, ROM vector, wrapper, tool options and five placements:

| Placement | Baseline Fmax MHz | Pipeline Fmax MHz | Pipeline setup slack ns | Baseline route ns | Pipeline route ns |
|---:|---:|---:|---:|---:|---:|
| 0 | 64.451 | 81.036 | -0.435 | 9.483 | 7.838 |
| 1 | 64.110 | 79.757 | -0.633 | 9.027 | 7.864 |
| 2 | 64.110 | 79.757 | -0.633 | 9.027 | 7.864 |
| 3 | 67.122 | 83.317 | -0.098 | 9.358 | 7.277 |
| 4 | 65.568 | 78.552 | -0.826 | 8.772 | 8.019 |

Logic rises 1258 -> 1295 (+2.94%); registers 184 -> 196 (+6.52%); BSRAM stays
17 including the input ROM. Occupied CLS is 706..735 versus 691..703. Worst
paths shrink from 13..14 to 11..12 levels, with 4.235..4.459 ns cell delay versus
5.273..6.304 ns. All five still fail setup at 84 MHz, with 5..33 violating
endpoints. Hold and MPW pass. The report helper now includes MPW in `passes`.
The baseline is the archived routed control, not a newly rerouted baseline.

Validation: final host suite passes; all 176 regenerated-RTL corpus/schedule
cases pass; corrupted expected output is rejected; wrapper midstream reset and
two complete 16384-byte replays pass. Sources and regenerated RTL are archived.

Additional cycles matter. Both the archived baseline RTL and candidate RTL were
simulated with the same no-stall bench and fixtures:

| Fixture | Baseline cycles | Pipeline cycles | Increase |
|---|---:|---:|---:|
| hello | 270 | 310 | 14.8% |
| big | 33292 | 33508 | 0.65% |
| abc | 12120 | 12149 | 0.24% |
| all-literals | 524 | 524 | 0% |
| zlib-stored | 876 | 1130 | 29.0% |

Fixture names do not guarantee block encoding: `all-literals` takes the stored
path; the `zlib-stored` fixture here exercises fixed-Huffman data. The latter
can lose throughput even with the measured 19.8..25.7% Fmax gain. At a fixed
clock the additional cycles are overhead. No Deflate board-frequency result is
claimed. Next useful refinement is the still-long bit-buffer consume/update
cone, with literal-path cycle cost tracked explicitly; the 24-bit-buffer trial
remains separate work.

## 3. Minimal Gowin support package

[Reproducer source and questions](../boards/tangnano20k/fast-probe/mpw-reproducer/README.md)
and [ZIP](evidence/2026-11-10-four-trials/gowin-mpw-reproducer.zip) are ready.
It needs Python and licensed Gowin, but neither Clash nor a board. It routes a
17-logic/66-register frozen netlist twice. Default models yield -1.195 ns MPW;
slow/slow yields +1.312 ns, with identical `.bin` and `.db` hashes. Sources,
constraints, reports and SHA-256 manifest are included. The package asks about
cross-corner correlation, the 1 ns requirement and a supported signoff method.
It has not been sent externally. Production constraints are unchanged.

## 4. Continuous LFSR and paired snapshots

`--continuous` selects the new harness. The probe enable is constant high;
there is no run/stop enable feeding its state registers. Every 256 core cycles,
a snapshot register captures the running state and toggles a notification. The
held bus stays stable for 256 cycles (about 412 ns at 621 MHz) while the toggle
crosses a three-register synchronizer into the 27 MHz domain. That domain takes
two successive notifications, then sends both snapshots and the 256-step gap
in a checksummed FPC1/FPC2 UART frame. The host independently advances the first
state 256 steps and compares the second; zero lockup is rejected.

This is a bundled-data CDC experiment: the slow-domain sample occurs well
inside the hold interval, but asynchronous clock groups do not themselves
prove CDC correctness. It tests recurrence, not absolute clock frequency or
absolute progress from reset. Short sampled windows can miss intermittent
errors outside the windows.

The first implementation made the 8-bit terminal-count decode drive all capture
enables, limiting reported Fmax to roughly 400 MHz at the 621 MHz target. A
registered strobe helped; splitting terminal detection into registered nibbles
before the strobe removed that decode bottleneck. All three revisions' five-
placement results at 216 and 621 MHz are retained, including failed revisions.
Final hardware results (32 pairs per build):

| Clock | Placement | Setup-derived Fmax MHz | Setup/hold pass | Matching pairs |
|---:|---:|---:|---|---:|
| 216 | 0 | 553.265 | yes | 32/32 |
| 621 | 0 | 567.808 | no | 17/32 |
| 621 | 1 | 638.182 | yes | 32/32 |
| 621 | 2 | 638.182 | yes | 32/32 |
| 621 | 3 | 671.341 | yes | 32/32 |
| 621 | 4 | 671.341 | yes | 32/32 |

All 621 MHz builds fail MPW (-2.704 ns), and 216 MHz also fails MPW (-1.195 ns).
The p0 worst path is LFSR Q to snapshot D, so the remaining failure can still
be capture-related. Compared with the earlier stop-enable harness's two passing
placements, four now pass this different functional test. This supports the
harness-bottleneck explanation but does not prove a raw LFSR ceiling or isolate
causality on an identical placement.

Three simulated clock rates (216, 607.5, 621 MHz) pass the UART pair test;
corrupted state, zero state and checksum negative controls are rejected.
SRAM-only board trials restored the original fprisc-84 image, verified identity
`28ed47fb2abb9afc`, and passed processor arithmetic, UART, reset recovery and
memory smoke tests afterward. Flash was not changed.

## Reproduction and evidence

[Evidence](evidence/2026-11-10-four-trials/) contains the full reports, constraints,
frozen netlists, source snapshots, cycle counts, raw UART, board restoration,
regression logs and a SHA-256 manifest. `collect.py` archives local outputs from
`output/tangnano20k/four-trials-20261110`. See `run_ceiling.py` there for the
frequency sweep. Existing Deflate build/check commands still apply. Continuous
probe commands are documented in the fast-probe README. No commits or pushes
were made.
