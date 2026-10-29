# Independent timing review

Kind: review of existing timing evidence, 2026-10-28, written alongside
[CONTROL-FANOUT-AND-AREA](2026-10-28-CONTROL-FANOUT-AND-AREA.md). No Gowin
synthesis or placement was run for this page; every timing number below is
read from reports already committed under `evidence/`. Source-to-net mapping
is either taken from that page's netlist reconstruction (marked *verified
there*) or is this review's inference (marked *inferred*).

## Question

The SDRAM pipeline closes between 48 and 72 MHz. Is the limit long routes
through heavily loaded control signals?

## Answer

Largely yes, but the limit belongs to the **SDRAM/cache integration of the
pipelined core**, not to the core in isolation. The BRAM-only core closed
117 MHz and passed the board at that clock
([MEMORY-PORT](2026-10-12-TANGNANO20K-MEMORY-PORT.md)); the pipeline reached
78-96 MHz in BRAM builds ([PIPELINE](2026-10-12-TANGNANO20K-PIPELINE.md)).
The SDRAM system adds the cache, a 5,000-plus-register `Machine`, three DSPs
and 37 BSRAMs at 77-95% logic utilization, so every control net that joins
the pipeline to the cache, the DSPs or a remote payload bank pays for
cross-die routing.

Gowin's "Actual Fmax" is only meaningful against the constraint it was
built for: with `-opt_goal timing` the placer stops improving once the target
is met. The 48 MHz preset's 55.269 MHz and the 72/54 MHz build's 72.040 MHz
(+0.008 ns) are "just met" results, not ceilings. Earlier pages record
10-15 MHz placement-mode swings for the same source.

## What the committed reports show (verified from the reports)

`evidence/2026-10-21-fprisc-48/timing.tr`, 48 MHz preset, worst path
(slack +2.740 ns at 20.833 ns):

```text
core/machine_0_2589_s1/Q            tC2Q 0.232   fanout 16
 -> machine_0_5691_s6     route 3.057  LUT 0.555  fanout 53
 -> machine_0_4685_s4     route 3.211  LUT 0.371  fanout 543
 -> c$case_alt_389_3819_s3 route 2.711 LUT 0.517  fanout 153  (R50C45)
 -> c$case_alt_389_3923_s2 route 7.034 LUT 0.371              (R6C30)
 -> machine_0_3855_s1/D
5 logic levels: cells 1.814 ns (10.0%), routing 16.012 ns (88.7%)
```

All 25 reported setup paths share that launch register and the 53- and
543-load nets, then end either in one ~100-bit block of state or, through a
546-load net, at the multiplier inputs `c$app_arg_61_0_s/A,B`. Several
top-ten fanout nets carry 5-7 ns of routing on a single net.

The newer MRU build (`evidence/2026-10-28-control-area/mru-ram/sdram_test.tr`)
moves the worst path into the cache (`core/request_66` to
`cache/entry_mru`, as CONTROL-FANOUT-AND-AREA describes), but the next core
paths keep the same shape:

| Path | Start | Chain (fanout) | End | Slack at 48 MHz |
|---|---|---|---|---:|
| 2-5, 16, 22 | `machine_0_2034` (`cpuInterruptDue` valid, *verified there*) | 48 -> 128 -> 411 -> **546** | MULT18X18 `B[*]` | +1.66 ns |
| 6-25 (CE endpoints) | `machine_0_3696` (pipeline state) | 57 -> 51 -> 66 -> carry chain | pipeline register **CE** pins | +2.03 ns |
| 11, 19, 25 | `machine_0_2034` | same as first row | pipeline payload `D` | +2.37 ns |

The archived netlist (`mru-ram/sdram_test.vg.gz`) shows every multiplier
mapped as `MULT18X18` with `AREG=1`, `BREG=1` and `OUT_REG=0`. Synthesis has
pulled the E2 operand payload registers (`e2A`, `e2B`) into the DSP input
registers, so the E1-to-E2 payload select (the 546-load net) ends on DSP
input pins, which have a large setup requirement and fixed die locations.

In the 72/54 MHz integration build
(`evidence/2026-10-19-integration/timing-summary.txt`, summary only) the
worst path is the cache read return `cache/read_bank_*` to `cpu_rdata_*`,
followed by the same `machine` to payload/DSP-input pattern and a stage CE.

## Correction of this review's first draft

An earlier private draft assumed that the cache hold was a next-state mux in
front of the whole `Machine`. CONTROL-FANOUT-AND-AREA's LUT reconstruction
shows that the broad net `machine_0_50_9` is a **clock enable**,
`advance || breaking`, with 10.5 ns of slack at 48 MHz. It is large, but it
is not on the critical paths, and the semantics it protects (Ctrl-C and
counters during a hold) mean it should not simply be registered a cycle
earlier. The mapping of `machine_0_2589`/`2598` to `pM.mAction` and of
`machine_0_0[5492]` to `cpuFast` is also that page's, not this one's.

## Source structure behind those paths (inferred)

1. **Stage payloads share their next-state mux with cancellation.** In
   `pipeStepDecodedWith` the stages D, E1, E2 and M were `Maybe` values. The
   final machine was `if handover then handed else ... pipe'`, and `pipe'`
   itself chose between `restartPipe` (handover, FENCE.I), the redirect
   branch and the normal branch. Every payload bit's next state therefore
   depended on `handover` (from `pM.mAction` and `cpuInterruptDue`), on
   `pRedirect` and on the advance decisions. That is the 400-550-load
   select network in both reports.
2. **The multiply operands sit behind that network.** `mProducts` was
   computed from `e2A`/`e2B` on the E2-to-M edge, so the DSP input registers
   were the E2 payload and inherited its select.
3. **The cache read return is a wide mux on raw BSRAM outputs.** In
   `pipeline_cache.v` the 32 banks x 2 ways of 512 x 32 BSRAM are read
   synchronously and selected by `read_bank`/`hit_way1`, then pass the
   held/ROM selection and the store/fill forwarding into `cpu_rdata` in the
   same clock.
4. **Branch resolution drives stage enables.** The CE endpoints of the
   second row pass a 32-bit compare (`actual /= e2Predicted`) into the
   redirect and the younger stages' enables.

## Recommendations, ranked

| Rank | Change | Expected effect | Effort | Status |
|---:|---|---|---|---|
| 1 | Separate each stage's validity token from its payload; load payload only by the stage's own advance decision | Removes handover/redirect from payload D-inputs, so payload uses CE; targets the 546/543-load selects | Medium | Implemented on `timing/stage-enables`, not yet timed |
| 2 | Feed the DSPs from free-running operand/product registers outside `Machine` | Removes the DSP-input endpoints from the select network; lets Gowin use `AREG/BREG/OUT_REG` without CE | Low, +2 cycles per pipelined multiply | Implemented on `timing/stage-enables`, not yet timed |
| 3 | Register the cache's hold earlier / skid buffer | Only after 1; the broad enable is not critical today | High | Not attempted (semantics per CONTROL-FANOUT-AND-AREA) |
| 4 | Register the cache read return (BSRAM output register or split bank select) | Targets the 72 MHz worst path | Low for the reduced form; medium-high for a full output register (changes the three-clock port) | Reduced form implemented on `timing/stage-enables`: registered one-hot bank select and AND-OR return, no added latency. Full form implemented 2026-10-29 for external-memory images only ([FOUR-CYCLE-PORT](2026-10-29-SDRAM-PIPELINE-FOUR-CYCLE-PORT.md)); not yet timed |
| 5 | Floorplan, placement sweeps at an over-constrained target, `max_fanout` after 1 | Recovers placement noise | Low | Tooling added 2026-10-29: `SDRAM_TARGET_MHZ`, `SDRAM_REGION_CST`, `sweep_place.py`. Not yet run |

A full output register for item 4 adds a clock to the cache's CPU port. The
CPU hard-codes that latency (`pInflight`, load `mWait`, the four-entry fetch
queue and `pOutstanding < 4`), and the BRAM image shares the same pipeline.
[The 2026-10-29 change](2026-10-29-SDRAM-PIPELINE-FOUR-CYCLE-PORT.md) therefore
makes the extra clock conditional on `cpuExternalMemory`: external images get a
four-entry in-flight pipeline and `mWait = 3`, while the BRAM image and the
Haskell model keep the three-clock port unchanged. The store and fill
forwarding windows (`last_write`, `fill_forward`) still assume the same
lookup stages, and the write-update store path still merges into the
old-timing word. Timing and CPI measurement is still outstanding.

## What remains unverified

- No synthesis, placement or STA was run for this review or for the
  implementation branch. Timing gains are expected, not measured.
- Net-to-source mappings not taken from CONTROL-FANOUT-AND-AREA are inferred
  from the generated structure and path shapes.
- The 72/54 MHz build's per-hop data is not committed.
- SDRAM I/O timing is still unconstrained, so a board failure above the
  internal Fmax may be I/O rather than core timing.
