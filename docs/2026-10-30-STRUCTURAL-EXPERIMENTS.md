# Structural experiments and acceptance criteria

Goal: obtain reproducible evidence for the processor's remaining structural
limits, then retain changes that improve correctness, useful throughput or
FPGA cost. A reported Fmax alone is not acceptance.

## Starting point

The baseline is `44fcaf0ef95d01433a299bac5a19ec20db6b9c86`: four-clock
external cache port, separately stored stage payloads, BSRAM replacement bits,
and deferred BTB writes with read bypass. The working tree was clean when
captured. This supersedes the earlier distributed-RAM MRU baseline.

The latest evidence identifies fetch hit/target/sequential-PC logic entering
register enables. Registering cache hold alone was measured worse and reverted.
Do not repeat that experiment without a different storage/handshake boundary.

The 60 MHz build's `DONE` response proves entry into the ROM finisher path;
it does not prove correct guest computation. Standalone SDRAM tests do not
establish integrated-memory or electrical timing correctness.

## Experiment sequence

| Experiment | Question | Required evidence |
|---|---|---|
| Observation contract | Can tests survive changes to Clash record layout? | Named simulation observations, no packed-state offsets; fence coverage and deliberate corrupt-input rejection |
| Fetch and BTB storage | Can fetch arithmetic terminate at data registers rather than storage enables? | Same predictions/results and workload counters where latency is unchanged; routed CE paths and resources |
| Queue/storage boundaries | Which small arrays benefit from separate storage or RAM? | Per-array read/write/collision contract; register/LUT/BSRAM cost; CPI and routed timing |
| E2 width | Can eight ALU candidates be selected before the E2 register profitably? | Full instruction differential checks, forwarding/traps, register reduction versus earlier selection delay |
| Hold/cancellation/effects | Are frozen state, tokens and external effects consistent? | Holds at varied pipeline positions; interrupt/redirect/fence/reset; no duplicate store, UART byte or retirement |
| Output isolation | Is the 60 MHz failure computation, UART, or host transport? | Memory-resident signature independent of output, ROM/readback checks, sustained and paced UART, one open host descriptor |
| End-to-end comparison | Do the changes improve FP-RISC execution? | Frozen guest hash, independent oracle, cycles/holds/fills, physical elapsed time and repeated correctness |

Run one structural change at a time. Keep rejected variants and their reports
as evidence, with production source reverted. Four in-flight entries need not
become RAM merely because the larger arrays do.

## Measurement contract

- Freeze the complete Haskell source, cache/bridge/controller RTL, guest binary
  and ELF before edits. Record revision, dirty status and SHA-256 values.
- Generate IM and IMC RTL afresh. Distinguish observation-enabled simulation
  from the ordinary synthesis top; no observation ports on the board image.
- Compare the same cache capacity/ways, CPU/SDRAM clocks, phase, tool version,
  mapping/routing settings and placement. State any deliberate variation.
- Record leading setup paths including the endpoint pin (D versus CE), logic
  and route delay, load counts, LUT functions, resource usage and hold results.
- Use the frozen classifier and independent result oracle. Changed memory or
  multiply latency requires a fresh CPI comparison, not historical counters.
- Internal STA, functional pin simulation and a physical run are separate
  evidence classes. None supplies the missing SDRAM I/O/PVT model.
- Qualify changes at 48 MHz before higher-clock experiments. Record the actual
  image and UART baud, retain the original image for restoration, and change
  FPGA SRAM only.

## Progress: first measurement milestone

The [baseline report](2026-10-30-STRUCTURAL-BASELINE.md) records the fresh data,
validation boundaries and updated experiment order. Completed locally:

- Frozen source/guest baseline and exact ordinary/observed workload comparison.
- Named simulation ports for fence/profiling observations; host-only source
  field metadata; detailed D/CE path and resource extraction with refusal tests.
- Fresh ordinary synthesis at 48 and 60 MHz; explicit separation of the real
  clock constraint from Gowin's synthesis frequency hint.
- Independent workload/signature reporter and receive-versus-readback CRC
  probes, including physical controls, restoration and functional pin simulation.
- Fixed a real unaligned-BSS startup trap discovered by those diagnostics.
- Local Haskell, RTL, formal, classifier and physical checks; CI wiring added.

The evidence changes the ordering: the older 60 MHz report exposes hazard and
exception-data D paths, while fresh builds expose mode/enable routing. The
60 MHz zero-pattern readback failure also occurs before guest execution and is
not established to be a UART fault. Obtain raw readback/an independent checksum,
then compare mode/storage ownership, hazard selection and E2 data variants at
fixed settings. Fetch/BTB and queue changes remain hypotheses to evaluate.

## Progress: controlled structural variants

The [variant report](2026-10-30-STRUCTURAL-VARIANTS.md) and its evidence bundle
extend the first milestone:

- Separate physical BTB banks preserve every frozen classifier counter and
  pass fresh IM/IMC RTL, abstract refinement checks and physical 48/60 MHz
  instruction, output and classifier checks. The source retains this change.
- At fixed 48 MHz settings, reported Fmax rises from 73.066 to 80.779 MHz,
  with 273 more logic cells. At fixed experimental 60 MHz / phase 112.5°,
  it rises from 66.468 to 71.620 MHz, with 100 fewer logic cells. The leading
  60 MHz paths move from mostly CE endpoints to fetch-PC D endpoints.
- E2 narrowing is evaluated and reverted: 163 fewer routed registers but a
  5.33% Fmax regression. Its source and negative result are retained.
- Raw words, host CRC, XOR and reordered cold probes isolate a reproduced
  60 MHz failure to cold-fill data capture. A phase-only change to 112.5°
  passes three probe orders and the frozen classifier with the original CPU.
  A functional delayed-read model reproduces the direction of this change.
- The board is restored to the original 54 MHz image and twelve final upload
  probes pass. The supported 48 MHz preset is unchanged.

## Final measurement milestone: queue and effect contracts

The [queue/effect report](2026-10-30-QUEUE-AND-EFFECT-CONTRACTS.md) completes
the remaining measurement categories:

- Defined per-array ownership/read/write/collision/cancellation contracts for
  raw, expanded and in-flight fetch storage, with packed and directly mapped
  register inventories. The raw queue already has four 66-flop bank enables.
- Implemented and evaluated a separate expanded-queue bank variant. Every
  frozen classifier metric matches, but reported Fmax falls 8.44% at fixed
  48 MHz settings, with 223 more logic cells and no register saving. Reverted
  the production change; preserved source, RTL, reports and its executable
  test-only ownership contract.
- Added eight uniquely owned stores/retirements with nonzero hold coverage,
  backend-acceptance counts and a cancelled younger store. Identical duplicate
  and wrong-path guest mutations must fail specifically. Existing UART,
  fence/refetch, timer interrupt and Ctrl-C/restart checks remain active.
- Final local checks pass: 68 processor and 8 support properties, 29 Maude
  searches, fresh IM/IMC and CDC RTL, positive/negative effect controls, the
  Icarus CI path, and independent frozen-workload oracle/counter comparison.

The evidence-gathering goal is complete locally: named observations, controlled
fetch/BTB and queue storage experiments, E2-width evaluation, explicit ownership
contracts, 60 MHz failure isolation and matched workload/resource/timing
comparisons now have reproducible receipts. Retained changes are the observation
and diagnostic infrastructure, startup fix, BTB banks and validation coverage;
both timing-regressing storage variants are preserved as negative results.

The next implementation priority is the measured fetch-PC/BTB-selection/next-PC
D cone, followed by placement sensitivity and independently bounded SDRAM I/O
timing. These are follow-up optimizations/qualification work, not claims made
by this measurement programme. Hosted CI and full SDRAM I/O/PVT qualification
remain unestablished; the supported preset stays at 48 MHz.
