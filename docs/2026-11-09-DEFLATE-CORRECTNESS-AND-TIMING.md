# Deflate correctness fixes and five-placement timing measurement

Kind: implementation and measurement, 2026-11-09. Applies to the new Deflate
working-tree implementation on top of the `8f83a6d` simple-risc core. This does
not change the adopted RV32IM core or its 84/48 MHz preset.

## Result

The stored/fixed-Huffman inflater now passes host and generated-Verilog tests,
including input stalls, output backpressure, EOF/truncation, history wrap and
reset. The standalone ROM-fed probe routes at all five placement options, but
**none closes 84 MHz**. Its measured Fmax is 64.110–67.122 MHz. This establishes
a correctness-checked experimental baseline, not a timing-qualified accelerator.

## Changes

- Empty stored blocks finish immediately, including nonfinal empty blocks.
- Refill cannot interrupt literal emission or the BRAM copy read/write pair.
  The read address remains selected while a copied output byte is stalled.
- `out_ready` adds output backpressure: only accepted output writes the window
  or advances counters. Stored bytes may be accepted on consecutive clocks.
- `in_end`, asserted with `in_valid` low after the last input byte, is sticky
  until reset. Insufficient bits after EOF raise `bad`; no fake zero padding
  is supplied. A seven-bit EOB can finish without a nine-bit peek's padding.
- The ring pointer is 15 bits; an independent 16-bit history count saturates
  at 32768. Valid back-references remain valid beyond 64 KiB of total output.
- The host RAM model reads old memory contents and checks stable stalled output.
  Its missing `fromMaybe` import is fixed. Test input is held until accepted.
- The RTL driver advances input only on acceptance, handles empty accepted and
  rejected streams separately, and exits unsuccessfully on any discrepancy.
- The FPGA wrapper now has one outstanding synchronous ROM read and retains
  each returned byte until acceptance. Reset restarts the ROM address and feeder.
  PLL lock participates in the reset synchronizer.
- The build handles Clash's `default_nettype none`, permits the 32768-entry
  RAM initialization loop, and fixes an out-of-bounds ROM initialization loop.
  Its SDC uses `(FBDIV+1)/(IDIV+1)` relative to the 27 MHz input. Timing parsers
  require complete reports and verify the requested clock rather than accepting
  a successful tool exit as timing closure.

The interface still intentionally rejects dynamic-Huffman blocks. It is a raw
DEFLATE inflater, without gzip/zlib framing, checksums or concatenated-stream
parsing. Earlier bytes emitted before `bad` remain a partial output prefix.

## Functional evidence

- Full `cabal test`: **74 SimpleRisc + 8 PsramRegs + 6 Deflate properties pass**.
- The shared corpus has **44 cases**, each checked under four input/output
  schedules in the host model and unmodified Clash-generated Verilog: **176
  RTL runs pass**. Fifty additional generated stall-seed pairs each exercise
  the ten original host vectors.
- Cases cover stored/fixed empty streams, multiple and mixed blocks, a stored
  header following a fixed EOB mid-byte, exact seven-bit final EOB, 65535-byte
  stored blocks, output beyond 64 KiB, distance 32768, overlapping distance-one
  copies, and every length/distance code at both extra-bit extrema. Rejections
  include bad NLEN, unavailable history, reserved block/symbol/distance codes,
  unsupported dynamic blocks, and every byte truncation of two short streams.
- Accepted corpus fixtures are independently inflated by Python zlib during
  generation. Truncated fixtures use zlib's decoded prefix as their oracle.
- Deliberately corrupting the first expected output byte makes the RTL checker
  fail with a nonzero exit code. The bench does not infer rejection from an
  empty expected-output file.
- The exact FPGA feeder/ROM wrapper passes a midstream reset and two complete
  16384-byte replays, with the window RAM retaining old contents across resets.
  This bench uses a behavioral PLL stub; it does not qualify the physical PLL.

During bring-up Icarus left phase-only `always @(*)` controls uninitialized
when their initialized phase never changed. Expressing the refill/active
predicates as Boolean comparisons removed that startup issue. All final RTL
results use the unmodified regenerated output. The installed Verilator 5.054
crashed on the earlier generated file; no Verilator pass is claimed.

## Matched placement measurement

Gowin V1.9.12.04, GW2AR-LV18QN88C8/I7, 84 MHz clock, placer target 92 MHz,
map 3, route 1, route fanout 8, no placement regions and no filler. Placement 0
synthesizes once; placements 1–4 consume that exact frozen netlist, checked by
SHA-256. The harness streams the `big` ROM vector and ties `out_ready` high.
These totals include the feeder, observation logic and ROM; output-stall paths
removed by the always-ready sink are not physically qualified here.

| Placement | Fmax MHz | Setup slack ns | Setup / hold violations | Occupied CLS | Worst-path cell / route ns |
|---:|---:|---:|---:|---:|---:|
| 0 | 64.451 | -3.611 | 64 / 0 | 703 | 5.766 / 9.483 |
| 1 | 64.110 | -3.694 | 54 / 0 | 700 | 6.304 / 9.027 |
| 2 | 64.110 | -3.694 | 54 / 0 | 700 | 6.304 / 9.027 |
| 3 | 67.122 | -2.994 | 52 / 0 | 691 | 5.273 / 9.358 |
| 4 | 65.568 | -3.346 | 48 / 0 | 699 | 6.212 / 8.772 |

All placements use **1258 logic units (1121 LUT + 137 ALU), 184 registers and
17 BSRAMs**: 16 for the 32 KiB window and one for the stimulus ROM. No DSP
primitive is used. Options 1 and 2 report identical timing, resource and worst
path results, so five requested options yield four distinct measured outcomes.
There are no reported hold violations; all five have setup violations.

The original scaffold's incorrect clock formula produced a 756 MHz constraint
for an 84 MHz PLL. That run was stopped/excluded, retained only locally under
`output/tangnano20k/deflate-invalid-sdc-20261109/`. Every result above explicitly
reports an 84 MHz constraint. There is no pre-fix matched performance comparison:
the old decoder and feeder had correctness problems, so no area/timing
improvement relative to that implementation is claimed.

## Interpretation and next trial

The critical paths are inside the bit-buffer update/enable cone, not the window
RAM. At placement 0, state bit 138 (buffer bit 2) feeds the symbol/extra-bit decode,
`total` addition, and the shift/update selection, ending at buffer bit 6. The
other placements have the same class of loop, at 13–14 reported logic levels.
Routing is 8.77–9.48 ns even though only about 7% of device logic is occupied.
Low utilization alone does not make this design fast, and the source-level
intent of a shallow probe is not borne out by the mapped circuit.

A bounded next experiment is to register the fixed-symbol/code-length decode
before consuming length extra bits and shifting the buffer. This removes decode,
length-count arithmetic and the selected shift from one feedback cycle, at the
cost of an additional decode cycle. Separately, the buffer never holds more
than 23 bits (refill is allowed only at 15 or fewer); narrowing its 40-bit storage
and shift network to 24 bits is another measurable area trial. Test each against
this frozen baseline with the same corpus and all placement options; do not
assume the two changes compose or that a higher Fmax offsets extra cycles.

No board image was loaded, and no operating frequency is hardware-qualified by
this work. CPU integration and full dynamic-Huffman support remain separate work.

## Reproduction and evidence

[Component guide](../boards/tangnano20k/deflate/README.md) contains exact commands.
[Evidence](evidence/2026-11-09-deflate/) includes host/RTL results, the negative
control, wrapper reset/replay log, compressed generated RTL and synthesis
netlist, all five raw timing/resource reports and Tcl/SDC constraints, and input
and evidence hashes. Local full builds are under
`output/tangnano20k/deflate-sweep-20261109/`.
