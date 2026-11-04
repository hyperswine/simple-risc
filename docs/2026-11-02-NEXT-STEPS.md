# Next steps: 80 MHz, IPC, memory envelope, reliability

Kind: ranked plan, 2026-11-02. Applies to: HEAD `cf42451`
(`fprisc-72` preset: CPU 72 / SDRAM 48 MHz, board-passing).
Follows: [FPRISC-72-PRESET](2026-11-01-FPRISC-72-PRESET.md),
[LOOP-PRICING-AND-80MHZ-FIXES](2026-11-01-LOOP-PRICING-AND-80MHZ-FIXES.md),
[SDRAM-OPERATING-ENVELOPE](2026-10-31-SDRAM-OPERATING-ENVELOPE.md),
[PATH-CENSUS](2026-10-31-PATH-CENSUS.md).

Roadmap steps 1-4 are done; step 5 is one clock milestone plus IPC work
from its gate. Ranked by payoff / cost:

1. **Close 80 MHz class on the board.** The zero-IPC-cost structural fixes
   are in RTL and sim-verified but not board-proven above 72 MHz.
   Note: exactly 80 MHz is not reachable with this PLL scheme (the SDC
   uses `cpu_freq/3`, the PLL `FBDIV_SEL=CPU/3-1`); the achievable
   target is **81 MHz = 27x3** (CPU VCO 648 MHz, inside the demonstrated
   576-768 MHz range). Build CPU81/SDRAM48 with the fprisc-72 settings,
   pass the timing gate, run the board suite. Done: see
   [CPU81-TIMING](2026-11-02-CPU81-TIMING.md) (gate 83.075 MHz,
   processor + 30,720 M + 38,400 I checks pass; FP-RISC suite still open).
2. **Add E2->D forwarding.** Loop pricing measured -7.3% window cycles
   (+8.9% unheld IPC), eliminating all E2-plain hazard stalls. Highest
   IPC lever; do once 81 MHz closes. In progress: see
   [E2D-FORWARDING](2026-11-02-E2D-FORWARDING.md): board-passing at 81 MHz
   on placement 1 (2026-11-04: processor/M/I checks, FP-RISC suite 7/7,
   classifier -4.5% on the same binary); timing margin +0.036 ns.
3. **Decide the memory story above 48 MHz.** The envelope work shows
   48 MHz has phase margin on both sides while 54/60 MHz do not, and
   short CRC probes do not prove correctness. Either accept
   CPU-fast/SDRAM-48 behind the bridge as the supported shape, or fund
   temp/supply/multi-board sweeps plus the missing Gowin AC timing.
4. **Attack routing/congestion.** Routing is 67-75% of every worst path
   with slices 83-86% full; frequency-plan items 5-6 (core vs memory
   apart, fan-out/duplication, less-logic rebuilds) still bound
   everything above ~80 MHz.
5. **Reliability hardening.** Multi-board coverage, endurance/soak runs,
   crash reports, and the board-path arch-test flow (signature over
   UART; sim-only today).
6. **Beyond: low-priority IPC and fenced experiments.** BTB 128->64 was
   only 1.036x, so further predictor growth waits behind DSP multiply
   and load-use work. Done 2026-11-05: shifts complete in E1 and forward
   from E2, 1.041x (see [SHIFTS-IN-E1](2026-11-05-SHIFTS-IN-E1.md));
   load-use (~8.7% of cycles) is the next hazard producer. RV64/PSRAM stay fenced until step 5's gate is met.

Near-term milestone: 81 MHz x improved IPC (~30+ MIPS) as the next
credible step toward the 96 MHz roadmap gate.
