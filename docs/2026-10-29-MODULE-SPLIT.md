# Splitting `SimpleRisc.hs` into modules

Kind: refactor record, 2026-10-29. Baseline is `9ac5154`. This page records the
measurement the split was based on, what moved, and what the gates were.

## Why the split is a clean cut

`src/SimpleRisc.hs` was 3,863 lines with about 400 top-level definitions and 44
type declarations. Two measurements decided the shape:

- **The value graph is acyclic.** Building a reference graph over all top-level
  bindings and running Tarjan's algorithm gives one strongly connected component
  per definition: no module cycle is forced by any function.
- **The type graph is acyclic too**, and it is dominated by one node:
  `data Machine` has 82 fields and depends on 19 types, while nothing depends on
  `Machine` at the type level. So types can sit below every behaviour module.

The constraints that shaped the cut:

1. `initialMachine` names every subsystem's initial value, so the machine state
   has to stay above the leaf modules.
2. `test/SimpleRisc.hs` reaches 79 internals (`initialMachine`, `pipeStep`,
   `pD`, `compareOperands`, `plicEnable`, `ioStep`, ...). Rather than edit the
   tests, `SimpleRisc` re-exports its submodules, so the test module is
   unchanged.
3. `boards/tangnano20k/build.sh` and `boards/tangnano20k/sdram/build.sh` glob
   `clash/SimpleRisc.topEntity/`, `SdramPipeline.topEntity/` and
   `SdramSimpleRisc.topEntity/`, so the three top-entity modules keep their
   names and keep their `Synthetic` annotations. The `DataReprAnn` blocks for
   `CpuPhase`, `MemoryTarget`, `BusPhase` and `CommitKind` moved with their
   types; Clash still applies them (the generated packed widths are identical,
   see below).

## What moved

| Module | Lines | Contents |
|---|---:|---|
| `SimpleRisc.Types` | 939 | every `data`/`type`/`newtype` (44), the four `DataReprAnn` blocks, and nothing else |
| `SimpleRisc.Decode` | 501 | instruction decode, immediate encoders, ALU candidates, `compute`, the multiply/divide step, memory-map constants and `decodeMemoryTarget`, load/store lane helpers, `decodeHazard` |
| `SimpleRisc.Uart` | 58 | the UART state machines and their timing constants |
| `SimpleRisc` | 2,420 (was 3,863) | the `Machine` record's initial value and resets, devices, bus, pipeline, phases and the top entities |

`SimpleRisc` now begins with

```haskell
module SimpleRisc (module SimpleRisc, module SimpleRisc.Types,
                   module SimpleRisc.Uart, module SimpleRisc.Decode) where
```

so every name the tests and the SDRAM wrappers used is still in scope. The
remaining planned cuts — `Bus`, `Devices`, `Io`, `Machine`, `Pipeline`,
`Phases` — are mapped but not done; they need the same treatment and the same
gates.

## Timing: the split first cost 5%, then gained 12%

Pure code motion is not timing-neutral here, and the reason is inlining.
Measured at 48/48 MHz, two-way, `LINE_BITS=11`:

| Build | Placement 2 | Placement 3 | Logic cells |
|---|---:|---:|---:|
| before the split (`9ac5154`) | 50.486 MHz, +1.026 ns | 51.712 MHz, +1.495 ns | 13,293 |
| split, no inlining hints | 48.027 MHz, +0.012 ns | 49.095 MHz, +0.465 ns | 13,215 |
| split, `INLINE` on the moved helpers | **56.638 MHz, +3.177 ns** | not run | **12,988** |

Crossing a module boundary changed GHC's inlining of the decode helpers
(`decodeMemoryTarget`, `decodeHazard`, `compute`, `compareOperands`,
`aluCandidates`, `selectedAlu`, the immediate encoders and the lane helpers).
With them no longer folded into the pipeline, the worst path moved back to the
processor's clock-enable net (`ds5_732 -> machine CE`, 20.334 ns). Adding
`{-# INLINE #-}` to those 42 definitions restored the fold and then some: the
enable path fell to 16.363 ns and the critical path returned to the cache's
replacement lookup (`request_32 -> cache/entry_mru`, 17.621 ns), which is the
limiter the earlier review already identified.

So the split is worth 6.2 MHz and 305 fewer logic cells at placement 2 against
the immediate predecessor, and 12,988 cells against the 15,911 of the
control-area baseline (-18.3%). The lesson to carry into the remaining cuts:
**give every moved helper that sits on a decision path an explicit `INLINE`,
then measure**; do not assume code motion is free.

## Gates passed

- `cabal build all`, `cabal test`: 66 + 8 properties, unchanged.
- A name-integrity check against the previous revision: all 245 top-level names
  from before the split are still defined, exactly once, somewhere in `src/`.
- Clash generation of `SimpleRisc` and `SdramPipeline`: the packed state widths
  are byte-for-byte the same as before the split (`c$running_app_arg` 7129 bits,
  `c$case_alt` 8921, `c$ds_case_alt` 7239), which shows the bit representations
  still apply and the hardware shape is unchanged.
- `check_pipeline_rtl.py` on the regenerated SDRAM image: PASS with the same
  counts as before (101 fills, 20 writes, 58,049 held clocks).
- `tb_simple_risc.v` on the regenerated BRAM image: PASS ("HiDONE").
- The 56.638 MHz bitstream (`sha256 862693afc3743e495fb4a0843de322d4971e2aaed7d6ab96f38410d65142d104`)
  was programmed into FPGA SRAM and run at 48 MHz: the 1 MiB working-set core
  check, 38,400 RV32I and 30,720 RV32M hardware reference checks all pass.

## Not done, deliberately

- Only placement 2 was rebuilt with inlining restored; the placement-3 number
  for the final tree is not measured.
- SDRAM I/O remains unqualified; every number above is internal placement and
  routing.
- The new modules use `-Wno-missing-export-lists` like the original file. Real
  per-module export lists are a follow-up; they are what will make the module
  boundaries enforceable.
- Splitting `Machine` into sub-records (`cpu`, `pipe`, `bus`, `devices`) is the
  deeper change. It is also what per-group clock enables would want, so it
  belongs with a timing experiment, not with this move.
