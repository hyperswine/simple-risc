# Shortening the RV32IM feedback paths

The qualified RV32IM core runs at 84 MHz with SDRAM at 48 MHz. At 87 MHz, placement 0 misses on the branch target buffer (BTB) RAM read address, and placement 4 misses on the memory-stage hazard check into decode. The short carry chains on both paths are inexpensive. A previous trial replaced them with LUT trees and every placement got slower. [84 MHz qualification](2026-11-08-FPRISC-84.md) · [Prior comparison](2026-11-09-EQUALITIES-AS-LUTS.md)

The fast probes suggest a more specific experiment. Moving the BRAM output register ahead of an adder and allowing it to map inside the RAM raised setup-derived Fmax from 205–210 to 316–354 MHz. Registering partial terminal-count conditions before a snapshot strobe also shortened a high-fanout control path. On the CPU, test whether the address choice or operand qualification can be prepared in advance without adding a cycle. On Deflate, adding a pipeline stage cost between zero and 29% more cycles depending on the input. [BRAM probes](2026-11-09-FAST-CLASH-PROBES.md) · [Capture and Deflate measurements](2026-11-10-FOUR-TIMING-TRIALS.md)

1. Give the BTB a registered 7-bit read index. Compute sequential and predicted-target indices independently and select the index for the PC actually issued, including redirect, blocked issue and restart. Preserve prediction latency.
2. Carry source indices from fetch with an out-of-range sentinel for an unused operand. Compare each against a producer index directly in the hazard check. Preserve forwarding and stalls. Route independently of the BTB trial.
3. Consider a registered cache refill or recovery step only if routed evidence points there. Track hit latency, miss penalties, branch redirects and elapsed classifier time before adopting an extra cycle.

Test each candidate at 87/48 MHz, placement target 96 MHz, with the existing floorplan and five placement options. Verify both logic and routing delay, occupied slices, setup/hold and minimum pulse width. Adopt a qualified candidate after pipeline checks and a physical workload comparison.

## Placement results

Keep the qualified 84/48 MHz preset. The hazard candidate gains a passing option at 87 MHz, but leaves a larger worst-case deficit and uses more logic. The BTB candidate loses routability. Both changes remain independent patches in the evidence directory.

Worst setup slack in nanoseconds, measured at 87 MHz. Every completed route had zero hold violations and minimum pulse-width slack of +2.250 ns.

| Placement | Canonical core | Registered BTB index | Qualified hazard operands |
|---:|---:|---:|---:|
| 0 | −0.039 | 1,070 unrouted nets | +0.095 |
| 1 | +0.169 | 524 unrouted nets | +0.050 |
| 2 | +0.169 | 524 unrouted nets | +0.050 |
| 3 | +0.102 | −0.861 | +0.037 |
| 4 | −0.003 | −0.554 | −1.063 |
| **Timing passes** | **3/5** | **0/5** | **4/5** |

The canonical and hazard bitstreams match byte-for-byte between options 1 and 2 within each variant. Counting distinct placements gives 2/4 canonical and 3/4 hazard passes. The three unrouted BTB placements have no setup, hold or pulse-width report. The vendor reported PR0004 on all three. [Per-placement results and path details](evidence/2026-11-13-core-feedback/results.json)

| Whole-design metric | Canonical core | BTB | Hazard |
|---|---:|---:|---:|
| Logic | 12,771 | 13,345 (+574) | 13,065 (+294) |
| Registers | 5,316 | 5,322 (+6) | 5,346 (+30) |
| Occupied CLS, completed routes | 8,053–8,121 | 8,212–8,350 | 8,154–8,202 |
| Reset fanout, completed routes | 3,863 | 3,870 | 3,892 |
| Largest reported net inside the core by fanout | 757 | 831 | 829 |
| BSRAM / DSP usage (vendor units) | 40 / 2.5 | 40 / 2.5 | 40 / 2.5 |

**BTB.** The two predictor RAMs take their read addresses from the seven new index bits in the synthesized netlist. The worst reported read-address path at placement 3 moved from the fetch PC (+0.461 ns, 7.404 ns routed) to synchronized reset through the cache and address select (−0.861 ns, 9.282 ns routed). At placement 4 the read address meets timing, but the memory wait state to decode hazard path misses by 0.554 ns. The simple BRAM probe’s benefit depended on mapping an output register inside the block. This experiment changed the address side and left both RAMs in read mode 0. Adding another field to the shared pipeline state introduced a new late control path. [BTB evidence](evidence/2026-11-13-core-feedback/btb/)

**Hazard.** At placement 4, the baseline’s nine-level M-valid to decode path had 3.501 ns of cell delay and 7.728 ns of routing. The new critical path is thirteen levels from E1 operand A to `pDBlocked`, with 5.475 ns in cells and 6.815 ns in routing. It goes through the address adder and `load1` before deciding whether E2 can forward a result. Placement 3 has the same endpoints with +0.037 ns of margin. Qualifying the *consumer* operands earlier leaves the *producer* decision on the critical path. The higher pass count comes with a lower worst-case setup Fmax (79.636 vs 86.706 MHz). [Hazard evidence](evidence/2026-11-13-core-feedback/hazard/)

**Next trial.** Start from the canonical core. Derive a one-bit producer classification from the registered operation for the hazard check, then verify whether the exact forwarding decision can be expressed without the same-cycle address sum or RAM-range check in the path to `pDBlocked`. Preserve load, MMIO, misalignment, trap and hold behavior. A conservative extra stall is an observable change and should be priced separately. Inspect the E1-to-decode path in the netlist before routing, then compare all five placements, area and workload cycles. The existing proposal targets at least +0.2 ns across the placement sweep before qualifying an 87 MHz preset. [Forwarding decision in the core](../src/SimpleRisc.hs) · [Adoption criteria](2026-11-09-AMENDED-PROPOSAL.md)

## Method

Each patch applies independently to the CPU sources at `8f83a6d`. The BTB candidate adds a seven-bit index to the pipe state and chooses among the predicted, sequential, held and redirected addresses. The hazard candidate carries six-bit operand indices in the fetched packet. Value 32 represents an unused operand and cannot match an architectural register. It retains the existing producer selection, forwarding policy and equality operators. [BTB patch](evidence/2026-11-13-core-feedback/btb.patch) · [Hazard patch](evidence/2026-11-13-core-feedback/hazard.patch)

Regenerating the canonical production RTL with Clash 1.8.1 reproduced the November 8 file byte for byte (SHA-256 `f5ba9bce778eb65305b632e2fa39373e8aedc249825c472cc135fdc7ffda85a0`). The same Gowin V1.9.12.04 flow targets the GW2AR-18C C8/I7 with an 87 MHz CPU PLL, 48 MHz memory PLL, 135° SDRAM phase, a two-way 64 KiB cache and a 96 MHz placer target. Each candidate uses the archived control's ROM, wrapper, clocks and synthesis options. The same CSR and bus regions were regenerated against each netlist's own register layout. Each variant was synthesized once. Four control routes come from the November 8 sweep and option 2 was rerouted from its frozen netlist. Options 1 and 2 are counted separately as requested, even where they produce identical results. The setup reports contain up to 3,000 core-to-core paths with Gowin’s `-max_common_paths 1` setting. [Original sweep](2026-11-08-IM-CANON.md)

## Pricing a refill register

The 87 MHz control has a second failing endpoint at placement 0. It runs from the core address to the cache's MRU bypass register (-0.026 ns). This register serves accesses on the hit path. The baseline reports contain no failing refill-completion path. An extra register on refill completion would therefore address a different path.

There is a measured workload cost against which to judge such a change if it becomes necessary. The earlier 81/48 MHz IMC classifier simulation recorded 258,441 fills in a window of 106,126,406 CPU cycles. At one additional unhidden CPU cycle per fill, that would add 0.244% to the measured cycles. That estimate uses the older compressed-instruction workload. A register on every hit has a different cost. [Classifier counters](evidence/2026-11-06-three-clock-port/results-sim-81-48.json)

## Recovery latency

The existing execution model also prices an extra backend redirect cycle. On the earlier classifier the measured increase was 0.802% of window cycles. The control and both experimental RTLs here have 2,104 redirects in a 200,596-cycle benchmark window. Charging one non-overlapped cycle for each at fixed clocks would add 1.05% on this benchmark. Actual overlap and the clock ratio matter. If recovery becomes the limiting path, compare measured elapsed time on the same workload before adopting a new stage. [Earlier redirect experiment](2026-11-01-LOOP-PRICING-AND-80MHZ-FIXES.md)

## Functional verification

Both independent patches passed the full host suite (74 core, 8 UART, 6 Deflate properties). Fresh Verilator RTL passed the two-way cache/CDC guest with eight interrupts across misses, fence and store-effect checks, and corrupt-data, duplicate-store and wrong-path-store negative controls. The UART loader passed a framed upload, CRC readback and execution on the small one-way cache. The warm-reset comparison against fresh canonical RTL matched 20 resets, including seven while held, 485 commits and 127 stores. Ignoring the candidate reset caused the expected mismatch at the first warm reset. [BTB test logs](evidence/2026-11-13-core-feedback/btb/) · [Hazard test logs](evidence/2026-11-13-core-feedback/hazard/)

The canonical and candidate production RTLs executed the identical RV32IM four-kernel image against the same simulated 87/48 MHz clock bridge and cache. The observed builds independently matched the production cycle counts. The four guest-reported kernel results matched exactly.

| Kernel | Cycles | Retired instructions |
|---|---:|---:|
| Arithmetic | 22,166 | 16,008 |
| Memory copy | 32,074 | 12,327 |
| Branches | 45,248 | 17,516 |
| Multiply/divide | 24,954 | 1,502 |
| **Total** | **124,442** | **47,353** |

The larger UART-delimited window measured 200,596 cycles, 18,518 held cycles, 124 cache fills, 2,728 writes and 2,104 redirects in every design. The microbenchmark was used because the reference 94,324-byte FP-RISC classifier image was unavailable in the local builds inspected. No candidate reached board qualification or a measured classifier elapsed time. [Matched workload](evidence/2026-11-13-core-feedback/cpi.c) · [Baseline simulation](evidence/2026-11-13-core-feedback/baseline/profile.json)

## Reproducing the measurements

The evidence includes independent source patches, exact production RTL and frozen Gowin netlists, per-placement clocks and physical constraints, raw timing and utilization reports, router errors and simulation receipts. Compare the `baseline`, `btb` and `hazard` directories. The per-field area census apportions shared cells across their downstream users. [Evidence](evidence/2026-11-13-core-feedback/)

Run the following commands from the repository root. The first replays one placement using the licensed Gowin flow and a new output directory. The second checks an experimental patch against the canonical source. Apply and generate each candidate in a separate checkout. A fresh replay of hazard option 1 reproduced +0.050 ns and the original bitstream byte for byte. [Replay receipt](evidence/2026-11-13-core-feedback/hazard/replay-p1.txt)

```sh
e=docs/evidence/2026-11-13-core-feedback
bash "$e/replay.sh" hazard 1 /tmp/simple-risc-hazard-p1
git apply --check "$e/hazard.patch"
```

For the workload, decompress `cpi.bin.gz` and `cpi.elf.gz` into a temporary directory. Run `boards/tangnano20k/sdram/run_perf.py` with that binary, `--elf`, the candidate’s unmodified generated RTL in `--generated`, `--cpu-mhz 87 --mem-mhz 48 --start 'CPI BEGIN' --end 'CPI END' --limit 3000000` and a fresh `--out` directory. To collect redirects, use the `SdramPipelineObserved` top with `--profile-cpu`.
