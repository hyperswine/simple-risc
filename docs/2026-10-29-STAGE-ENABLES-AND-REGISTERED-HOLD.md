# Per-stage enable registers, a registered hold, and what they measured

Kind: implementation change with a Gowin build and RTL regressions, 2026-10-29.
Baseline for every number below is the RAM-backed-MRU build in
`evidence/2026-10-28-control-area/mru-ram` (same device, 48/48 MHz,
`LINE_BITS=11`, two-way, placement 2). This page answers the two remaining
items of the [independent timing review](2026-10-28-INDEPENDENT-TIMING-REVIEW.md):
item 1 (per-stage enable registers) and item 3 (a registered hold, and no
next-state select over the whole `Machine`).

## Result

The processor's control storage is now five separately enabled registers
instead of one. At 48 MHz the design uses **16.5% fewer logic cells and 8.4%
fewer CLS at essentially the same clock**, and the critical path leaves the
processor's enable network for the cache, where the baseline's path already
was.

| 48/48 MHz, two-way, `LINE_BITS=11` | Baseline | Now (place 2) | Now (place 3) |
|---|---:|---:|---:|
| Logic cells | 15,911 / 20,736 (77%) | 13,293 (65%) | 13,293 |
| CLS | 8,856 / 10,368 (86%) | 8,110 (79%) | 8,110 |
| Registers | 5,308 | 5,381 | 5,381 |
| BSRAM / DSP | 37 / 3.5 | 37 / 3.5 | 37 / 3.5 |
| Reported core Fmax | 52.023 MHz | 50.486 MHz | **51.712 MHz** |
| Worst setup slack at 48 MHz | +1.611 ns | +1.026 ns | +1.495 ns |
| Worst path | `core/request_66` → `cache/entry_mru/D`, 19.187 ns | `core/request_32` → `cache/entry_mru/D`, 19.772 ns | same shape |

Two conclusions matter more than the table:

1. **The wide enable is gone from the critical path.** Before this change, the
   processor's single enable carried about 1,776 loads. A first attempt that
   only split the stage payloads made things *worse* (48.438 MHz): the machine
   register's remaining ~5,000-load clock enable became the worst path, and
   all 18 leading setup paths were `ds5_732 → c$running_app_arg_*/CE` at
   20.6 ns. Taking the pipeline field onto its own enable fixed that and put
   the design back on the cache's MRU lookup.
2. **Items 1 and 3 do not by themselves unlock 85-95 MHz.** The limiter is now
   `cache/entry_mru`, exactly the path the earlier review ranked first. The
   processor side no longer contributes a leading path at 48 MHz.

## What changed

### Item 3: the hold is a clock enable, not a machine-wide next-state select

`SdramPipeline.step` used to be

```haskell
| held -> let ticking = R.tickHeld machine ... in ...
| otherwise -> ... machineStepCoreBy ...
```

That is a select over every state bit. It is now a single path whose result is
discarded when the core is held:

- `HeldState` (the cycle counter, `mtime` and the received-byte holding
  register) is registered **every** cycle. Those are exactly the fields
  `tickHeld` advanced; `cpuInstret` deliberately stays out of the group so held
  clocks never count as retirements.
- The machine register loads under `enable & ~(memory_hold & ~breaking)`, so a
  hold stops loading it instead of selecting a different value.
- Ctrl-C still lands during a hold: `breaking` opens the enable and the step's
  own reset path supplies the next state.
- The step's *outputs* are idled while held, so a frozen cycle cannot emit a
  store or a UART byte. Any suppressed effect is simply retried from the
  unchanged state after the hold.

`tickHeld` is kept for the serial image (`SdramSimpleRisc`), which still uses
the old whole-machine hold.

### Item 1: one clock-enabled register per stage

`StagePayloads` (D, E1, E2 and M payloads) lives beside `Machine`, injected
before the step and taken back from it, the same way `cpuRfA`/`cpuRfB` and the
DSP products already work. `StageLoad` carries the four enables. `cpuPipe`
gets a fifth register because it is the largest remaining field.

The enables are *supersets* of "this payload changes":

```haskell
StageLoad (dFree && pFCount /= 0) (e1Advance || dAdvance) (e2Advance || e1Advance) (mHold || e2Advance)
```

The first version used `e1Advance`/`e2Advance` alone and was wrong: an **empty**
stage takes a new instruction even when it cannot advance because the stage
after it is stalled. The Haskell circuit test for the BRAM image caught it with
`X: Unknown initial element` from the block-RAM model; both images now pass.

`StagePayloads`/`withPipe`/`heldStateOf`/`applyHeldState` are exported so the
two circuits (`simpleRiscSd` for the BRAM image and `SdramPipeline.circuit`)
register the same groups.

### What was not done: `syn_keep` duplicates of the enable

The plan called for duplicating the enable into 4-8 copies of about 64 loads
with `syn_keep`. After the split the enable no longer appears in the top 25
setup paths, so replication has nothing to fix yet. A `syn_keep` copy would
also have to be written into the generated Verilog, which this repository
deliberately does not post-process for synthesis.

### Item 5's over-constrained target

`sweep_place.py` was run over the new design at a 53 MHz target (10% above the
48 MHz clock):

| placement | Fmax | worst slack |
|---|---:|---:|
| 2 | 50.486 MHz | +1.026 ns |
| 3 | 51.712 MHz | +1.495 ns |

Place 2 reproduced the direct build exactly, and over-constraining changed
nothing: the placer is already saturated at this utilization, so the lever is
**placement mode**, not the target. Placement 3 is the better mode for this
design and recovers 1.2 MHz.

## Verification

- `cabal build all`, `cabal test`: 66 + 8 properties, including the BRAM
  circuit test and the pipelined cycle-count assertions.
- `check_pipeline_cache.py` (18 cases), `check_cache_mru.py`,
  `check_clock_bridge.py`, `check_fence_assertion.py`: pass.
- `check_pipeline_rtl.py` against freshly generated Verilog, IM and IMC
  two-way guests: pass with 101/91 fills, 20 writes, 58,049/57,745 held
  clocks — identical to before this change, which is the point: it is a
  restructure, not a pipeline change.
- Gowin V1.9.12.04, GW2AR-LV18QN88C8/I7, two builds plus a two-case sweep, all
  with zero setup and hold violating endpoints.
- The placement-3 bitstream passes the board's regression set at 48 MHz; see
  the physical-run table below.

SDRAM I/O remains unqualified; every timing number here is internal placement
and routing.

## Physical run, 2026-10-29

The placement-3 build was programmed into FPGA SRAM on the Tang Nano 20K and
the board's own regression scripts were run against it at 48 MHz.

| Item | Value |
|---|---|
| Bitstream | `output/tangnano20k/sweep-new/place3-l11/impl/pnr/sdram_test.fs` |
| SHA-256 | `a78ee6508f91cd36386c8b8b568d30de93927092e175088c02ba73bc7b5b1d16` |
| ROM identity | `isa=rv32im cpu=48 mem=48 ram=8 MiB max=2 MiB cap=PMXQVHTUICG id=fe28365ea09c4e00` |
| Internal STA | 51.712 MHz Fmax, +1.495 ns at 48 MHz, 0 setup / 0 hold |

| Check | Result |
|---|---|
| `sdram/check_core.py --freq-mhz 48` | PASS: high-address execution, 1 MiB working set, all banks, last word and byte lanes |
| `check_rv32i.py` | PASS: 38,400 hardware reference checks, 10 runs |
| `check_rv32m.py` | PASS: 30,720 hardware reference checks, 20 runs |
| `check_bus.py` | PASS: 3,852 RAM/RX bus checks |
| `check_finisher.py` | PASS: word, halfword, success, failure and ignored-command cases |
| `check_traps.py` | PASS: 90 guest CSR/exception/mret checks per run |
| `check_exceptions.py` | PASS: 31 exception/encoding and legal-access checks |
| `check_processor.py` | PASS: five exact C arithmetic runs, byte/halfword/word stress, UART RX/TX, Ctrl-C recovery, memory clear and reload |
| `check_counters.py --sdram` | PASS: 27 counter/retirement/trap checks per run, 10 runs |
| `check_interrupts.py` | PASS: 27 interrupt checks per run with 67 bytes received by interrupt while busy, 5 runs |

This is the same coverage the earlier 48 MHz boards reports list, so the
enable-register restructure and the four-cycle cache port are exercised on
hardware: interrupt handling and Ctrl-C during cache misses, exact
retirement counters, traps and `mret`, the finisher, and the full 1 MiB RAM.

Two things were not run: `check_sd.py`, because it writes over a test block on
the microSD card, and the compressed-board and FP-RISC classifier runs, which
need the RV32IMC bitstream and the sibling `fprisc` checkout.

The CRC-framed `U` upload still answers `ERR HDR` on this image. That
reproduces the [recorded board result](2026-10-28-ROM-IDENTITY-AND-VERIFIED-UPLOAD.md);
the frame is accepted in RTL simulation, and every legacy `P`/`Q`/`V`/`H`
upload used by the checks above works, so it is not a consequence of this
change. `run_program.py --identify` also refuses this ROM because it requires
a capability `R` that the ROM's identity line does not advertise, although the
ROM implements `R`; both are ROM/tool issues outside this change.

## Next

1. **`cache/entry_mru`** is now the single limiter (19.77 ns). The earlier
   review's recommendation still stands: bank or register the replacement-bit
   read, or move the collision selection across the existing lookup boundary.
2. Use `SDRAM_PLACE_OPTION=3` for this design in the `fprisc-48` preset, which
   currently pins placement 2 and now closes 48 MHz at +1.026 ns there.
3. Re-run `run_perf.py` for the CPI effect; nothing here changes instruction
   semantics, so only the enable structure should differ.
