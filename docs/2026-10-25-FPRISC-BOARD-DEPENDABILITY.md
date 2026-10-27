# A dependable FP-RISC development board

Kind: prioritized roadmap and acceptance criteria. Applies to SimpleRisc on
the Tang Nano 20K and the sibling FP-RISC runtime/tooling, reviewed 2026-10-25.
The items below are proposed work, not completed validation claims.

## Baseline and objective

Keep `fprisc-48` as the development baseline: RV32IMC, CPU/SDRAM 48/48 MHz,
8 MiB SDRAM, a 64 KiB cache and conservative collection enabled in FP-RISC.
The [preset report](2026-10-21-FPRISC-48-PRESET.md) records the fresh Gowin
build and seven passing physical examples, including ten classifier runs.

The FP-RISC runner also supports custom Base programs with arguments, input,
environment values and a file root. CI coverage and custom-runner changes
are now in the FP-RISC checkout's committed history; the earlier statement
that they were still uncommitted is superseded. Hosted CI status was not
rechecked for this document. See the
[FP-RISC guide](../../fprisc/docs/2026-10-21-TANGNANO20K-PRESET.md).

The next objective is predictable daily use: identify the connected board,
load the correct program, diagnose failures, recover without manual FPGA
reprogramming, and reproduce a tested configuration on a fresh machine.

## 1. Board identification and compatibility checks

Ownership: SimpleRisc ROM/configuration and FP-RISC host runner.

Add a versioned ROM query reporting protocol version, ISA, CPU and memory
clocks, RAM size, maximum image size, supported loader features and build
identity. Derive the identity from build inputs and record its mapping to
the final bitstream hash in the manifest. The existing `T` probe only
returns `DONE`; it cannot establish compatibility.

Have the runner discover candidate UARTs, query the board and compare its
response with the guest/build manifest. Preserve an explicit port override;
ambiguous discovery must not silently select another board. Clock discovery
also needs a defined transport strategy, since today's UART baud depends
on the configured core clock.

Acceptance:

- The correct board/configuration is identified before guest upload.
- Wrong ISA, memory requirements, protocol version or clock configuration
  produces a specific error before execution.
- No board, multiple boards and legacy ROMs have explicit outcomes.
- Tests cover malformed identity replies and deliberate mismatches.

## 2. Reliable upload and recovery

Ownership: SimpleRisc ROM and FP-RISC uploader, with shared protocol tests.

Add a versioned upload protocol with length bounds, CRC32, bounded receive
timeouts and explicit completion acknowledgement. The current `Q`/`V`
protocol verifies an XOR of uploaded words, while ROM receive loops can
wait indefinitely. Mark an image executable only after a complete verified
transfer; starting a replacement upload must invalidate the previous image.

Define how the host and ROM regain synchronization after an interrupted
transfer. Recovery must distinguish command framing from arbitrary payload
bytes. Preserve documented legacy compatibility without silently falling
back when the new protocol is required.

Acceptance:

- Truncated headers/payloads, excessive lengths, corrupt data and bad CRCs
  cannot execute an incomplete or stale program.
- Host termination and cable interruption during upload recover within a
  documented bound after reconnection.
- Each negative test is followed by a successful upload and run, without
  manually reprogramming the FPGA.
- Existing example and custom-program suites still pass on the new image.

## 3. Actionable crash reports

Ownership: SimpleRisc trap/ROM path and FP-RISC runtime/host tooling.

Report trap cause, faulting PC and fault address (`mcause`, `mepc`, `mtval`)
before returning to the loader. Retain the guest ELF and use its symbols to
explain the fault location. Distinguish CPU traps, runtime panics, host or
guest timeouts, and normal exits. Preserve diagnostics through recovery.

Acceptance: intentional illegal instructions, invalid memory accesses,
runtime errors and nonterminating programs produce distinct useful reports;
the next valid program runs successfully. Identify available stack/heap
diagnostics without claiming memory protection that the board lacks.

## 4. Physical reliability and SDRAM qualification

Ownership: SimpleRisc hardware validation, with FP-RISC workload coverage.

Run repeated upload/run/reset cycles, prolonged allocation and SDRAM
workloads, and cold-start tests. Expand to relevant temperature and supply
conditions with suitable measurement equipment. Record image identity,
duration, cycle counts, conditions and every failure; define the campaign's
pass thresholds before running it.

Acceptance: the defined endurance campaign completes without corruption or
manual recovery. Every tested condition has traceable logs and a reproducible
workload. A single-board functional pass remains separate from broader
operating-condition qualification.

The [SDRAM timing profile](../boards/tangnano20k/sdram/io_timing_gw2ar18_qn88.json)
still has missing vendor AC bounds and `pending_vendor` qualification.
Internal STA and successful programs do not close this electrical/PVT gap.

## 5. Reproducible releases and ongoing regression checks

Ownership: both repositories and their build/CI tooling.

Package a matched bitstream, source revisions, compiler/runtime identity,
manifests, checksums and validation reports. Document tool dependencies and
the supported Base capability surface. Establish a verified hosted CI pass
for the published revisions, then add a controlled physical-board regression
job with exclusive board access and recovery after failures.

Acceptance: a fresh checkout or release bundle can run the documented
examples using the recorded image and toolchain. Reports distinguish hosted
tests, physical tests and hardware qualification. A failed or incomplete run
cannot become an accepted release.

## Recommended next implementation slice

Implement priorities 1 and 2 together, keeping the 48 MHz configuration fixed.
First specify the identity/upload/recovery contract and negative tests;
then update the ROM and host tools together. Run host and RTL tests, build
with Gowin, require passing timing, and validate recovery plus the full
FP-RISC suite on the physical board. Capture evidence before accepting the
new image. Follow with crash reporting, a defined endurance campaign and
release packaging.

Faster clocks, actors and standalone SD boot can follow this reliability
baseline. They are not prerequisites for dependable single-threaded,
host-connected FP-RISC development.
