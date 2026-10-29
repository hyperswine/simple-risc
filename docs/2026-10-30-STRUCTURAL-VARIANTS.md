# Structural variants: BTB storage, E2 width and 60 MHz read capture

This records the second checkpoint. The later
[queue/effect report](2026-10-30-QUEUE-AND-EFFECT-CONTRACTS.md) completes the
measurement programme; active/pending status below describes this checkpoint.

The separate BTB banks are retained in the working source. They preserve the
frozen workload's counters and improve routed timing at both controlled clock
settings. Selecting the ALU result before E2 is rejected: its modest resource
saving costs timing. The earlier 60 MHz output failure has been narrowed to
cold-fill data capture, with a phase-only physical control that passes. These
are measured steps toward the [structural goal](2026-10-30-STRUCTURAL-EXPERIMENTS.md),
which remains active.

The [evidence bundle](evidence/2026-10-30-structural-variants/README.md) retains
source variants, generated RTL, timing/netlist reports, negative controls,
physical logs and hashes. This report extends the
[first baseline milestone](2026-10-30-STRUCTURAL-BASELINE.md); that bundle's
source hashes describe its historical checkpoint, not this later checkout.

## Controlled comparisons

The source baseline is `44fcaf0ef95d01433a299bac5a19ec20db6b9c86`, followed by
the first milestone's named observations and startup fix. `control.json` and
the control source archive identify the exact pre-variant working source.
The original ordinary CPU RTL has SHA-256
`55c53bb62a45dd2b6ce170ff51577c968ade79e27ef664ba0d3c632693f11c3e`.
Only ordinary RTL is used for hardware builds; named observation RTL is used
for simulation. All variants use RV32IMC, two cache ways, line bits 11, write
update, CPU clock equal to memory clock, place 2, route 1, map 3 and route
max-fanout 8. The synthesis frequency hint equals the actual constraint.

| 48 MHz / phase 135° variant | Logic | Registers | CLS | Reported Fmax, MHz | Setup slack, ns |
|---|---:|---:|---:|---:|---:|
| Original storage, wide E2 | 14,153 | 5,307 | 8,474 | 73.066 | +7.147 |
| Narrow E2 only, rejected | 14,067 | 5,144 | 8,445 | 69.169 | +6.376 |
| Separate BTB only, retained | 14,426 | 5,308 | 8,508 | 80.779 | +8.454 |

The 48 MHz control and E2/BTB builds use the normal ROM. The separate 60 MHz
pair below uses the same diagnostic ROM and phase 112.5°. All rows consume
38 BSRAM and 3.5 DSP units. Setup and hold endpoint violations are zero in
these routed builds. Reported Fmax is specific to each placement and clock
constraint; the 48 MHz result does not establish operation at 80 MHz.

| 60 MHz / phase 112.5° variant | Logic | Registers | CLS | Reported Fmax, MHz | Setup slack, ns |
|---|---:|---:|---:|---:|---:|
| Original storage, wide E2 | 14,404 | 5,309 | 8,547 | 66.468 | +1.622 |
| Separate BTB only | 14,304 | 5,308 | 8,441 | 71.620 | +2.704 |

These are single controlled routes, not a placement-seed distribution. The
BTB change raises 48 MHz logic usage by 273 (1.93%) and CLS by 34, while the
60 MHz route uses 100 fewer logic cells and 106 fewer CLS. Its timing benefit
is consistent across the two constraints; a universal area reduction is not
established.

## BTB storage and its hold contract

`SdramPipeline.btbStorage` holds eight independently enabled register banks.
The write index and entry come directly from the registered `pBtbWrite`.
The physical banks may install that entry on every clock, including repeated
memory holds. The logical pipe's table mirror is stripped before registering
and injected from the banks when assembling the running machine.

This freedom relies on a precise invariant: every predictor read applies the
current pending-write bypass. Repeating a pending installation is idempotent.
Before the pending register changes, its old write has reached physical
storage. Thus effective reads equal those of the reference table even when
logical CPU time is stopped. Reset clears both the banks and pending token.
Stage payloads retain their existing hold enables; the BTB proof does not
authorize free-running instruction payload registers.

The new Haskell property samples the actual bank registers over 200 random
write, invalidate, hold and reset sequences, using the production synchronous
`XilinxSystem` reset domain. All 67 processor and 8 support properties pass.
The initial property used asynchronous `System` reset and exposed a harness
domain mismatch; the final property explicitly checks the production reset
kind. The implementation did not change to accommodate that harness error.

`formal/btb_storage.maude` explores two banks and three abstract entries. Its
complete safety search passes; removing bypass or installation produces a
counterexample. A real hold witness is reachable, and removing physical hold
installation makes that witness unreachable. All 24 searches across the five
models pass. This is an abstract refinement check, not a synthesized RTL proof.

Fresh IM and IMC RTL execute the instruction/fence/loader checks, including
deliberately corrupt input rejection. The IMC one-way, line-bits-12 CDC case
also passes. Diagnostic raw readback passes in both ISA configurations.

At 60 MHz the original control's leading 25 reported setup endpoints contain
21 CE and 4 D paths. Its worst path has four logic levels, 1.196 ns of cell
delay and 13.582 ns of routing, including a 1,000-load source. After BTB
separation all 25 leading endpoints are D. The worst path starts at fetch-PC
bit 3 and ends at bit 29, with ten levels, 4.292 ns cell and 9.403 ns routing.
At 48 MHz the attributed worst path similarly runs from `pFetchPc[3]` to
`pFetchPc[16]`, with 4.007 ns cell and 8.105 ns route delay. The mapped path
passes through BTB selection/bypass and the next-PC cone. This is concrete
evidence for the next fetch experiment; it does not show that all global
enable pressure has disappeared.

## E2 narrowing: useful negative result

The rejected variant selects the normal ALU result in E1, replacing eight
32-bit candidates and compare state in E2 with `Maybe Word32`. Packed E2
width falls from 798 to 570 bits. Fresh Haskell and IM/IMC RTL checks pass,
and every frozen classifier metric is identical to the control.

The routed saving is 163 registers, 86 logic cells and 29 CLS. Reported Fmax
falls 5.33%. Register capacity is not the limiting resource, so this tradeoff
is rejected as the default. The original wide E2 is restored. Its separate
source/RTL/reports are retained, along with a combined narrow-E2/BTB functional
run; the combined variant has no routed or physical acceptance claim.

## Isolating the 60 MHz failure

The diagnostic-only ROM macro `ROM_DIAGNOSTIC_READBACK` adds command `D` to
dump the last accepted image's RAM words. It is bounded by the existing upload
length and advertised only in diagnostic capabilities. The host independently
checks exact words, a CRC over the dumped bytes, ROM CRC readback and XOR.
The normal ROM code compiles byte-for-byte identically to its original
508-word payload. The isolated diagnostic ROM occupies 1,936 of the available
2,032 code bytes. The supported `fprisc-48` preset rejects ROM overrides.

With the original CPU and phase 135°, a physical 60 MHz cold load receives
the upload correctly but returns wrong RAM data. For 16 zero words, word 12
is observed as `0x0000f000`; larger first-touch regions show a repeated
four-word pattern. The host CRC of the raw dump agrees with the ROM's CRC
of the same wrong data. This rules out a fault confined to the CRC routine.
Changing probe order from zero-first to sequence-first moves the failure to
the first sequence data; later zeros pass. The failure follows cold fills and
newly touched lines, rather than zero data itself. Observation is through the
CPU/cache, so this does not prove that stored SDRAM array bits were wrong.

Changing only the pin clock phase to 112.5° makes all twelve raw/CRC/XOR
probes pass at 60 MHz. Two further cold SRAM loads with zero-first and
ones-first orders also pass, as do three frozen classifier runs with the
original CPU. The phase-only builds have identical internal timing/resource
results. The first one-word protocol failures also disappear with this phase.
Together these controls support read-capture margin as the leading cause of
this reproduced failure.

A functional pin-model experiment at 60 MHz with an injected 11 ns read
access delay fails specifically at the SDRAM capture-word assertion with
phase 135°, and passes with exact phase 112.5°. The 11 ns delay is an
experimental model setting, not a measured part specification. Functional
pin simulation and internal STA do not supply the missing flight-time,
I/O-delay and voltage/temperature bounds. These results do not qualify an
arbitrary higher frequency or resolve all earlier CPU/memory clock pairs.

## Physical and workload acceptance

The separate-BTB ordinary images pass at both 48 MHz / 135° and experimental
60 MHz / 112.5°:

- 38,400 RV32I and 30,720 RV32M differential checks per clock setting.
- C arithmetic, echo, Ctrl-C, clear/reload and memory stress checks.
- Compressed straddles, links, traps, `mret`, fences and boundary checks.
- Memory-resident signature and silent/burst/paced output diagnostics.
- Three CRC-verified frozen classifier uploads and independent result-oracle checks.

The 48 MHz output modes are repeated three times each; the 60 MHz output
modes run once each, following twelve raw probes. All candidate images were
loaded into FPGA SRAM only. Each orchestration restores the original 54 MHz
image, SHA-256
`f01fdf0bb48c3f5842cf8f8ad0d7d24bc1a746c9959993089e26a4661e207038`,
and verifies twelve upload probes after restoration. The final restore passes.

The frozen guest SHA-256 is
`f8abaa0ed11ef3e2576f4ccceccf33948982557c05c17927b15e9e62e4c9a9af`.
For E2-only, BTB-only and the combined functional variant, all simulation
metrics match the control exactly: 145,460,221 measured-window cycles,
8,450,881 held cycles, 260,094 fills, 39,517,185 pipeline commits and
5,364,322 redirects. There is no same-clock IPC improvement.

| Physical BTB clock | Guest timer readings, microseconds | Clock-corrected duration |
|---|---|---|
| 48 MHz | 2,031,360 / 2,031,361 / 2,031,359 | 3.0470385–3.0470415 s |
| 60 MHz | 2,031,152 / 2,031,151 / 2,031,152 | 2.4373812–2.4373824 s |

The frozen binary assumes a 72 MHz timer, so correction is reading × 72 / actual
MHz. The approximately 20% duration reduction comes from the higher clock,
not fewer pipeline cycles. The original CPU also passes this classifier at
60 MHz after the phase change; BTB separation is not credited with fixing
the memory failure.

## Remaining work

The supported preset remains 48 MHz. Hosted CI has not run for these local
changes. CI now includes fresh observed RTL for both ISAs, diagnostic raw
readback, native normal/diagnostic ROM checks and the new formal searches.
The goal remains active for these next experiments:

1. Define queue read/write/collision and cancellation contracts before moving
   raw/fetched arrays outside `Pipe`. Evaluate the two-entry expanded queue
   separately from the four-entry raw queue and in-flight metadata.
2. Break the measured fetch-PC/BTB-selection/next-PC D cone, with explicit
   prediction latency and redirect recovery accounting.
3. Expand the hold/effect checks across stores, UART, retirement, redirects,
   fence, interrupts and reset. The earlier stage-payload hold requirement
   remains binding.
4. Compare any retained changes against the frozen control with the same
   physical, routed and workload contracts. Preserve negative results.
