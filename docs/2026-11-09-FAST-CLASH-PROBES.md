# Fast Clash probes: datapath limits, BRAM registers and the physical board

Kind: controlled implementation and hardware experiment, 2026-11-09. Adds
standalone probes beside the unchanged RV32IM core, following the
[Deflate measurement](2026-11-09-DEFLATE-CORRECTNESS-AND-TIMING.md).

## Findings

There is no general 80 MHz ceiling in Clash or the connected Tang Nano 20K.
Small Clash circuits have much shorter routed paths, and the board produced
correct LFSR signatures at 607.5 MHz and, with selected placements, at 621 MHz.
That is bounded experimental operation, **not high-frequency timing signoff**:
the final audit found minimum-pulse-width violations which the initial
setup/hold-only result flag had omitted. The clock-model issue remains open.

The strongest controlled design result is the BRAM boundary. Putting an add32
immediately after RAM gives 205–210 MHz setup-derived Fmax. A resettable register
before the add raises that to 286–300 MHz. Removing reset from that payload stage
lets Gowin use the native BRAM output register: 316–354 MHz, with 32 fewer fabric
registers. The latter change needs a validity contract in any real consumer.

## The experiment

Six Clash circuits, each separately synthesized, plus independent hand-written
Verilog controls for the first three:

1. A 32-bit LFSR: wires and one four-input XOR feedback function.
2. A 32-bit incrementing counter: a carry-chain feedback path.
3. A 1024x32 read/write block RAM, with its output captured in a register.
4. The same RAM followed by a 32-bit constant add, then the capture register.
5. The same add, with a resettable pipeline register inserted before it.
6. The same extra stage implemented with reset-free Clash `delay`.

The common observation wrapper captures every output bit and folds it to a pin;
outputs cannot be trimmed. Probe reset comes from a PLL-lock synchronizer.
Each design gets one synthesis and five placements of that exact frozen netlist,
verified by SHA-256. Settings: GW2AR-LV18QN88C8/I7, Gowin V1.9.12.04, 216 MHz
constraint, target 240 MHz, map 3, route 1, route fanout 8, no floorplan or filler.
This gives **45 routes** across nine variants. Every route completes.

Generated RTL matches the independent Verilog models for **20,000 cycles** with
reset, enables and RAM wrapping. Both integer- and half-MHz board protocols are
simulated. Negative controls reject a wrong RTL feedback tap, a wrong signature
with a valid transport checksum, and a wrong checksum.

## Routed datapath results

These are the vendor's **setup-derived Fmax estimates**, not complete safe clock
limits. Minimum pulse width is discussed below. Area includes the observation
wrapper. Ranges span all five placement options, including duplicated outcomes.

| Circuit | Reported Fmax range, MHz | Logic | Fabric registers | BSRAM |
|---|---:|---:|---:|---:|
| Clash LFSR32 | 507.960–648.828 | 17 | 66 | 0 |
| Verilog LFSR32 | 507.960–648.828 | 17 | 66 | 0 |
| Clash counter32 | 392.555–428.383 | 47 | 66 | 0 |
| Verilog counter32 | 392.555–428.383 | 47 | 66 | 0 |
| Clash BRAM → register | 374.862–399.142 | 38 | 44 | 2 |
| Verilog BRAM → register | 374.805–400.410 | 38 | 44 | 2 |
| Clash BRAM → add32 → register | 205.225–209.738 | 70 | 76 | 2 |
| Clash BRAM → resettable register → add32 → register | 285.813–300.053 | 70 | 108 | 2 |
| Clash BRAM → reset-free register → add32 → register | 316.213–354.185 | 70 | 76 | 2 |

The LFSR and counter controls match their Clash counterparts at every placement
in timing and logical resources. The BRAM controls differ slightly in placement,
with the same logical resources. This gives no evidence of a general Clash
translation penalty for these circuits; it does not prove every Clash coding
style maps well or that dense CPU routing will behave like these tiny designs.

The netlists explain the BRAM comparison directly:

- Direct registered readout uses `SDPB.READ_MODE=1`.
- Add before capture uses `READ_MODE=0`; the output register cannot be folded
  backward through the arithmetic.
- The extra resettable Clash register stays in fabric (`READ_MODE=0`), adding
  32 flip-flops. Its critical path is the RAM output to those flops.
- The reset-free version is absorbed (`READ_MODE=1`). It returns to 76 fabric
  registers and improves the worst placement's Fmax by 54% over the unpipelined
  add, at the cost of one additional cycle of latency.

Gowin's [GW2AR datasheet, DS226-2.7E](https://cdn.gowinsemi.com.cn/DS226E.pdf)
separately specifies a much shorter BSRAM clock-to-output delay when its output
register is used (0.31 ns versus 2.26 ns for C8/I7). This supports the structural
interpretation; the routed comparisons above remain the actual evidence here.

## Physical board checks

A separate harness keeps the UART and window controller on the 27 MHz reference
clock. Only the Clash LFSR and its synchronized controls run at the swept clock.
It resets the LFSR, enables it for a known reference-clock interval, freezes it,
waits 32 slow clocks, and reports its state. The host computes expected states
independently by GF(2) matrix exponentiation. Window lengths vary from 65536 to
73472 reference cycles. All frames, indices, checksums and signatures are checked;
a uniform +/- one-fast-clock boundary ambiguity is permitted, but every passing
window in this experiment matched the **exact** expected count.

The initial 216 MHz run failed only its first window: it matched 524142 LFSR
steps instead of 524288. Subsequent windows were exact. Adding a wait for **2 ms
of continuous PLL lock** before the first run made all 32 windows pass. This is
consistent with a startup-settling effect; it is not proof of the particular
analog mechanism. The first result is retained, not discarded from the record.

With that startup correction:

| Clock MHz | Placement | Correct windows | Outcome |
|---:|---:|---:|---|
| 216 | 0 | 32/32 | pass, also repeated |
| 324 | 0 | 32/32 | pass |
| 432 | 0 | 32/32 | pass |
| 540 | 0 | 32/32 | pass |
| 594 | 0 | 32/32 | pass, repeated after the failing high-clock trials |
| 607.5 | 0 | 32/32 | pass |
| 621 | 0 | 0/32 | fail, reproduced |
| 621 | 1 | 32/32 | pass |
| 621 | 2 | 32/32 | pass; same reported timing/site outcome as option 1 |
| 621 | 3 | 0/32 | fail |
| 621 | 4 | 5/32 | fail |

Each 621 MHz image reports positive setup slack (+0.127 to +0.327 ns) and zero
setup/hold violating endpoints. Each window there is roughly 1.5–1.7 million
LFSR clocks. These are short room-condition checks of one board, not a PVT,
long-duration reliability or all-placement qualification at lower frequencies.
The PLL output configuration stays within the datasheet's 625 MHz C8/I7 maximum;
that specification is not a guarantee that arbitrary fabric logic or clock pulses
are timing-safe at that frequency.

The failure pattern identifies a likely control-boundary problem. Across all
32 samples, placement 0 is exactly a fixed mixture of bits from states N and N+1
(mask `0xffe1000f` selects N+1). Placement 4 is also exactly such a mixture, with
bits 6–8 one step ahead (mask `0x000001c0`). Placement 3 mostly follows that pattern
but one bit has no single fixed offset. The final snapshot is taken long after
the fast data is held. This strongly suggests inconsistent stopping through the
shared clock-enable distribution; it is not consistent with a simple uniformly
wrong PLL frequency. It does not establish a particular silicon or tool defect.
The diagnostic never changes a failing sample into a passing one.

## Timing-audit correction: minimum pulse width

The initial helper, like the existing core timing guard, checked frequency,
setup slack, and setup/hold endpoint counts. That is insufficient. In the final
raw-report audit, **all 58 reports collected for this experiment have negative
minimum-pulse-width slack**, including the 216 MHz routes. Historical raw JSON's
`passes` and hardware logs' `STA pass` mean only those original setup/hold checks.
The evidence `rtl-checks/reviewed-timing.json` supplies the corrected classification
for every report. The new helper separates `setup_hold_passes` from `passes`, and
requires nonnegative minimum-pulse-width slack for the latter.

For the 621 MHz placement-0 report, the modeled low pulse is -1.704 ns against
1.000 ns required, hence -2.704 ns slack. Its late falling clock path is
0.805 + 5.329 + 2.274 = 8.409 ns; its early rising path is
1.610 + 3.583 + 1.511 = 6.705 ns. At 216 MHz the same kind of analysis gives
-1.195 ns slack. These negative modeled widths are not measured oscilloscope
waveforms. They combine differing early/late PLL and clock-network delays.

The [Gowin timing guide, SUG940-2.0.5E](https://cdn.gowinsemi.com.cn/SUG940E.pdf)
defines pulse-width slack using those early/late clock paths and the cell's
required width. We have not demonstrated that the pessimism can legitimately
be removed, or that the constraints/model are wrong. Therefore no high-frequency
image here receives complete timing signoff, even when the hardware run passes.
No pulse-width exception or ideal-clock workaround was used to hide the failure.
There is also no explicit PLL jitter uncertainty in these probe constraints.

## What this says about simple-risc, and the next useful work

- The 64–84 MHz complex-design results are not a universal Clash/board limit.
  Tiny circuits run much faster, and equivalent plain Verilog does not provide
  a magic speedup. The CPU/Deflate path depth and routing remain primary targets.
- Pipeline boundaries and register semantics matter. The BRAM experiments
  isolate a large difference caused by where arithmetic sits and whether a
  payload stage resets. Inspect mapped primitives, not just Haskell stages.
- Placement affects real control timing near the limit. A positive setup-only
  summary is not enough; include pulse-width and clock-uncertainty analysis and
  preserve the full placement distribution.
- The immediate design experiment remains splitting Deflate symbol decode from
  bit-buffer consumption, then measuring latency/throughput as well as Fmax.
- The immediate flow investigation is the PLL/generated-clock minimum-pulse-
  width model, preferably as a minimal vendor-support case using these reports.
  Extend the shared core timing guard with pulse-width checks before using it to
  qualify much higher clocks. Do not simply suppress this report.
- For a cleaner extreme-frequency experiment, isolate or distribute the stop
  enable so its fanout does not become the measurement boundary. The present
  data does not give an intrinsic maximum frequency for the LFSR recurrence.

All programming was SRAM-only. Each hardware batch restored and re-identified
`fprisc-84`, build `28ed47fb2abb9afc`; flash was not written. After the final restore,
processor smoke checks pass: exact C arithmetic, UART RX/TX, Ctrl-C recovery,
memory clear/reload and byte/halfword/word stress.

## Reproduction and evidence

[Component guide](../boards/tangnano20k/fast-probe/README.md) gives commands.
[Evidence](evidence/2026-11-09-fast-clash/) contains all raw timing/resource reports,
frozen netlists, generated RTL, source snapshots, input/bitstream hashes, RTL
checks and negative controls, hardware frames/results, restoration logs, the
corrected timing audit and the per-bit boundary analysis. Full builds remain
under `output/tangnano20k/fast-probe-*20261109/`.
