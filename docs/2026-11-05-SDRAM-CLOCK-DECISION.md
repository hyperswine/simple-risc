# SDRAM: the vendor cannot supply timing; the canonical profile splits clocks

Kind: decision record, 2026-11-05. Closes the open question in
[NEXT-STEPS](2026-11-02-NEXT-STEPS.md) item 3.

## Gowin's reply

Gowin replied to the [SDRAM I/O request](2026-10-18-TANGNANO20K-SDRAM-IO-VENDOR-REQUEST.md)
but said they could not help with the SDRAM data. The embedded memory's
AC timing, an SDC with real I/O delays and the CLKOUT/CLKOUTP jitter bound
stay unavailable, so no SDRAM clock can be signed off from vendor numbers.
What is known comes from the board: the
[operating envelope](2026-10-31-SDRAM-OPERATING-ENVELOPE.md), where only
48 MHz has a passing phase a full step away on both sides of its setting.

## Decision

The canonical simple-risc profile splits the clocks: the SDRAM runs at
48 MHz, and the CPU runs on its own, faster clock behind the clock bridge.
CPU speed is pursued on the CPU side only; the SDRAM clock is not raised.

Why this shape:

- 48 MHz is the only SDRAM clock with measured phase margin on both sides,
  and the vendor will not supply data that could qualify a faster one.
- The bridge is fully constrained (setup-2 / hold-1 multicycle paths, see
  [CPU81-TIMING](2026-11-02-CPU81-TIMING.md)), so the CPU clock can move
  without touching the memory side.
- With the two-way 64 KiB cache, waiting on the SDRAM costs about 9% of the
  classifier's cycles, so a faster SDRAM clock could only win a slice of
  that.

Higher CPU clocks are the goal. The current canon is **81 MHz**: the
`fprisc-81` preset (CPU 81 / SDRAM 48). `fprisc-72` follows the same shape at
a lower clock, and `fprisc-48` stays as the single-clock baseline.

## Still open

Electrical qualification of 48 MHz itself: the envelope is one board at room
conditions. Supply, temperature and second-board sweeps (or a measured pin
characterisation) remain the only way to qualify it further.
