# Stall split: which producers and which redirects

Kind: measurement infrastructure, two simulation runs and a trace-driven
predictor model, 2026-10-30. No hardware build, no change to the board image's
RTL. Follows [STALL-BREAKDOWN](2026-10-30-STALL-BREAKDOWN.md).

## Result

The two largest losses on the frozen classifier now have known shapes:

- **Redirects (33.5% of cycles) are mostly a predictor that cannot hold the
  workload's branches, not hard-to-predict branches.**
  - 99.5% of returns redirect.
  - A third of all redirects come from 32-bit branches and jumps that start in
    the upper half of a word. The core never installs those in the BTB.
  - A trace-driven model of the BTB matches the core to 0.06% per
    instruction. In that model:
    - an 8-deep return stack removes 21% of redirects;
    - installing straddling instructions removes another 15%;
    - 64 entries remove another 23%.
  - Together that is about 19.5% fewer cycles (1.24x). Direction counters and
    associativity add almost nothing.
- **Operand waits (24.4%) are mostly plain ALU results.** A plain result waiting
  to leave E2 costs 8.0% of cycles, which is the upper bound for E2-to-decode
  forwarding. Shifts cost 7.4% because they finish in M and cannot forward
  until they commit. Loads waiting in E1-M cost 3.6% here, plus the 6.8% "behind
  a load in M" row.
- **Every restart takes at least 7 cycles to issue again** (mean 7.51). Fetch
  never loses the memory port during a refill, so this is pipeline depth, not
  contention. Each cycle cut from that path is worth 3.7%.

| Fix (estimated separately) | Cycles saved | Speedup |
|---|---:|---:|
| 8-deep return stack | 6.9% | 1.075 |
| + install straddling branches/jumps | 11.8% cumulative | 1.133 |
| + 64-entry BTB | 19.5% cumulative | 1.242 |
| Forward plain results from E2 to decode (upper bound) | 8.0% | 1.087 |
| One cycle shorter restart-to-issue path | 3.7% | 1.038 |
| Shifts finished by E2 (upper bound, M wait only) | 2.4% | 1.025 |

The 48 to 60 MHz clock step is worth about 1.25x. The predictor work alone is
about the same size, and it needs no I/O timing qualification.

## Operand waits by producer

Decode waits on the nearest in-flight producer of one of its sources (E1
before E2 before M). The causes partition `slot_hazard` exactly.

| Producer | Cycles | Share of all cycles |
|---|---:|---:|
| plain result in E2 | 11,647,399 | 8.01% |
| plain result in E1 | 7,651,750 | 5.26% |
| shift in E2 | 3,820,314 | 2.63% |
| load in M (not yet final) | 3,618,951 | 2.49% |
| shift in M | 3,495,082 | 2.40% |
| shift in E1 | 3,388,488 | 2.33% |
| load in E2 | 994,858 | 0.68% |
| load in E1 | 575,794 | 0.40% |
| multiply (E1, E2, M) | 333,410 | 0.23% |
| **total** | **35,526,046** | **24.42%** |

"Plain" is anything E2 selects: ALU operations, LUI, AUIPC, a jump's link, CSR
reads. The committed mix over the window is:

| Instructions | Count | Share of 39.5M commits |
|---|---:|---:|
| loads | 5,326,833 | 13.5% |
| stores | 5,778,062 | 14.6% |
| shifts | 4,798,605 | 12.1% |
| multiplies | 326,909 | 0.8% |
| conditional branches | 4,636,415 | 11.7% |
| `jal` | 2,346,959 | 5.9% |
| returns | 974,539 | 2.5% |

What these mean:

- **Shifts:** each shift costs its dependents 2.23 waiting cycles on average.
  That is because shifts do their low two levels in E1 and their high three
  levels at commit, so dependents read them from the register file.
- **Loads:** each load costs 2.84 cycles. That is the "behind a load in M" row
  plus the load hazard rows, out of 5.3M loads.
- **Hot spots:** the hottest loops show the pattern directly.
  - `zero_words` (0x8000039e) runs `slli` → `add` → `sw`.
  - `log2_word` (0x800003b6) runs four `srli` → `beqz` pairs.

## Redirects by kind

Each redirect is classified when E2 resolves it. The kinds partition
`window_redirects` exactly.

| Kind | Redirects | Share |
|---|---:|---:|
| conditional branch taken, no BTB hit | 2,762,324 | 51.5% |
| `jal` without a correct BTB hit | 1,517,250 | 28.3% |
| return (`jalr x0, 0(ra or t0)`) | 970,068 | 18.1% |
| conditional branch predicted taken, not taken | 88,820 | 1.7% |
| non-control instruction hit an aliased entry | 15,906 | 0.3% |
| other `jalr` | 5,856 | 0.1% |
| straddle refetch bubble | 3,632 | 0.1% |
| branch taken, wrong predicted target | 466 | 0.0% |
| **total** | **5,364,322** | |

Each redirect costs 9.07 cycles: 1 restart cycle, 6.51 refill cycles and 1.56
wrong-path issues.

**Restart to first issue:** at least 7 cycles; 59% take exactly 7, 32% take 8,
and 9% take 9. `refill_port_blocked` is 0, so no refill cycle was spent waiting
for the memory port.

## Predictor replay

`run_perf.py --control-trace` writes each committed branch and jump as one
line: pc, expanded word, next pc, and whether that instruction redirected.
`predictor_replay.py` replays the stream with instruction sizes taken from the
image.

Its "current" model follows the core's rules:

- 8 direct-mapped entries, indexed by pc[4:2], with an 8-bit tag and a
  halfword slot bit;
- a taken branch or jump installs its target, and a mispredicted hit clears
  the entry;
- a 32-bit instruction that starts in a word's upper half is never installed.

The model gives 5,343,078 mispredicts against 5,345,127 control-instruction
redirects flagged in the hardware trace, every kind is within 0.6%, and the
per-instruction absolute differences sum to 3,173 (0.06%). The model ignores
the one-cycle install delay, which explains the remainder.

| Variant | Mispredicts | Cycles saved at 9.07 each |
|---|---:|---:|
| A: current, 8 entries | 5,343,078 | — |
| B: A + 8-deep return stack (returns not in the BTB) | 4,230,886 | 6.9% |
| C: B + straddling instructions installed | 3,456,256 | 11.8% |
| D: C at 16 entries | 3,287,447 | 12.8% |
| E: C at 32 entries | 2,977,491 | 14.8% |
| F: C at 64 entries | 2,221,318 | 19.5% |
| G: F + 2-bit direction counters | 2,119,627 | 20.1% |
| H: G at 256 entries | 1,127,155 | 26.3% |
| A at 16 entries | 5,052,807 | 1.8% |
| A at 64 entries | 3,932,918 | 8.8% |
| A as 2-way, 8 entries | 5,350,409 | 0.0% |
| A + straddling installed | 4,544,058 | 5.0% |
| A + 4-deep return stack | 4,235,535 | 6.9% |

What the replay shows:

- **Returns:** the return stack fixes them almost completely. 38 of 974,539
  returns still miss with 8 entries, and 4,687 miss with 4 entries.
- **Straddling instructions:** 2,075,055 control instructions straddle a word
  boundary across 488 sites, and 1,716,624 of those are taken. They are
  invisible to the BTB today. The single hottest is the `bne` at 0x800003a2 in
  `zero_words`: 935,943 redirects, which is 17.5% of all redirects.
- **Capacity:** with the two fixes above, capacity is what limits the BTB.
  Associativity at 8 entries and 2-bit counters change very little.
- **Caveats:** cycle savings assume each removed redirect saves its average
  9.07 cycles, and the rows are not strictly additive with the hazard fixes.
  The replay sees committed order only. A real return stack updated at fetch
  or at E2 can lag when a call and its return are in flight together.

## What this suggests, in order

1. **Return stack.** Mark call and return entries in the BTB and take a
   return's target from a small stack. It is the largest single gain (6.9%),
   with little state.
2. **Install straddling instructions.** Key their entry on the word that
   holds their last halfword, with the slot-0 meaning "the instruction ending
   here is taken". The assembler then takes the target after consuming the
   second word. This changes the C-mode assembly path, which carries fetch
   timing, so it needs routed timing as well as CPI.
3. **A larger BTB, 32-64 entries.** The entries live in flip-flops today
   (separately enabled banks). At 64 entries a LUT-RAM or BSRAM table with a
   registered read is the realistic option, and the extra read cycle must not
   land in the fetch loop.
4. **E2 forwarding into decode.** It is worth at most 8.0%. Start from the
   rejected narrow-E2 variant and judge it on CPI and routed timing together.
5. **Restart path and shifts.**
   - Each cycle removed between a redirect and the first issue is worth 3.7%.
     Candidates are skipping the F queue on a restart, or resolving `jal` in
     decode.
   - Finishing shifts in E2 removes the 2.4% "shift in M" row, and more if (4)
     lands.

Not pursued: 2-way BTB, direction counters before capacity.

## Method

- **Clash side:** `PipelineTrace` gains `ptHazard` (stage * 4 + producer kind)
  and `ptRedirectKind`. Both are only present under
  `-DPIPELINE_SLOT_OBSERVATIONS`, and `SdramPipelineObserved` exports them as
  `observe_hazard` and `observe_redirect_kind`.
  - With the flag absent, the ordinary `SdramPipeline` Verilog is
    code-identical (comments aside) to the committed HEAD.
  - The classification decodes the instruction in the stage directly, so
    `KindLoad` is matched with a case. Clash cannot compare the one-hot
    `CommitKind` with `==`.
- **Testbench (`perf_tb.v`, `NAMED_SPLIT_OBSERVATIONS`):**
  - counters for each cause and redirect kind;
  - restart-to-first-issue lengths;
  - committed instruction-mix counts;
  - the optional control trace.
  - The `ctl_branch_taken` counter treats a taken branch to pc+4 as not taken;
    the replay's count (2,932,866), which uses real sizes, is the one to use.
- **Runner:** `run_perf.py --split` (implies `--stall-breakdown`) requires the
  new ports and records `profile_abi: named-v3`.
  - It checks that hazard causes sum to `slot_hazard`, that none lacks a
    producer, and that redirect kinds sum to `window_redirects`.
  - `test_run_perf.py` covers those checks.

```sh
cabal run clash -- -isrc -hide-package simple-risc -DRISCV_COMPRESSED \
  -DPIPELINE_SLOT_OBSERVATIONS src/SdramPipelineObserved.hs --verilog \
  -fclash-clear -outputdir output/observed-split
python3 boards/tangnano20k/sdram/run_perf.py base.bin --elf base.elf \
  --generated output/observed-split/SdramPipelineObserved.topEntity \
  --cpu-mhz 48 --mem-mhz 48 --single-clock --line-bits 11 --ways 2 \
  --write-update 1 --split --control-trace control.txt
python3 boards/tangnano20k/sdram/predictor_replay.py control.txt base.bin \
  --results results.json --json predictor.json
```

**Inputs and checks:**

- **Inputs:** the frozen classifier and configuration of STALL-BREAKDOWN.
- **Counters:** all 32 counters shared with that receipt are identical.
- **Output:** the classifier output matches (train 124/128 digest 21562, test
  61/64 digest 909572).
- **Receipts:** in [evidence/2026-10-30-split](evidence/2026-10-30-split/).
  The 215 MB control trace is not committed; its SHA-256 is in
  `control-trace.sha256`, and the commands above regenerate it.

## Limits

- One workload. FP-RISC runtime code is call-, shift- and branch-heavy.
- Hazard attribution charges the nearest producer only, so removing it can
  expose a wait on an older one. The forwarding figures are upper bounds.
- Cycle savings use the average redirect cost and are estimates until a
  changed core is simulated with this same harness.
