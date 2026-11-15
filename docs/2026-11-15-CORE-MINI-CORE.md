# CoreMini: a simplified five-stage core clocks at 134 MHz

Kind: new probe core plus timing measurement, 2026-11-15. Uncommitted working
tree (the core is `src/CoreMini.hs`, the sweep runner
`boards/tangnano20k/core-mini/run_mini_sweep.py`). The question, following the
seven single-arc probes ([CORE-PROBE-ARCS](2026-11-14-CORE-PROBE-ARCS.md)):
if none of the RV32IM core's individual arcs sets its 84 MHz ceiling, how fast
does a complete "typical stages" pipeline clock when every measured
clock-killer is designed out? [Method follows FAST-CLASH-PROBES](2026-11-09-FAST-CLASH-PROBES.md)

## Result

**The mini core's frozen netlist places at 125-137 MHz across five
placements, setup-derived vendor Fmax.** That is a complete fetch/decode/
execute/memory/writeback pipeline with full forwarding, branch resolution and
a data memory - not an isolated arc. It clears the RV32IM canon's 84 MHz by
roughly half, and lands between the slowest isolated arc (BTB loop, 114-123)
and the fastest (cache load, 240-262), where a composition of all of them
should land.

| Placement | Fmax MHz | Setup slack ns | Worst arc | Levels | Cell ns | Route ns |
|---:|---:|---:|---|---:|---:|---:|
| 0 | 125.2 | -3.357 | opA register -> opB register | 7 | 2.90 | 4.82 |
| 1 | 134.5 | -2.804 | opB -> opA | 8 | 2.39 | 4.78 |
| 2 | 134.5 | -2.804 | opB -> opA | 8 | 2.39 | 4.78 |
| 3 | 134.4 | -2.809 | opA -> opA | 7 | 2.20 | 4.97 |
| 4 | 136.9 | -2.677 | opA -> erReg | 6 | 1.86 | 5.18 |

Every placement's worst path is the same arc: the operand-capture registers
(`opA`/`opB`), whose inputs are the four-way forwarding mux fed by the three
producer compares and the E-stage ALU. Six to eight levels, 1.9-2.9 ns of
cells, and 4.8-5.2 ns of routing - the fabric's routing again dominates the
clock, exactly as in every probe since the first [timing
analysis](2026-11-09-DEFLATE-CORRECTNESS-AND-TIMING.md). The MPW report shows
the known cross-corner artifact (-1.195 ns at 216 MHz; slow/slow passes), so
`passes` is false by construction and setup is the meaningful gate.

Area: 1,339 logic cells, 474 registers, one BSRAM, 889-934 occupied CLS -
about 4 percent of the device and roughly a ninth of the RV32IM core's
12,771 logic / 8,053-8,121 CLS.

## What the core is

A 16-bit fixed-word custom ISA, 8 x 16-bit registers as plain registers, 512
word IROM and 256 word DRAM as blockRams with registered reads, word-addressed
9-bit pc:

    op[15:12] rd[11:9] rs1[8:6] b[5:0]
    R-type: rs2 = b[5:3]
    ST: data register rs2 = b[5:3], address offset = signed b[2:0]
    LD/ST/BEQZ/JAL: offset = signed b[2:0] (word offset; x2 for LD/ST)
    LDI: b = signed 6-bit immediate

    0 ADD rd, rs1, rs2      1 SUB rd, rs1, rs2     2 AND   3 OR   4 XOR
    5 SLT (signed 16-bit)   6 SLL2 rd, rs1, b[1:0]
    7 LD  rd, [rs1 + sext3(b)*2]
    8 ST  [rs1 + sext3(b)*2], rs2
    9 BEQZ rs1, sext3(b)    predict not-taken
   10 JAL rd, sext3(b)      rd = pc + 1
   11 LDI rd, sext6(b)     12 JR rs1     15 HALT freezes the pc

Each measured clock-killer is designed out on purpose:

- No BTB or predictor: predict not-taken, redirect from E. The registered
  target takes two cycles to steer the pc, and the kill window is three
  bubbles - it costs CPI, not MHz. (The BTB feedback arc measured 114-123 MHz
  alone; dropping it removes that arc from every path.)
- No interlock: forwarding at capture covers distance 1 (E result, ALU only),
  distance 2 (ER register) and distance 3 (the W value, including a load's
  data). The assembler contract is two independent instructions after LD.
- The register file is eight plain registers read by mux in D, written by W -
  no BRAM read port on any arc.
- r0 is hardwired zero and never written, so no read bypass for it.
- No CSRs, traps, interrupts, multiply, byte lanes or compression.

The pipeline is F (registered IROM read) -> D (decode + register mux) ->
E (forward + ALU/branch resolve) -> M (registered DRAM read) -> W
(writeback). HALT freezes the pc and the pipeline drains to NOPs.

## Verification

`test/CoreMini.hs` runs three programs (a sum loop with a store and load, a
call/return subroutine exercising every ALU op, a taken-and-not-taken branch)
through the Clash simulator and requires the final register file to equal a
sequential ISA model (`model`, in the same file) after HALT, and to stay
there. Full host suite passes: 74 SimpleRisc, 8 PsramRegs, 6 Deflate,
3 CoreMini.

The debugging paid for itself as a catalogue of pipeline mistakes, each
visible in a pc/operand trace:

- The original ST/BEQZ encoding overlapped the 6-bit immediate with the
  register fields; the fix splits the immediate to 3 bits and puts ST's data
  register in b[5:3].
- The branch target base is the pc three registers behind fetch (pc -> IROM
  output register -> iD -> iE); a base taken from a shallower register is off
  by one on every taken branch and JAL link.
- A redirect decided in E kills nothing by itself: the instruction already in
  D escapes into E at the next edge and executes (and may itself redirect) on
  the wrong path. The D->E transfer must die on the fresh decision, while the
  two wrong-path fetches behind it die on the registered redirect cycles.
- Forwarding priority must be youngest-wins. With the muxes nested the other
  way, a distance-3 producer (in W) shadows a distance-2 producer (in M)
  writing the same register - visible as a loop reading its own stale value.
- Freezing only the pc is not a halt: the fetch address sticks, so
  irom[pc] re-executes every cycle forever. HALT must kill the D and E
  transfers like a redirect.
- The first measurement reported 40 MHz with 43 logic levels from regVec to
  the wrapper's output register - that was the serial LFSR fold observable
  used by the simulation tests, not the pipeline. The synthesis top now
  exposes a parity tree; the fold stays simulation-only. A probe's observable
  is part of its own measurement.

## What it says about the RV32IM core

- A complete pipeline with forwarding, branch resolve and memory lands at
  ~135 MHz on this fabric at ~4 percent occupancy. The RV32IM canon runs at
  84 at ~84 percent occupancy. Occupancy - routing congestion, shared
  control state and the cross-arc paths that no isolated probe sees - remains
  the only candidate left standing for the difference, which is what
  [CORE-PROBE-ARCS](2026-11-14-CORE-PROBE-ARCS.md) concluded from single
  arcs; a whole simplified core now confirms it.
- The mini's own worst arc (operand capture through the forwarding compares,
  6-8 levels) mirrors the core's finding that qualifying operands costs more
  than the arithmetic beneath them ([CORE-FEEDBACK](2026-11-13-CORE-FEEDBACK-TRIALS.md)).
- The 2-cycle redirect and 3-bubble kill cost cycles, not megahertz; at
  ~60 percent more clock they would need a workload comparison before
  adoption, same as any CPI-for-MHz trade elsewhere in the project.

## Limits

Vendor setup-derived Fmax from Gowin V1.9.12.04, GW2AR-18C C8/I7, one
synthesis, five placements of that frozen netlist, 216 MHz SDC, placer
target 240 MHz, map option 3, route option 1, route fanout 8. No board run:
these are estimates under the default corner with the MPW artifact noted
above. The program is baked into the IROM at Clash generation time (the
sweep top runs the sum loop); there is no external memory, bus or CDC. CPI
was not measured. The register file as plain registers would grow quadratically
with more architectural registers - the mux-read cost is part of what makes
this fast, and is not portable to a 32-register ISA without re-measuring.

## Reproduction

```sh
cabal run -v0 simple-risc-test
cabal run clash -- -isrc -hide-package simple-risc src/CoreMini.hs \
  --verilog -fclash-clear -outputdir output/tangnano20k/core-mini-generated
python3 boards/tangnano20k/core-mini/run_mini_sweep.py \
  --out output/tangnano20k/core-mini-sweep2 --freq 216 --target 240
```

[Evidence](evidence/2026-11-15-core-mini/) holds `results.json` (all five
placements with Fmax, slack, levels, cell/route split, MPW and area), the
sweep runner, and SHA-256s of the generated RTL and the frozen synthesis
netlist. Local builds live under `output/tangnano20k/core-mini-generated/`
and `output/tangnano20k/core-mini-sweep2/`. Nothing was committed or pushed;
no board programming was performed.
