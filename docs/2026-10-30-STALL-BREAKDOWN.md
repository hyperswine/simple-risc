# Stall breakdown: where the classifier's cycles go

Kind: measurement infrastructure and one simulation run, 2026-10-30. No
hardware build, no change to the board image's RTL.

## Result

The frozen FP-RISC classifier commits 39,517,185 instructions in 145,460,221
measured cycles: **0.272 instructions per clock**. Cache holds are only 5.8% of
that. Most of the rest is two causes inside the core:

| Cause | Cycles | Share |
|---|---:|---:|
| Mispredicted control flow: restart cycle + front-end refill + wrong-path issues | 48,669,232 | **33.5%** |
| Decode waiting for an operand from E1 or E2 | 35,526,046 | **24.4%** |
| Useful issue (committed instructions) | 39,517,185 | 27.2% |
| Decode blocked behind a load waiting in M | 9,921,271 | 6.8% |
| Cache holds the core | 8,450,881 | 5.8% |
| Everything else (multiply waits, port conflicts, slow phases, other front-end gaps) | 3,375,606 | 2.3% |

For comparison, the 48 to 60 MHz step measured on the board is worth about 20%.
Halving either of the two leading rows is worth roughly 12-17% at the same
clock, with no I/O qualification needed.

## Full accounting

Every unheld measured cycle gets exactly one issue-slot cause, decided by the
same step function that computes the next state. The causes plus held cycles
equal the window cycle count; `run_perf.py` refuses the run otherwise.

| Cause (`ptSlot`) | Cycles | Share |
|---|---:|---:|
| cache holds the core | 8,450,881 | 5.81% |
| issued into E1 | 47,903,247 | 32.93% |
| behind a load in M | 9,921,271 | 6.82% |
| behind a multiply in M | 124,869 | 0.09% |
| behind another M wait | 0 | 0.00% |
| E2 load blocked by an M store | 512,998 | 0.35% |
| operand hazard in decode | 35,526,046 | 24.42% |
| restart cycle (redirect/handover/fence) | 5,373,238 | 3.69% |
| front end refilling after restart | 34,909,932 | 24.00% |
| front end empty, other | 2,191,590 | 1.51% |
| outside the pipeline (ROM/trap phases) | 546,149 | 0.38% |
| unclassified | 0 | 0.00% |

Derived: 47,903,247 issues minus 39,517,185 commits leaves 8,386,062
wrong-path issues. Each restart is followed by 6.5 refill cycles on average
(34,909,932 / 5,373,238), the fetch-to-decode depth through the four-clock
cache port. Redirects are 13.6% of commits (5,364,322). Fetch wanted to issue
but lost the port to a load or store in 16,564,763 cycles (non-exclusive); only
1.5% of cycles show an empty front end outside refills, so that contention is
mostly hidden behind the stalls above.

## What the leading causes are

**Operand hazards.** `decodeHazard` (`src/SimpleRisc/Decode.hs`) holds an
instruction in decode while any instruction in E1 or E2 writes one of its
sources. Forwarding only comes from the registered M stage, so a dependent
instruction directly behind its producer loses two cycles. This is deliberate:
the comment says it keeps E2's ALU result mux out of decode's forwarding path.
The bucket also includes load-use waits: the dependent of a load is counted
here while the load is still in E1 or E2, and behind a load once the load is
waiting in M.

**Mispredicts.** The 8-entry BTB and the 6.5-cycle refill make each redirect
cost about 9 cycles including wrong-path work. The cause of the redirects
(conditional branch, `jal`, `jalr` return, BTB alias) is not split out yet.

## Method

- `PipelineTrace` gains `ptSlot` (a 4-bit cause, priority order: slow phase,
  restart, issue, M wait by kind, port conflict, hazard, empty front end) and
  `ptFetchPortBlocked`. Both exist only when Clash is run with
  `-DPIPELINE_SLOT_OBSERVATIONS`. Clash carries the trace through the step's
  internal result, so unconditional fields changed the ordinary top's Verilog
  text (by about 15k lines of renamed nets) even though nothing reads them. With
  the flag, the ordinary `SdramPipeline` RTL is code-identical (comments aside)
  to committed HEAD, which is itself code-identical to the accepted BTB-only
  build.
- `SdramPipelineObserved` exports them as `observe_slot` and
  `observe_fetch_port_blocked` when the flag is set; without it, the top keeps
  the named-v1 ports, so existing RTL checks are unchanged.
- `perf_tb.v` counts them under `NAMED_SLOT_OBSERVATIONS`. A front-end bubble
  is a refill while no instruction has issued since the last restart.
- `run_perf.py --stall-breakdown` implies `--profile-cpu`, requires the new
  ports, records `profile_abi: named-v2`, checks the identity and prints the
  table. `test_run_perf.py` covers the identity and its refusals.

```sh
cabal run clash -- -isrc -hide-package simple-risc -DRISCV_COMPRESSED \
  -DPIPELINE_SLOT_OBSERVATIONS src/SdramPipelineObserved.hs --verilog \
  -fclash-clear -outputdir output/observed-slots
python3 boards/tangnano20k/sdram/run_perf.py base.bin --elf base.elf \
  --generated output/observed-slots/SdramPipelineObserved.topEntity \
  --cpu-mhz 48 --mem-mhz 48 --single-clock --line-bits 11 --ways 2 \
  --write-update 1 --stall-breakdown
```

Inputs: the frozen classifier (`base.bin` SHA-256 `f8abaa0e...`, ELF
`a6d64959...`), RV32IMC, 48/48 MHz single clock, two ways, line bits 11,
write update. All 20 counters the run shares with the accepted BTB-only receipt
(`evidence/2026-10-30-structural-variants/simulation/btb-only/perf`) are
identical, and the classifier output matches (train 124/128 digest 21562, test
61/64 digest 909572). Receipts are in
[evidence/2026-10-30-stall-breakdown](evidence/2026-10-30-stall-breakdown/).

## Limits

- Attribution is at the decode-to-E1 slot. A cycle is charged to the first
  blocking reason in priority order, not split between overlapping reasons.
- Wrong-path work is inferred as issues minus commits over the window; window
  edges make it approximate by a few instructions.
- This is one workload. FP-RISC code is call-, branch- and load-heavy; other
  programs will weight the rows differently.

## Next

1. Split the two leading rows: hazards by producer (E1 or E2, ALU or load)
   and redirects by kind (branch direction, `jal`, `jalr`/return, BTB miss).
2. Forward ALU results to E1's operand input instead of stalling decode on E1
   and E2 producers. This trades directly against the timing goal that put the
   stall there, so measure both CPI and routed timing. The rejected narrow-E2
   variant (ALU selected in E1) is the natural starting point: its result is
   registered one stage earlier.
3. Reduce redirect cost: a return-address stack and a larger BTB if the split
   shows returns and aliasing dominate, and a shorter refill path.
