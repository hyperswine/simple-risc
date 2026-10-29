# Structural baseline: what the measurements actually distinguish

Kind: measurement infrastructure, a startup fix, functional regressions and
physical diagnostics. This is the first milestone of the
[structural experiment goal](2026-10-30-STRUCTURAL-EXPERIMENTS.md), not completion
of the processor restructures.

## Findings

1. There is no single persistent critical cone. The older 60 MHz mapping's
   leading 25 paths all terminate at D pins. Fresh ordinary builds expose CE
   paths instead. Detailed paths, synthesis settings and source attribution
   must accompany every timing claim.
2. A `DONE`-only response can mean the program trapped before `main`. The SDRAM
   C linker script allowed an unaligned BSS start; this is fixed and tested.
3. Both tested 60 MHz images accept the receive CRC of longer zero payloads,
   then return an incorrect, repeatable memory-readback CRC. Ones and sequence
   patterns pass those cases. A corresponding functional pin-model test passes.
   The physical cause is still unresolved, so 60 MHz remains unacceptable.
4. Named simulation observations preserve the frozen classifier's output and
   every measured cache/cycle counter exactly. They remove the testbench's
   dependency on packed `Machine`/`Pipe` offsets.

## Fixed inputs and observation contract

The captured pre-change revision is
`44fcaf0ef95d01433a299bac5a19ec20db6b9c86`, with a clean working tree. Source,
cache/bridge/controller RTL and the guest were frozen before edits under
`output/tangnano20k/structural-20261030`.

The guest binary is the previous small FP-RISC classifier, SHA-256
`f8abaa0ed11ef3e2576f4ccceccf33948982557c05c17927b15e9e62e4c9a9af`.
It has a 72 MHz timer constant. Current simulations use 48/48 MHz, two ways,
`LINE_BITS=11`, 64 KiB capacity and write-update. No cycle difference here is
attributed solely to the earlier change from a three- to four-clock cache port;
that would require another controlled pair.

`SdramPipelineObserved` is a simulation-only top. It exports commit word/PC,
next PC, fetch issue/PC, pipeline emptiness and execute redirect as named ports.
Those decisions come from the same step function that produces the next state;
there is no second behavioral pipeline implementation. The ordinary
`SdramPipeline` top discards the observations and has its original board ports.
Use only that ordinary top for hardware resource and timing measurements.

The FENCE.I monitor no longer references generated internal names or record bit
slices. Current performance profiling uses the same named ports. Historical
2026-10-28 profiling is an explicitly selected, checked legacy ABI; the matrix
runner selects it for old experiment receipts. Counter ABIs must match across
a controlled matrix.

`pipeline-layout` is a host-only metadata executable. It uses Haskell Generic
field metadata and the source's one-hot `CommitKind` representation. The
analysis tool requires explicit register ownership bindings and checks widths
against the selected generated RTL before attributing bits. This metadata is
for analysis; functional assertions do not consume it.

## Endpoint evidence changes the diagnosis

Gowin V1.9.12.04; GW2AR-LV18QN88C8/I7; two-way 64 KiB cache; phase 135 degrees;
placement 2; mapping 3; routing 1; route max-fanout 8:

| Build | Actual / synthesis target MHz | Logic | Registers | Fmax MHz | Setup slack ns | Leading endpoint pins |
|---|---|---:|---:|---:|---:|---|
| Existing `btbdef-60-rvc` | 60 / 66 | 14,400 | 5,308 | 70.901 | +2.563 | 25 D |
| Fresh ordinary top | 48 / 48 | 14,153 | 5,307 | 73.066 | +7.147 | 24 CE, 1 D |
| Fresh ordinary top | 60 / 60 | 14,404 | 5,309 | 66.468 | +1.622 | 21 CE, 4 D |

All three reports have zero setup and hold violating endpoints under their
supplied constraints. The fresh builds use 38/46 BSRAM and 3.5/24 DSP. Their
ordinary CPU RTL SHA-256 is
`55c53bb62a45dd2b6ce170ff51577c968ade79e27ef664ba0d3c632693f11c3e`.

These rows are **not** an area/speed comparison of an architectural
optimization. The old row has a different synthesis target hint; the observation
refactor also changes generated structure/names. The original temporary input
Verilog for the older build is unavailable. The new 48 and 60 MHz rows use the
same ordinary generated CPU but deliberately change clock/controller constraints.
A future candidate must be compared against a fresh control with identical
target hints, tool settings and other inputs.

The older 60 MHz report's first path has 10 logic levels, 3.918 ns cell delay,
9.920 ns routing and 0.232 ns clock-to-Q. Its maximum reported data-path fanout
is 33, and its endpoint is explicitly `/D`. Width-checked source attribution
maps it to `MemoryStage.mStore -> Pipe.pDBlocked`. Following paths map
`ExecuteOne.e1B[2] -> ExecuteTwo.e2Action` payload bits and contain an address
carry chain and selection. These are hazard and exception-data paths, rather
than evidence that the residual wall is necessarily fetch/BTB enable logic.

That attribution uses a fresh generation of the captured source and explicit
ownership bindings for the older netlist's registers. Matching widths and source
fields support the interpretation; they are not a formal equivalence proof of
the missing original synthesis input.

The fresh 48 MHz worst path ends at CE after four logic levels: 11.923 ns
routing, 1.496 ns cell delay and maximum reported data fanout 285. The fresh
60 MHz worst path also ends at CE after four levels, with 13.582 ns routing,
1.196 ns cell delay and maximum reported data fanout 1,000. Its source record
bit 5806 corresponds to `cpuFast` in the generated assignments. Wide mode
ownership remains a candidate; it cannot be dismissed from the older D-pin
report alone.

The analyzer now records each physical endpoint pin, every data-path hop,
cell/route/C2Q totals, mapped cell ports/LUT INITs and synthesized CE connections.
Synthesized CE connection counts and routed fanout counts are different metrics.

## A startup trap was masquerading as missing output

The first signature reporter returned only `DONE` on the existing 54 MHz image.
Its ELF defined `_bss_start = 0x80000167`, `_bss_end = 0x80000168`. Startup
executes `sw zero,0(t0)` while clearing BSS, so it traps on the unaligned first
store before calling `main`. The ROM then prints `DONE`.

The SDRAM linker script aligned the global location counter before `.bss`, but
not the start inside the RAM output section. It now aligns `_bss_start` inside
that section and asserts word-aligned bounds. The BRAM C linker script already
did this. A regression links a one-byte `.rodata` fixture with empty BSS and
checks the actual ELF bounds. A native test executes the actual diagnostic C
and reporter against an independent Python digest/output oracle.

After the fix, all nine 54 MHz workload runs pass: silent computation, 4,096-byte
burst output and equally sized paced output, repeated three times. Each run is
followed by a separately uploaded reporter that reads a retained high-address
SDRAM signature. The 128 KiB data workload produces digest `89c8e2fb`.
The reporter still uses the UART: absent reporter output would be inconclusive,
not proof of incorrect computation.

This establishes one concrete startup failure. It does not establish the cause
of every historical `DONE`-only result at 60 MHz.

## Physical 60 MHz failure: receive versus readback

The diagnostic keeps one UART file descriptor open, verifies board identity and
uses the real `clock / 868` baud (69,124 at 60 MHz). Its upload-only mode never
executes the uploaded bytes. For each pattern it checks the ROM's received
payload CRC, then requests three CRCs computed by reading memory.

For the longer zero payloads, all three readback CRCs are identical within a
build but incorrect:

| Zero words | Expected CRC | Existing 60 MHz image | Fresh 60 MHz image |
|---:|---|---|---|
| 16 | `758d6336` | `686ad78a` | `3d564921` |
| 128 | `b2aa7578` | `f81fc09a` | `16acb8e3` |
| 512 | `f1e8ba9e` | `f1da2d69` | `aa195cc6` |

The corresponding ones and sequence payloads pass receive and readback CRC at
these lengths. The one-word cases also expose protocol errors at 60 MHz
(`DONEERR HDR`, and in the final comparison `ERR TMO`); they are retained
separately and are not described as successful uploads with bad readback.
All twelve probes pass at 54 MHz, both before and after restoring that image.

This is stronger evidence than lost guest output, but it does **not** prove
corruption of the SDRAM array itself. The failure could involve store/read
integration, physical timing or the CPU's readback/CRC computation. An
independent raw readback or alternative checksum is still needed to distinguish
those possibilities. Standalone SDRAM success does not clear the integration.

The 512-zero-word case passes generated RV32IMC RTL with the actual controller,
the 60 MHz stamped ROM, a functional SDRAM pin model, 135-degree phase, 6 ns
read access delay and the actual 868-clock UART divider. The test checks three
CRC replies **and backing RAM**, with no guest execution. This does not model
all SDRAM I/O bounds, PVT, FPGA routing delay or metastability. It fails to
reproduce the physical fault in that functional model; it does not qualify
the interface electrically.

## Functional and physical acceptance of the measurement changes

- `cabal build all`; Haskell tests: 66 processor properties and eight other
  properties pass.
- Existing cache checks: 18; MRU checks: five; formal searches: 19; bridge and
  instruction-fence positive/negative checks pass. The unchanged abstract
  models do not prove the synthesized implementation or physical timing.
- Fresh observed IM and IMC RTL guests pass, including fences, masked stores,
  traps, timer interrupts across misses, counters and Ctrl-C. A corrupted
  backend beat is rejected. A full-capacity one-way IMC case also crosses
  clock domains.
- The actual ROM's framed upload, CRC readback and guarded execution pass.
  Non-executable zero-pattern tests for IM and IMC are added to CI. Concurrent
  callers now isolate the fence unit-test artifacts; the former shared output
  directory could race and produce an unrunnable simulator file.
- Five parser/attribution guard tests, three benchmark-control tests and two
  diagnostic/startup tests pass locally. Hosted CI has not been observed here.
- The frozen classifier independently matches 23 nodes, depth five, training
  124/128 with digest 21562, test 61/64 with digest 909572 and the reference root.
  Ordinary and observed simulations match every cache/cycle counter, including
  145,460,221 window cycles, 8,450,881 held cycles and 260,094 refills.
- The new ordinary 48 MHz image passes all nine signature/output workloads.
  One physical frozen-classifier run passes the independent oracle after a
  CRC-verified upload. Its guest time is 2,031,356 us; applying the frozen
  72/48 timer correction gives 3,047,034 us. This is one acceptance run, not
  endurance or a claimed speedup.

The pre-task 54 MHz image was restored after the experiments and all twelve
upload/readback probes passed again. Its SHA-256 is
`f01fdf0bb48c3f5842cf8f8ad0d7d24bc1a746c9959993089e26a4661e207038`.
Only FPGA SRAM was programmed; flash and SD were unchanged.

## Next controlled experiments

1. Obtain raw memory readback or a second independent checksum for the 60 MHz
   zero-payload failure before treating output loss as a UART-only problem.
2. Compare explicit mode/storage ownership boundaries at fixed synthesis
   settings, because the fresh ordinary build exposes `cpuFast`/CE routing.
3. Compare producer conflicts before selecting next-stage payloads, targeting
   the measured store-to-decode-hazard path without changing stall semantics.
4. Separate E2 exception classification from its wide fault-value data, and
   evaluate earlier ALU selection as another independent variant. The former
   targets the measured address-to-action path; the latter tests area versus
   earlier combinational selection.
5. Evaluate fetch/BTB and queue storage separation using the same contracts.
   Their value is a hypothesis to measure, not a conclusion from an old path.

Keep each latency change separate, rerun the frozen workload, preserve negative
results, and measure current D/CE paths before choosing the following change.

## Evidence

The [evidence bundle](evidence/2026-10-30-structural/README.md) contains the source
snapshots, generated RTL, timing/utilization/netlist data, run receipts,
classifier comparison, startup symbols and physical diagnostics with hashes.
