# 2026-11-01: Root-Causing and Fixing the `U` Framed CRC32 Uploader (`ERR HDR`)

Kind: technical investigation, bug fix, and regression gate.
Applies to: `boards/tangnano20k/bootrom/bootrom.c`, `boards/tangnano20k/bootrom/build.sh`, `boards/tangnano20k/bootrom/build_readback_rom.py`, `boards/tangnano20k/run_program.py`, `boards/tangnano20k/sdram/build.sh`, and `boards/tangnano20k/test_upload.py`.
Follows: [`2026-10-28-ROM-IDENTITY-AND-VERIFIED-UPLOAD.md`](2026-10-28-ROM-IDENTITY-AND-VERIFIED-UPLOAD.md).

## Summary

The framed CRC32 boot-ROM uploader (`U` command in the `I`/`U`/`C`/`G` protocol) was previously marked unqualified on hardware in [`2026-10-28-ROM-IDENTITY-AND-VERIFIED-UPLOAD.md`](2026-10-28-ROM-IDENTITY-AND-VERIFIED-UPLOAD.md) after physical board runs returned `ERR HDR` or `DONEERR HDR`. Investigation uncovered three distinct bugs across the boot ROM C implementation, the SDRAM Verilog synthesis script, and the host runner:

1. **Unaligned-RAM / uninitialized-SDRAM stack frame in `bootrom.c`**: `gcc -Os` spilled 6 registers (`ra`, `s0`–`s4`, 24 bytes at `0x8000_ffe8..0x8000_fffc`) to the RAM stack at the top of `c_entry` and reloaded `s0` (`0x1000_0000`, `UART_BASE`) from the stack inside the `U` error-recovery path (`lw a0, 16(sp)` at ROM PC `0x4c4`). When the stack lived in uninitialized SDRAM or collided with an upload/test window, stack loads corrupted return/pointer registers or triggered memory stalls during live UART bursts.
2. **Inter-byte UART RX FIFO / holding-register overrun during `U` header/payload bursts**: While `U` executed word stores (`*dst++ = word`) and bit-by-bit CRC32 inner loops (`for (uint32_t bit = 0; bit < 8; ++bit)`), SDRAM cache-miss/write-through holds froze the CPU while the host streamed back-to-back UART bytes at `115200` baud (`868` clocks/byte). In addition, when a `U` frame failed with `ERR HDR` or `ERR CRC`, the host was still streaming the remaining frame bytes; returning immediately to the outer command loop caused those trailing payload bytes to be parsed as new ROM commands, producing `DONEERR HDR` Cascades.
3. **Build-time ROM image substitution bug in `boards/tangnano20k/sdram/build.sh` and host recovery in `boards/tangnano20k/run_program.py`**:
   - `boards/tangnano20k/sdram/build.sh` (lines 131–150) matched only the exact two-line formatting of the Clash-generated ROM block (`assign c$app_arg = {32'd...,` followed by `32'd...};`). Whenever Clash emitted a multi-line vector literal for `bootRomContents`, the `awk` replacement silently skipped substituting `bootrom-sdram.hex`, leaving the BRAM `bootrom.hex` (`id=46f38956791b8ca9`) baked into the SDRAM bitstream instead of `bootrom-sdram.hex` (`id=879ab42ff3920ca9`).
   - `boards/tangnano20k/run_program.py` (line 110) raised `RuntimeError` on `ERR HDR` / `ERR CRC` before draining the remaining UART burst and sending Ctrl-C (`0x03`) to resynchronize the board.

## Root Causes and Fixes

### 1. Register-Only Stack-Free Boot ROM (`boards/tangnano20k/bootrom/bootrom.c`)

In the previous `bootrom.c`, `_start` initialized `sp = 0x80010000` and jumped to `c_entry`, which opened a 32-byte stack frame:

```text
00000010 <c_entry>:
  10: fe010113          addi sp,sp,-32
  14: 01812623          sw   s0,24(sp)
  ...
  4c4: 01012503         lw   a0,16(sp)   # reloads UART_BASE from RAM stack!
```

We restructured `boards/tangnano20k/bootrom/bootrom.c` so that:
- `_start` jumps directly to `c_entry` with `noreturn` and no RAM stack frame (`0` `lw ..., (sp)` and `0` `sw ..., (sp)` instructions in both `bootrom.elf` and `bootrom-sdram.elf`).
- `recv_byte()` / `recv_word()` poll `UART_STATUS` and read `UART_RXDATA` cleanly in registers without touching RAM before an explicit `P`, `M`, `U`, `C`, or `Q` command addresses RAM.
- During `U`, all four header words (`address`, `length`, `expected_crc`, `header_crc`) are received into registers first before computing `header_crc`, so zero CRC computation occurs between the 16 header bytes on the wire.
- On `ERR HDR` or `ERR CRC`, `drain_rx_quiet()` drains trailing bytes from the host's in-flight burst (`4096` idle-status polls after the last received byte) before transmitting `ERR HDR\r\n` or `ERR CRC\r\n`, preventing trailing frame bytes from re-entering the command loop as bogus commands.

The rebuilt ROM images fit well inside the 508-word budget (words `0..507`, with words `508..511` holding the 64-bit ROM FNV-1a identity and CRC32 trailer):

| ROM artifact | Target | Instruction words | Stack loads (`lw ..., (sp)`) | New `id=` (64-bit FNV-1a) |
|---|---|---:|---:|---|
| [`boards/tangnano20k/bootrom/bootrom.hex`](../boards/tangnano20k/bootrom/bootrom.hex) | BRAM (`SimpleRisc`) | `466 / 508` | `0` | `126fabbc9b422512` |
| [`boards/tangnano20k/bootrom/bootrom-sdram.hex`](../boards/tangnano20k/bootrom/bootrom-sdram.hex) | SDRAM (`SdramPipeline`) | `462 / 508` | `0` | `1c12e19bcac60097` |

Both [`boards/tangnano20k/bootrom/build.sh`](../boards/tangnano20k/bootrom/build.sh) and [`boards/tangnano20k/bootrom/build_readback_rom.py`](../boards/tangnano20k/bootrom/build_readback_rom.py) now enforce an automated objdump check that fails the build if any `lw ..., (sp)` instruction is emitted.

### 2. Multi-Line ROM Literal Substitution in `boards/tangnano20k/sdram/build.sh`

In [`boards/tangnano20k/sdram/build.sh`](../boards/tangnano20k/sdram/build.sh) (lines 131–150), the `awk` pass that replaces the Clash-compiled `bootRomContents` vector literal with `bootrom-sdram.hex` previously required the entire 16,384-bit vector literal to span exactly two lines. In the Clash-generated SDRAM pipeline netlist, `bootRomContents` spans ~170 lines (`wire [16383:0] c$app_arg;` followed by `assign c$app_arg = {32'd..., ...};`).

We replaced the fragile two-line `awk` matcher with a deterministic Python pass that locates the `wire [16383:0] <name>;` declaration, matches the entire multi-line `assign <name> = { ... };` statement, and asserts `n == 1` substitution (failing the build immediately if the 512-word ROM literal is not replaced).

### 3. Host Error Drain and Recovery in `boards/tangnano20k/run_program.py`

In [`boards/tangnano20k/run_program.py`](../boards/tangnano20k/run_program.py) (line 110), `upload_verified()` now flushes and drains any residual UART output and issues a clean Ctrl-C (`\x03`) reset via `_recover_rom()` whenever an upload frame reports `ERR HDR`, `ERR CRC`, or a readback mismatch, leaving the board synchronized at a fresh `READY` prompt instead of stranded mid-frame.

## Verification

All host, ISA, and RTL simulation gates pass:

- `python3 boards/tangnano20k/bootrom/check_loader.py`: **PASS** (`P`/`R`/`M`, `T`/`Q`/`V`/`H`, and `I`/`U`/`C`/`G` with header/payload CRC error rejection and recovery).
- `python3 -m unittest boards/tangnano20k/test_upload.py`: **8/8 PASS** (including `test_bootrom_elves_have_no_stack_loads` and recovery from `ERR HDR` / `ERR CRC`).
- `python3 -m unittest boards/tangnano20k/test_preset_manifest.py`: **6/6 PASS** (updated preset manifest `rom_id = 1c12e19bcac60097`).
- `python3 boards/tangnano20k/sdram/check_pipeline_rtl.py --boot-loader --loader-command U --compressed --simulator verilator`: **PASS** (full RTL pipeline + cache + UART RX/TX executing `I`/`U`/`C`/`G` framed CRC32 upload and running the guest to completion).
