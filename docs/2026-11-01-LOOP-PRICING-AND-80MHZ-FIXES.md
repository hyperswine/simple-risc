# 2026-11-01: Loop Cycle-Penalty Pricing and 80+ MHz Structural Fixes

Kind: architectural timing census, cycle-accurate IPC pricing (`Vperf_tb`), and RTL structural fixes.
Applies to: `src/SdramPipeline.hs`, `src/SimpleRisc.hs`, `output/tangnano20k/loop-pricing-20261101/loop_pricing_summary.json`, and `output/tangnano20k/structural-80mhz-20261101/`.
Follows: [`2026-10-31-FREQUENCY-STRUCTURE-PLAN.md`](2026-10-31-FREQUENCY-STRUCTURE-PLAN.md) and [`2026-10-31-PATH-CENSUS.md`](2026-10-31-PATH-CENSUS.md).

## 1. Loop vs. Feed-Forward Census at 96 MHz

Using the 3,000-path Gowin timing census at 96 MHz (`output/tangnano20k/census-20261031/cpu96-full.json` for `cpu96-head-p0` at `75.384 MHz` Fmax, `-2.849 ns` worst slack, `1,176` failing endpoints; and `output/tangnano20k/census-20261031/cpu96.json` for `cpu96-head-p0-cutcontrol` at `79.748 MHz` Fmax, `-2.123 ns` worst slack, `220` failing endpoints), every failing register-to-register pair falls into one of three structural categories:

### A. Control-Fanout Pseudo-Loops (`966 / 1,176` failing paths in `cpu96-full.json`, `0` IPC cost to eliminate)

| Source register | Field in `Machine` | Failing paths (`cpu96-full.json`) | Worst slack (96 MHz) | Root cause |
|---|---|---:|---:|---|
| `core/machine_0_2076_s0` | `cpuInRom` | `638` | `-2.695 ns` | `breaking = emergency & (~cpuInRom)` combinational gate feeding `holding` (5,000-flop CE tree) and `emergencyReset` |
| `core/machine_0_11015_s2` | `cpuFast` | `267` | `-2.791 ns` | `stageNext` (`ds3_0..ds6`) and `pipeState` data fields muxed with `stagePayloadsOf next` / `restartPipe` when `cpuFast == 0` |
| `core/machine_0_11184_s0` | `clearRegisters` | `45` | `-1.536 ns` | Full-machine `clearRegisters` muxing into pipeline control/data paths |
| `core/machine_0_2373_s0` | `cpuInterruptDue` | `13` | `-1.370 ns` | `handover` (`isJust cpuInterruptDue`) muxing into `pipe'` data payloads (`pQueue`, `pFQueue`, `pDOperands`, `pFrontTarget`) |

### B. True Architectural Feedback Loops (Cycle-Priced in Section 2)

| Loop ID | Register pair (`src -> dst`) | Failing paths (`cpu96.json` / `cpu96-full.json`) | Worst slack (`cutcontrol` / `full`) | Logic levels | Architectural meaning |
|---|---|---:|---:|---:|---|
| **L1** | `E2 (ds5) -> pipeState (pBtbWrite / pRedirect)` | `38` / `32` | `-2.123 ns` / `-2.849 ns` | `10` | Branch/jump resolution in `E2`: `e2Control` + `e2BranchCompare` -> `taken` -> 32-bit `actual` mux -> 32-bit `!= e2Predicted` comparator -> `mispredicted` -> `pBtbWrite` / `pRedirect` |
| **L2** | `pipeState (pRedirect / pRedirectFront / pBtbWrite) -> pipeState (pFetchPc / pInflight / pOutstanding)` | `70` / `68` | `-1.959 ns` / `-2.587 ns` | `8` | Steering mux (`pRedirect` / `pRedirectFront`) + BTB hit (`pBtb` / `pBtbWrite` bypass) -> `predicted` (+4 adder / BTB target) -> `pFetchPc` and `issue` |
| **L3** | `pipeState (pQueue / pQueueRead / pInstructionPc) -> pipeState (pA / pQueueRead / pInstructionPc)` | `8` / `28` | `-1.281 ns` / `-2.212 ns` | `8` | RV32C halfword assembly (`headWord`/`secondWord`, `straddleTaken`, `wordDone`) -> `pInstructionPc` and `pQueueRead` |
| **L4** | `pipeState (pA) -> pipeState (pRas / pRasTop / pRedirectFront / pFrontTarget / pFQueue)` | `7` / `8` | `-1.281 ns` / `-1.529 ns` | `7` | `A`-stage `rawControl` (`rcCall`/`rcReturn`/`rcJal`) + `followed` compare -> `aSteer` (`pRedirectFront`), `aTarget` (`pFrontTarget`), RAS update, and `C.decompress32` into `pFQueue` |
| **L5** | `D / E1 / E2 / M -> D (ds3_0) / pipeState (pDBlocked / pDFresh)` | `3` / `5` | `-0.831 ns` / `-1.797 ns` | `7` | Decode hazard check (`decodeHazard`) and `M -> D` operand forwarding (`mValue -> a/b -> pDOperands`) |

### C. Pure Feed-Forward Pipeline Paths (`0` IPC cost when rebalanced across stages)

| Path ID | Register pair (`src -> dst`) | Failing paths (`cpu96.json` / `cpu96-full.json`) | Worst slack (`cutcontrol` / `full`) | Logic levels | Root cause |
|---|---|---:|---:|---:|---|
| **FF1** | `D (ds3_0) / pipeState (pDOperands) -> E1 (ds4)` | `2` / `38` | `-0.742 ns` / `-2.818 ns` | `10` | `decodeOut` in `D` runs the 20-way MMIO `decodeTarget` comparator chain on `pc` (`firstFault`) and `pc + 2` (`crossFault`) before feeding `e1Writes` / `e1FetchFault` |
| **FF2** | `E1 (ds4) -> E2 (ds5)` | `61` / `31` | `-2.269 ns` / `-1.907 ns` | `10` | `e1Out` computes `a + imm` (`aPlusImm`) and runs the 20-way `decodeTarget` chain for `plainMemory1` and `e1Action`, plus computes `compareOperands a b -> branchTakenPrepared -> taken1` just to check misaligned branch targets in `e2Action` |
| **FF3** | `E2 (ds5) -> M (ds6)` | `10` / `0` | `-1.199 ns` / — | `8` | `e2Out` ALU candidate selection (`selectedAlu`) -> `mValue` |
| **FF4** | `mulOperands -> mulProducts -> M (ds6)` | `11` / `0` | `-1.520 ns` / — | `6` | 66-bit adder tree (`productHalf`) summing the four DSP `MULT18X18` partial products at `mWait == 1` |

## 2. Cycle-Accurate Loop Pricing (`Vperf_tb` Decision-Tree Benchmark)

We compiled and ran Verilator `Vperf_tb` (`--compressed`, 64 KiB 2-way cache, 2:1 CDC bridge, real SDRAM controller model) on the full decision-tree classifier workload (`train=32 test=16 bins=4 depth=3 minLeaf=2` through `FPR EXIT 0`, verified against `dtree-oracle.py`) across `baseline` and six architectural loop-cut / forwarding variants (`output/tangnano20k/loop-pricing-20261101/loop_pricing_summary.json`):

| Variant | Loop / Path Targeted | Window Cycles | $\Delta$ Window Cycles | Unheld Cycles | $\Delta$ Unheld Cycles | Window IPC | Unheld IPC | Redirects | Hazard Cycles (`E2 plain` / `M plain`) |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| **`baseline`** | Reference `head.v` | `27,717,269` | `0.0000%` | `25,477,215` | `0.0000%` | `0.3524` | `0.3834` | `291,367` | `8,476,317` (`2,840,111` / `0`) |
| **`btb_nobypass`** | **L1/L2**: Drop same-cycle `pBtbWrite -> entry` bypass in `F` | `27,717,281` | **`+0.00004%`** (`+12`) | `25,477,231` | **`+0.00006%`** (`+16`) | `0.3524` | `0.3834` | `291,369` | `8,476,319` (`2,840,111` / `0`) |
| **`btb_2cycle`** | **L2**: 2-cycle BTB lookup (hit suppressed on Cycle 1 after redirect) | `27,746,861` | **`+0.1068%`** (`+29,592`) | `25,505,046` | **`+0.1092%`** (`+27,831`) | `0.3520` | `0.3829` | `293,502` | `8,476,053` (`2,840,111` / `0`) |
| **`front_plus1`** | **L4**: +1 cycle on `A`-stage RAS/JAL front redirect (`pRedirectFront`) | `27,911,582` | **`+0.7011%`** (`+194,313`) | `25,671,053` | **`+0.7608%`** (`+193,838`) | `0.3499` | `0.3805` | `291,367` | `8,448,808` (`2,840,111` / `0`) |
| **`redirect_plus1`** | **L1/L2**: +1 cycle on `E2` backend redirect (`issue` gated by `~pRedirectValid`) | `27,939,564` | **`+0.8020%`** (`+222,295`) | `25,698,693` | **`+0.8693%`** (`+221,478`) | `0.3496` | `0.3801` | `291,367` | `8,408,901` (`2,840,111` / `0`) |
| **`e2_forward`** | **L5**: Add `E2 -> D` ALU/LUI/AUIPC/Jump link forwarding (`e2Ready`) | `25,689,763` | **`-7.3150%`** (`-2,027,506`) | `23,401,329` | **`-8.1480%`** (`-2,075,886`) | **`0.3802`** | **`0.4174`** (`+8.87%`) | `291,367` | `5,854,847` (`0` / `0`) |
| **`no_m_forward`** | **L5**: Remove `M -> D` forwarding (require `WB` writeback) | `29,861,324` | **`+7.7354%`** (`+2,144,055`) | `27,661,234` | **`+8.5724%`** (`+2,184,019`) | `0.3271` | `0.3531` | `291,367` | `10,889,419` (`2,840,111` / `2,413,102`) |

### Key Conclusions from Loop Pricing

1. **`btb_nobypass` is essentially free (`+0.00004%`, +12 cycles in 27.7M)**: Because a branch/jump resolving in `E2` cannot re-enter `F` at the exact same PC on the very next cycle without at least a 2-cycle loop body, the combinational `pBtbWrite -> entry` bypass mux in `F` is dead weight and should be removed unconditionally.
2. **`btb_2cycle` (`+0.11%`), `front_plus1` (`+0.70%`), and `redirect_plus1` (`+0.80%`) are all <1% cycle penalties**: Moving from 72 MHz to 81 MHz provides `+12.5%` clock rate, so even if all three pipeline cuts were taken simultaneously (`~1.6%` combined cycle cost), net wall-clock throughput increases by **`+10.7%`**.
3. **`M -> D` forwarding is mandatory (`+7.74%` penalty if removed)**: Cutting `L5` by dropping `M -> D` forwarding costs `2.14M` cycles and is rejected.
4. **`E2 -> D` forwarding (`e2_forward`) saves `2.03M` cycles (`-7.32%` window cycles, `+8.87%` unheld IPC)**: Eliminates all `2,840,111` `E2 plain` hazard stalls, making a dedicated registered `e2FastResult` flop in `E2` the highest-leverage IPC upgrade once 81 MHz timing is closed.

## 3. Structural Fixes Applied to `src/SdramPipeline.hs` and `src/SimpleRisc.hs`

We applied all four zero-IPC-cost structural fixes to the Haskell Clash source (`src/SdramPipeline.hs` and `src/SimpleRisc.hs`) and generated the corresponding synthesis and observed Verilog netlists in `output/tangnano20k/structural-80mhz-20261101/`:

1. **Pre-registered `breaking` in `src/SdramPipeline.hs`**:
   - Folded `not (R.cpuInRom machine)` into the `emergency` flip-flop D input (`emergency = register False ((\rx m -> rx == Just 3 && not (R.cpuInRom m)) <$> receivedNow <*> machine)`) and set `breaking = emergency`.
   - Removes `cpuInRom` (`core/machine_0_2076_s0`, `638` failing paths at 96 MHz) from the 5,000-flop `holding` clock-enable tree and from `emergencyReset`.
2. **Stage and `pipeState` Data Payloads Decoupled from `cpuFast` and `restartPipe` (`src/SimpleRisc.hs`)**:
   - In `pipelinedCpuStepStages`, `stages` is now returned unconditionally in both the `cpuFast` and `phases` branches (when `cpuFast == False`, `loads == noStageLoad` and all stage valid bits are `False`).
   - In `pipeStepTracedWith`, `restarted` updates `pQueue`, `pFQueue`, `pDOperands`, `pFrontTarget`, and `pBtb` unconditionally from the pipeline step while resetting only the queue pointers and valid tokens (`pQueueRead = 0`, `pQueueWrite = 0`, `pFRead = 0`, `pFWrite = 0`, `pFCount = 0`, `slotCancel`).
   - Removes `cpuFast` (`267` failing paths), `clearRegisters` (`45` failing paths), and `cpuInterruptDue` (`13` failing paths) from the stage and `pipeState` data buses.
   - Drops the combinational `pBtbWrite` bypass in `F` when `cpuExternalMemory` is enabled (`btb_nobypass`).
3. **Hoisted `E2` `mispredicted` 32-Bit Comparator (`L1` Fix, `src/SimpleRisc.hs`)**:
   - Replaced `actual = if e2Refetch x then e2Pc x else if taken then target else cLink comp; mispredicted = e2Refetch x || actual /= e2Predicted x` with:
     ```haskell
     mispredicted = if taken then (e2Refetch x || target /= e2Predicted x) else e2PredictedTaken x
     ```
   - Because `e2PredictedTaken x` (`refetch1 || e1Predicted x /= link1`) is already precomputed in `E1` and registered in `E2`, the 32-bit comparator `target /= e2Predicted x` now evaluates in parallel with `taken` directly from `E2` flip-flops, and `taken` drives only a 1-bit 2:1 mux. Cuts 4 LUT/carry levels off `L1` (`-2.849 ns` / `-2.123 ns`) with **0 IPC cost**.
4. **Moved Taken-Branch Misaligned Target Check to `E2` (`FF2` Fix) and Replaced 20-Way `decodeTarget` Cascades in `D`/`E1` (`FF1`/`FF2` Fix, `src/SimpleRisc.hs`)**:
   - Removed `branchTakenPrepared funct31 (compareOperands a b)` from `e1Out`'s `action1` (`e2Action`) and checked `misalignedBranch = taken && (target .&. instructionAlignmentMask machine /= 0)` in `e2Out` using registered `e2BranchCompare` and `cTarget`. Cuts the 10-level `E1 -> E2` `FF2` path (`-2.269 ns` slack, `61` failing paths) with **0 IPC cost**.
   - Added `ramAddr` and `fetchableAddr` in `pipeStepTracedWith` so external-memory pipeline builds check `(addr .&. 0xff80_0000 == 0x8000_0000)` and `romAddress addr` directly (2 LUT4s) instead of expanding four copies of the 20-way MMIO `decodeTarget` comparator chain in `D` and `E1`.

## 4. Verification Summary

- `simple-risc-test`: **78/78 PASS** (`70` processor property/unit tests + `8` `PsramRegs` tests).
- `check_pipeline_rtl.py --compressed --simulator verilator` on `observed_zero_ipc`: **PASS** (`58,095` held clocks, 97 fills, 36 writes, 2 `fence.i` epoch assertions, 8 timer interrupts across misses, corrupt-beat and wrong-path store monitors passed).
- `check_pipeline_rtl.py --compressed --simulator verilator` on `observed_redirect`: **PASS** (`58,203` held clocks, all assertions and monitors passed).
