# SDRAM envelope evidence, 31 October 2026

See [the experiment report](../../2026-10-31-SDRAM-OPERATING-ENVELOPE.md)
for the conclusions, operating conditions and limitations.

- `summary.json` contains the per-phase classifications, repeated passing
  windows, sampled endpoint distances, comparison totals and normalized
  post-route netlist checks.
- `measurements.json` contains every board attempt, including unsuccessful
  and incomplete runs. `hardware/<case>/run-*/` retains its parsed result,
  programming log and guest/tester UART bytes. Identity/protocol errors are
  recorded in the result JSON; a guest UART file can be empty if the guest
  never started.
- `builds/<case>/` contains the source/image hash receipt, actual PLL and SDC,
  build Tcl, I/O-model status, complete internal timing report and build logs.
  Earlier failed or interrupted attempts are retained where recorded.
- `guests/` holds the three exact guest binaries and ELFs. `reference.json`
  contains independently calculated expected digests.
- `recovery-*/` contains each restoration's programming log, ROM identity
  and twelve upload/readback CRC checks.
- `experiment.json` pins the source revision, source archive, ordinary CPU
  RTL, guest and recovery image. `tool-versions.json` records the toolchain.
- `netlists/` retains one compressed post-route Verilog sample per
  frequency/test type. Every case's original and normalized netlist hashes
  are in `summary.json`; normalization removes only creation time and the
  single PLL phase parameter. This is not proof of identical physical routes.
- `tools/` contains copies of the experiment, parser, summarizer, collector
  and plot sources. Maintained copies are under
  `boards/tangnano20k/sdram/` at the repository root.
- `manifest.json` gives SHA-256 hashes for every evidence file except itself.
- `validation.json` records the final raw-UART, journal, receipt and recovery
  audit. Its script is retained as `tools/validate-final.py`; run it from the
  repository root with the local experiment directory as its argument.

Large FPGA bitstreams and the frozen source/RTL build tree remain in the local
ignored directory `output/tangnano20k/envelope-20261031/`; their hashes are
retained here. Absolute paths in receipts identify those original local build
inputs. The exported report/PLL/SDC/log copies use the relative layout above.

A protocol/incomplete result means the memory experiment did not complete.
It is neither a passing phase nor an invented memory-comparison failure.
No phase window in this evidence is a vendor AC limit or PVT qualification.
