# Boot ROM board identity and CRC-verified upload (`I`/`U`/`C`/`G`)

Kind: implementation record. Applies to the boot ROM in
`boards/tangnano20k/bootrom/`, the host library `boards/tangnano20k/rom_protocol.py`,
and both board images (BRAM and SDRAM pipeline).

The protocol landed in commit `417053d3099dfa52b6ae497d796086a75dc5d4ab`
(2026-10-27) without a dated page. This page is that record, written 2026-10-28,
and it adds the ROM-identity finding from the `ERR HDR` investigation below.
It implements priorities 1 and 2 of the
[dependability roadmap](2026-10-25-FPRISC-BOARD-DEPENDABILITY.md); that page's
"proposed work" framing is now stale for those two items and has been corrected.

## Why

Before this, the host had no way to ask a board what it was. `T` returns
`DONE`, which proves a UART and *a* ROM, not a compatible one: a wrong ISA,
wrong clock, wrong RAM size or an older ROM all looked identical until a guest
misbehaved. Uploads were `P`/`Q` with an optional `V` XOR readback, the ROM's
receive loops could wait indefinitely, and a partially accepted image could
still be started.

## The wire protocol

Legacy `P`/`R`/`M`/`X`/`Q`/`V`/`H`/`T` keep their exact framing. Four commands
are added. All integers are little endian; all replies are ASCII.

### `I` — board identity

Request: one byte `I`. Reply: one line.

```
SRID1 isa=rv32imc cpu=00000030 mem=00000030 ram=00800000 max=00200000 cap=PMXQVHTUICG id=b71e54b0563bfcdd
```

| field | source | meaning |
|---|---|---|
| `SRID1` | literal | identity protocol version; a host must reject an unknown `SRIDn` |
| `isa` | `csrr misa`, bit 2 | `rv32im`, or `rv32imc` when C is present |
| `cpu` | ROM word 508 | CPU clock in MHz, hex |
| `mem` | ROM word 509 | memory clock in MHz, hex |
| `ram` | `RAM_BYTES` | RAM in bytes: `00800000` (8 MiB SDRAM) or `00010000` (64 KiB BRAM) |
| `max` | `EXTENDED_WORDS * 4` | largest uploadable image in bytes: `00200000` (2 MiB SDRAM) or `0000ff00` (65,280 B BRAM) |
| `cap` | literal | commands this ROM implements: `PMXQVHTUICG` |
| `id` | ROM words 510/511 | 16 hex digits; see below |

`max` is why the BRAM and SDRAM ROMs stay separate images: the BRAM bound is
`16384 - 64` words, reserving 256 B for the ROM's own stack.

### What `id=` identifies — and what it does not

There are two different digests, and only the second reaches a board.

- `bootrom/build.sh` computes
  `sha256(508 code words ‖ ":variant:cpu_mhz:mem_mhz")` and writes it to words
  510/511 of the **committed** hex files.
- `sdram/build.sh` then **re-stamps** words 508..511 of the ROM it embeds with
  `cpu_freq, mem_freq, build_id[:8], build_id[8:16]`, where `build_id` is
  `preset_manifest.compute_build_id` — `sha256` over the build `configuration`
  plus the hashes of every input (`src/*.hs`, `sdram/*.v`, the cabal files,
  `bin/Clash.hs`, the `.cst`, both committed ROM hex files, the build and preset
  scripts, `io_timing.py`, the QN88 timing JSON, `check_gowin_timing.py`),
  truncated to 16 hex digits.

So on an SDRAM build `id=` identifies **the whole build**, not the ROM. The
committed hex's own metadata words are discarded. This is the intended
behaviour — it is what makes `id=` usable as a bitstream-identity check against
`build-manifest.json`'s `rom_identity` block — but it has a consequence worth
stating plainly: **two images with byte-identical ROM code report different
`id=`, and `id=` cannot tell you whether the ROM changed.**

Verified 2026-10-28 against the controlled-benchmark evidence: the `baseline`
and `combined` ROMs are identical in all 508 code words and in words 508/509,
and differ only in words 510/511 (`b71e54b0/563bfcdd` versus
`fe28365e/a09c4e00`), exactly as the whole-build derivation predicts.

### `U` — framed upload with CRC32 and bounded timeouts

Host frame:

```
'U' | magic 0x31555253 ("SRU1") | count | hcrc32 | count words | pcrc32
```

- `count` — payload words, in `[1, EXTENDED_WORDS]`.
- `hcrc32` — CRC-32 (IEEE 802.3, reflected; the same value `zlib.crc32` gives)
  over the 8 bytes `magic ‖ count`.
- payload — the image zero-padded to a word boundary.
- `pcrc32` — CRC-32 over those padded payload bytes.

The ROM's `crc32_word` updates over one 32-bit word at a time with the
`0xedb88320` reflected polynomial, which is equivalent to a byte-wise CRC-32
over the word's little-endian bytes; the host's `crc32_bytes` is `zlib.crc32`.
`test_upload.py` and `check_loader.py` pin that agreement from both sides.

Replies:

| reply | cause | link state afterwards |
|---|---|---|
| `OK <pcrc32>\n` | accepted; the image is marked ready | drained, aligned |
| `ERR HDR\n` | magic mismatch, or `hcrc32` mismatch | drained, aligned |
| `ERR LEN\n` | `count == 0` or `count > EXTENDED_WORDS` | drained, aligned |
| `ERR CRC\n` | payload CRC mismatch | drained, aligned |
| `ERR TMO\n` | a byte did not arrive within `UART_TIMEOUT_SPINS` (500,000 status polls) | **not drained** — the link is assumed idle |

Two properties the dependability roadmap asked for, and where they live:

- **A replacement upload invalidates the previous image.** On entering `P`, `Q`
  or `U` the ROM sets `loaded = 0; ready = 0; failed = 1` and zeroes `RAM[0]`
  before reading anything else. A failed upload therefore cannot leave a stale
  image startable, and `RAM[0] = 0` makes an accidental start trap immediately.
- **Resynchronisation.** `ERR HDR`, `ERR LEN` and `ERR CRC` go through
  `drain_err()`, which discards bytes until `UART_DRAIN_SPINS` (4096) consecutive
  status polls see nothing, and only then prints. The host's already-transmitted
  payload is consumed, so the next byte the host sends is read as a command.
  The `ERR TMO` paths deliberately skip draining and `goto next_cmd`.

An oversized `Q` frame is still rejected without RAM writes, and its declared
payload is consumed before `ERR\n`, as before.

### `C` — CRC32 readback

`C` returns 8 lowercase hex digits plus `\n`: CRC-32 over the `loaded` words
currently in RAM. `V` is the legacy XOR over the same range. Both read the
`loaded` count from the last accepted upload, so `M` (which zeroes `loaded`)
makes both report the CRC/XOR of an empty range.

`C` is the end-to-end check: it re-reads RAM rather than trusting the value the
ROM accumulated during the upload, so it catches a store that did not land.

### `G` — guarded run

`G` runs only when `ready` is set, that is, only after a complete verified
upload; otherwise it replies `ERR NOIMG\n` and stays in the ROM. `R` and `H`
keep their legacy rule: they run unless `failed`. All three quieten the UART
control register, `msip` and `mtimecmp`, claim and complete a stale PLIC
request, and drain any stale RX byte before jumping, so a previous program's
interrupt arming and leftover input never reach the guest.

## Host side

`boards/tangnano20k/rom_protocol.py` (486 lines) is the single implementation;
`run_program.py` and the FP-RISC runner both use it.

- `frame_u(image, max_words)` builds the frame, raising `ValueError` on an empty
  or oversized image before anything is written.
- `parse_identity` / `RomIdentity` apply a strict regex and reject non-ASCII
  bytes, an unknown `SRIDn` version, an unsupported ISA, non-positive clocks or
  sizes, and `max_bytes > ram_bytes`. A version mismatch raises
  `CompatibilityError`; malformed content raises `ProtocolError`.
- `check_compatibility(...)` compares against explicit expectations or a
  `build-manifest.json`'s `rom_identity` block, requires capabilities `UICG` by
  default, checks `build_id`, and rejects an image larger than the board's
  `max_bytes`.
- `query_identity(io, expected_mhz=...)` sends `\x03`, drains, then `I`. On no
  reply it sweeps `CANDIDATE_CLOCKS_MHZ` (48, 96, 72, 54, 66, 27) **in place**
  with `set_fd_baud`, then restores the expected rate. A board that answers at a
  different clock becomes a specific `CompatibilityError` naming both rates,
  rather than silence. A board that answers `DONE` to `T` but ignores `I` raises
  `LegacyRomError` naming the missing commands.
- `set_fd_baud` reconfigures an open descriptor (`tcsetattr`, then the macOS
  `IOSSIOSPEED` ioctl for a rate with no `B*` constant). Nothing here closes and
  reopens the port, because that wedges the BL616 bridge while the FPGA is
  transmitting — see the board README's known-issue section.
- `discover_port` refuses ambiguous multi-port discovery and always honours an
  explicit `--port`.
- `upload_image_u` writes the frame, expects `OK <crc>`, then optionally
  verifies with `C`; `retries` re-sends after a `\x03` and drain, and every
  failure path reports the ROM's actual reply line.
- `start_guarded` sends `G` and raises `UploadError` on `ERR NOIMG`, otherwise
  returning the guest's initial output.
- `FdTransport` is the non-closing descriptor transport the above rely on.

`run_program.py` gained `--identify`, `--protocol {p,u}` and `--manifest`.
**The default remains `p`** (legacy `P`+`R`), for the reason in the next section.

## Verification

In CI (`formal-and-rtl` job):

- `bootrom/check_loader.py` compiles the **actual ROM C** natively under
  `ROM_HOST_TEST` with UART/memory hooks and runs both variants end to end:
  65,280-byte BRAM bounds and 2,097,152-byte SDRAM bounds, `I`/`U`/`C`/`G`,
  `Q`/`V`/`H`/`T`, CRC32 and timeout recovery, `P`/`R`/`M`/`X`, and the reset
  causes.
- `test_upload.py` (285 lines) unit-tests the host library against a
  `FakeRomTransport`: partial nonblocking writes and backpressure, CRC32 and
  frame construction, identity parsing (valid and malformed), compatibility and
  manifest validation, port-discovery ambiguity and override, legacy-ROM and
  in-place clock discovery, and upload retry with guarded start.
- `sdram/test_preset_manifest.py` covers the `build_id` / `rom_identity`
  manifest contract, including that a preset build refuses to become `ready`
  when its inputs change underneath it.

In CI (`build` job):

- `test/SimpleRisc.hs` `prop_boot_rom_identity_and_crc_upload` runs the real ROM
  image through the core simulator over the simulated UART.

Not in CI before this page: the exhaustive decoder check, the architecture
tests, **any `U` upload in generated RTL**, and any physical `U` upload.
`--loader-command` offered only `R`, `D` and `H`. The RTL gap is now closed;
see "A framed-upload RTL regression" below.

## Status: implemented, host- and RTL-verified, not hardware-qualified

The 2026-10-28 bounded probe (a four-byte NOP payload, never executed) found
that `U` returns `ERR HDR` on the controlled-benchmark **baseline** image at both
0 ms and 3 ms per-byte pacing, while the **combined** image accepts the identical
frame and returns the expected CRC `63e8276d`. Both images answered `I` with a
valid `SRID1` line. A full-size 153,280-byte classifier image failed the same
way on the same baseline bitstream. Evidence:
[`upload-probe.json`](evidence/2026-10-28-controlled-benchmark/hardware/upload-probe.json)
with `probe_upload.py` beside it, and
[`crc-upload-attempt/`](evidence/2026-10-28-controlled-benchmark/hardware/crc-upload-attempt/)
for the full-size attempt.

**The cause is still open.** What follows is what has been eliminated.

### The two builds differ in exactly two variables

`inputs.json` for both images records every build input by hash. Comparing them,
`memory.v`, `sdram.v`, `burst_memory.v`, `pipeline_cache.v`, `clock_bridge.v`,
`pll.v`, `pins.cst` and `clocks.sdc` are **byte-identical**. Only these differ:

| | baseline (`ERR HDR`) | combined (`OK`) |
|---|---|---|
| generated CPU RTL | `045755aa…` (compressed BTB lookup disabled) | `b2db3d0b…` (production) |
| cache geometry | `LINE_BITS(12), WAYS(1)` | `LINE_BITS(11), WAYS(2)` |

### Eliminated

1. **The ROM.** The two `bootrom-sdram.hex` images are identical in all 508 code
   words and in words 508/509; they differ only in words 510/511, the stamped
   build id. That is expected, because `sdram/build.sh` re-stamps those words
   from `compute_build_id` over *every* build input. So the same ROM bytes and
   the same host code succeed on one image and fail on the other.
2. **The CRC convention.** The ROM's word-wise `crc32_word`, the host's
   `zlib.crc32`, and the new testbench's byte-wise `crc32_update` all give
   `727fbcc5` for `magic ‖ count=1`, and all give `63e8276d` for the NOP
   payload — the value the combined image actually acknowledged on hardware.
3. **A receive timeout.** The header path reports `ERR TMO`, not `ERR HDR`, so
   the bytes arrived and were read; they simply did not match.
4. **RX FIFO overrun / bandwidth.** It fails at 3 ms per byte as well as at
   0 ms. At 3 ms per byte the ROM has roughly 144,000 cycles per byte against a
   32-byte FIFO, and the whole 21-byte probe frame fits the FIFO even sent at
   once.
5. **General RX-path or ROM-execution breakage on that bitstream.** Legacy
   `Q`/`V`/`H` with the 153,280-byte classifier image, including XOR readback
   verification, succeeded three times on the *same* baseline bitstream in the
   same session. The divergence is confined to the 12-byte `U` header window.
6. **The cache geometry.** Production RTL passes the framed upload at the
   baseline's exact `WAYS(1)/LINE_BITS(12)`, and at `WAYS(1)`/`WAYS(2)` ×
   `LINE_BITS(7)` — a deliberately tiny cache that maximises refill holds while
   the UART is receiving.
7. **The prediction-off change, on current source.** Re-applying the baseline's
   exact one-line change (`&& not (cpuCompressed machine)` on the BTB hit
   condition) to today's `src/SimpleRisc.hs` and regenerating does **not**
   reproduce the failure: the framed upload passes, both with the functional
   memory and through the real burst controller and SDRAM pin model at the
   hardware's 48 MHz and 135-degree phase.
8. **A simulation/synthesis divergence from Clash's standing
   `integerToInt#` warning.** Generating either top entity prints
   `Dubious primitive instantiation for GHC.Num.Integer.integerToInt#`, which is
   the kind of warning that could make RTL simulation pass where hardware fails.
   It is not the cause here: it appears twice (once per top entity) in *every*
   archived generation log, identically in the failing baseline
   (`generate-off.log`) and the succeeding combined
   (`prepare-check-generate-on.log`), and in the accepted `fprisc-48` preset
   build that passed the full physical example suite. Clash does not name a
   source location; the `Int`-typed literal arguments in `RiscVCompressed`
   (`sext :: Int -> …`, `field n mask`) are a plausible origin, but that is an
   inference, not a verified attribution. It is worth pinpointing or silencing
   anyway, so that a genuine future `Integer` leak into hardware is not masked
   by a warning that is always there.

### What remains

- **The archived baseline CPU RTL at revision `b33a844`.** That revision predates
  the stage-token/payload split (`aedc547`), the free-running DSP operand and
  product registers (`4a84990`) and the registered one-hot cache-return select
  (`5d308d6`). A latent defect in the compressed mispredict/redirect path there
  could since have been incidentally fixed. Simulating the archived
  `cpu-off.v` directly needs the fence monitor stripped, because its probes are
  hard-wired to the *current* generated `Machine` packing; that run was started
  but not completed, so this candidate is **untested, not excluded**.
- **Physical behaviour of that specific placement.** SDRAM I/O timing is still
  `pending_vendor` and unconstrained at the pins, and the functional pin model
  cannot represent a marginal setup/hold window. The
  [independent timing review](2026-10-28-INDEPENDENT-TIMING-REVIEW.md) makes the
  same caveat.

The mechanism that would fit every observation above is a mispredict/redirect
defect: `crc32_word` is a 32-iteration loop, so the header window executes 64
taken backward branches. With BTB hits disabled none is ever predicted taken,
so all 64 redirect; production trains the entry after about one iteration. That
is consistent with `Q`/`V`/`H` surviving (its per-word loop trains the BTB) and
with the failure being confined to the header. It is a hypothesis, not a result.

Until it is reproduced and explained, `U` must be treated as unqualified:
`run_program.py` stays on `--protocol p`, and accepted physical results keep
using legacy `Q`/`V`/`H` with readback verification. Dependability priority 2's
criterion — each negative test followed by a successful upload and run **without
manually reprogramming the FPGA** — is met in the native ROM tests, the host
library tests and now generated RTL, and remains unmet on silicon.

### Two robustness gaps this investigation exposed

- **`fifoStep` silently drops a byte when the RX FIFO is full.** There is no
  overrun flag and no NACK, so the only symptom of a lost byte is a downstream
  `ERR HDR` or `ERR CRC`. Nothing observed here proves that happened, but a
  large frame sent at 0 ms pacing during a long refill storm is exactly the case
  where it could. An RX-overrun bit in UART STATUS plus a distinct ROM reply
  would make that visible instead of indistinguishable from corruption.
- **`ERR HDR` conflates two different failures** — a magic mismatch and a header
  CRC mismatch. That single ambiguity is what made this investigation expensive.
  Splitting it into two replies costs a handful of ROM bytes and would have
  localised the fault on the first probe.

## A framed-upload RTL regression

`check_pipeline_rtl.py --loader-command U` now drives the whole protocol against
the generated RTL: `I` and a checked `SRID1` line, the `U` frame with both
CRC-32s computed in the testbench, the `OK <crc>` ack, a `C` readback compared
against the same CRC, a guarded `G` start, then the guest running to its trap
and `DONE`, with every uploaded word and the zero sentinel verified in backing
memory. A magic, header-CRC, length, payload-CRC or readback mismatch, or an
`ERR` of any kind, is fatal and the ROM's reply is echoed.

Passing as of this page, on freshly generated IM and IMC RTL:

| configuration | result |
|---|---|
| IMC, `WAYS(2)/LINE_BITS(11)` (production 64 KiB) | pass |
| IMC, `WAYS(1)/LINE_BITS(12)` (the baseline geometry) | pass |
| IMC, `WAYS(2)/LINE_BITS(7)` and `WAYS(1)/LINE_BITS(7)` (conflict stress) | pass |
| IMC, `WAYS(1)/LINE_BITS(12)`, pin model at 48 MHz / 135 degrees | pass |
| IMC, prediction-off source change, with and without the pin model | pass |
| IM, `WAYS(2)/LINE_BITS(7)` — reports `isa=rv32im` | pass |

CI runs the IM and IMC framed upload at `WAYS(1)/LINE_BITS(12)` and
`WAYS(1)/LINE_BITS(7)`. The existing `R`, `D`, `H` and executing-guest modes
still pass unchanged; note that guest mode must **not** be run with
`--uart-bit-cycles 32`, because accelerating the UART removes the TX
backpressure its `ready_stalls` coverage leg requires.

## Reproduce

```bash
# the actual ROM C, both variants, natively
python3 boards/tangnano20k/bootrom/check_loader.py

# the host library
python3 boards/tangnano20k/test_upload.py

# the manifest / build-id contract
python3 -m unittest discover -s boards/tangnano20k/sdram -p test_preset_manifest.py

# rebuild both committed ROM images (needs riscv64-unknown-elf-gcc)
boards/tangnano20k/bootrom/build.sh

# identify a board without uploading
python3 boards/tangnano20k/run_program.py --identify --port auto --freq-mhz 48

# a CRC-verified upload and guarded start
python3 boards/tangnano20k/run_program.py IMAGE.bin --protocol u --freq-mhz 48
```

The framed-upload RTL regression, on freshly generated IMC RTL:

```bash
cabal run clash -- -isrc -hide-package simple-risc -DRISCV_COMPRESSED \
  src/SdramPipeline.hs --verilog -fclash-clear -outputdir "$PWD/output/framed"

# the baseline's cache geometry, then the tiny-cache conflict stress
python3 boards/tangnano20k/sdram/check_pipeline_rtl.py \
  --generated "$PWD/output/framed/SdramPipeline.topEntity" --compressed \
  --boot-loader --loader-command U --uart-bit-cycles 32 \
  --cache-ways 1 --cache-line-bits 12

# the highest local fidelity: real burst controller plus functional SDRAM pins
# at the hardware's clock and phase
python3 boards/tangnano20k/sdram/check_pipeline_rtl.py \
  --generated "$PWD/output/framed/SdramPipeline.topEntity" --compressed \
  --boot-loader --loader-command U --uart-bit-cycles 32 \
  --cache-ways 1 --cache-line-bits 12 \
  --pin-model --pin-freq-mhz 48 --pin-phase-degrees 135
```

Re-running the same investigation against the archived baseline build needs its
recorded inputs, all of which are in the evidence directory and hash-match
`inputs.json`: `cpu-off.v.gz` for the CPU, `cache.v` for `pipeline_cache.v`, and
`hardware/baseline/bootrom-sdram.hex` for the ROM. `clock_bridge.v`, `sdram.v`
and `burst_memory.v` are unchanged since. The testbench's fence monitor must be
stripped first, because its probes are hard-wired to the current generated
`Machine` packing.
