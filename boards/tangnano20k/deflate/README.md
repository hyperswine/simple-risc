# Deflate timing probe

A raw DEFLATE **inflater**, supporting stored and fixed-Huffman blocks with a
32 KiB history RAM. Dynamic-Huffman blocks are rejected. This is a standalone
probe, not an accelerator connected to the RISC-V core, and does not implement
zlib/gzip framing or checksums.

## Interface

- Accept input on `in_valid && in_ready`; hold the byte until accepted.
- After the final byte has been accepted, deassert `in_valid` and assert
  `in_end`. EOF is latched until reset. Do not send synthetic padding bytes.
- Accept output on `out_valid && out_ready`. Output remains stable while
  stalled. Consecutive valid cycles are legal, including stored bytes.
- `done` and `bad` are sticky until synchronous active-high reset. `bad`
  includes unsupported dynamic blocks and detected malformed/truncated input.
  Output produced before an error is a prefix, not a successful complete stream.
- Reset starts a new stream without clearing the RAM. A saturating history
  count prevents reads of old/unwritten history; a separate 15-bit pointer wraps.
- Trailing input after a final block is not validated; this is a single-stream
  decoder, not a concatenated-stream parser. There is no total output-size limit.

## Reproduce

From the repository root:

```sh
python3 boards/tangnano20k/deflate/make_vectors.py
cabal test simple-risc-test --test-show-details=direct
cabal run -v0 clash -- -isrc -hide-package simple-risc src/Deflate.hs --verilog \
  -fclash-clear -outputdir output/tangnano20k/deflate-generated
python3 boards/tangnano20k/deflate/check_deflate.py

DEFLATE_SKIP_CLASH=1 DEFLATE_PREPARE_ONLY=1 FREQ_MHZ=84 \
  DEFLATE_TARGET_MHZ=92 DEFLATE_OUT=output/tangnano20k/deflate-sweep/p0 \
  bash boards/tangnano20k/deflate/build_deflate.sh
python3 boards/tangnano20k/deflate/check_wrapper.py output/tangnano20k/deflate-sweep/p0

DEFLATE_SKIP_CLASH=1 FREQ_MHZ=84 DEFLATE_TARGET_MHZ=92 \
  DEFLATE_OUT=output/tangnano20k/deflate-sweep/p0 \
  bash boards/tangnano20k/deflate/build_deflate.sh
python3 boards/tangnano20k/deflate/sweep_deflate.py output/tangnano20k/deflate-sweep
python3 boards/tangnano20k/deflate/report_deflate.py output/tangnano20k/deflate-sweep --freq 84
```

Use a fresh output root for a new experiment. `build_deflate.sh` defaults to
84 MHz, placement 0, the `big` vector and no filler, with map 3, route 1 and
route fanout 8. It allows timing failures so a sweep can record every option;
`report_deflate.py` reports the `passes` flag and checks the actual constraint.
A successful tool exit alone does not mean timing closure.
The ROM harness accepts 1..65535 compressed input bytes; this limit does not
apply to the decoder interface or its host/RTL corpus checks.

The RTL checker runs the shared 44-case corpus under four input/output schedules
and requires a deliberately corrupted expected byte to fail. The wrapper check
uses a behavioral PLL stub and verifies an aborted stream plus two full replays.
The routed wrapper uses a real PLL, a registered vector ROM and an always-ready
sink. Area includes that harness; stall-handling paths optimized out by the
always-ready sink are not physically qualified by this measurement. No board
programming or board-frequency qualification is performed by these commands.

Results and limitations: [2026-11-09 correctness and placement sweep](../../../docs/2026-11-09-DEFLATE-CORRECTNESS-AND-TIMING.md).

The current experimental decoder registers fixed-symbol/code-length decode
before consuming bits. The [pipeline trial](../../../docs/2026-11-10-FOUR-TIMING-TRIALS.md)
records five-placement gains and stream-dependent extra cycles. It still fails
84 MHz setup timing in every placement; it is not a qualified 84 MHz accelerator.
