# The SG90 servo commit and fprisc-84 timing

Kind: regression diagnosis and fix, 2026-11-22. Follows
[FPRISC-84](2026-11-08-FPRISC-84.md) and the servo commit `6abaea1` ("Add
SG90 PWM peripheral for Spectre-84", with qos `af60cb4`).

## Result

`6abaea1` made the stock fprisc-84 build fail timing, although the stock
image contains no servo logic at all. Two edits in that commit changed the
stock core's Clash netlist:

1. `decodeTarget` mapped one more I/O word for every image
   (`ioBase + 12` became `ioBase + 16`), and
2. the core's `topEntity` gained the `servo_write`/`servo_width` ports and the
   servo binding. In the stock top they are unconnected, so synthesis drops
   them, but the renamed and reordered Clash nets alone still map differently.

Stock synthesis went from 12,771 to 12,780 logic and CLS from 8,053 to 8,145.
Placement 3 then missed 84 MHz on the BTB loop, the loop already known to be
the limit: BTB RAM `DO` → 8-cell carry chain (the tag compare) → `hit`
(fanout 44) → BTB address `ADB`. 6 endpoints failed. Evidence:
[stock-head worst path](evidence/2026-11-22-servo-timing/stock-head-worst-path.txt).

The fix puts both edits behind `-DSDRAM_SERVO`, which `build.sh` passes when
`SDRAM_SERVO=1`, into its own generated directory (`SdramPipeline-0-servo`).
The stock core's Clash Verilog is again identical to the pre-servo
`e10a76a` output, apart from source-location comments. The stock build
reproduces the qualified implementation exactly. The servo image's Verilog
is identical to `6abaea1`'s, so it stays the image that drove the SG90 on the
board on 20 to 22 November.

| Build (placement 3 unless noted) | Logic | CLS | Fmax | Worst slack |
|---|---:|---:|---:|---:|
| fprisc-84 qualified (`3b4052d`) | 12,771 | 8,053 | 86.021 | +0.280 |
| stock at `6abaea1` | 12,780 | 8,145 | 83.015 | **−0.141** (6 endpoints) |
| stock, decode reverted only, servo ports kept | 12,807 | 8,052 | 85.108 | +0.155 |
| **stock, this fix** | **12,771** | **8,053** | **86.021** | **+0.280** |
| servo at `6abaea1` (`SDRAM_SERVO=1`) | 12,865 | 8,114 | 84.357 | +0.050 |
| servo, request and PWM registered (trial, not kept) | 12,906 | 7,976 | 82.948 | −0.151 |
| **servo, this fix** (same Verilog as `6abaea1`) | 12,865 | 8,114 | **84.357** | **+0.050** |

The other placement options (PnR only, same netlist,
[timing.txt](evidence/2026-11-22-servo-timing/timing.txt)):

| Netlist | p0 | p1 (= p2) | p3 | p4 | Passes |
|---|---:|---:|---:|---:|---:|
| fprisc-84 qualified | | | +0.280 | | 4 of 4 ([FPRISC-84](2026-11-08-FPRISC-84.md)) |
| stock at `6abaea1` | +0.160 | +0.047 | −0.141 | +0.045 | 3 of 4 |
| servo at `6abaea1` = this fix | −0.397 | +0.017 | +0.050 | +0.152 | 3 of 4 |
| servo, registered trial | +0.010 | −0.006 | −0.151 | +0.049 | 2 of 4 |

## What was tried and not kept

The servo request leaves the core combinationally: the late cache hold,
the I/O bus state and a 32-bit address compare feed the PWM block's
`pending_us` enable from outside the floorplan regions. That looked like the
obvious culprit. Registering it at the core boundary (`delay`), and
registering `servo_pwm`'s width check and pin, does not appear among the
failing paths either way. It made the distribution worse (2 of 4) and lost
placement 3, the preset's option, so it was reverted. None of the failing
paths, before or after, touch servo logic. They are the core's own fetch and
BTB loops, and their margin at 84 MHz is a placement draw that any netlist
change re-rolls. This repeats the 2026-11-09 lesson that seven cells moved
placement 3 by 1.2 ns.

## Board

Both final images were loaded to FPGA SRAM, and the board was then
reconfigured from flash (System.qa).

- Stock: processor check, 30,720 RV32M and 38,400 RV32I checks at 84 MHz pass.
- Servo: processor check and 7,680 RV32M checks pass. The qos probe
  `hal/spectre/actors/servo/board-servo.c` had all five writes (1500, 1400,
  1600, 1500, 0 µs) accepted and reported DONE with PWM disabled
  ([log](evidence/2026-11-22-servo-timing/servo-probe-board.log)). Nobody
  watched the servo horn this time. The physical movement record is qos's
  servo README, on the same Verilog.

`cabal test` passes (75 + 8 + 6 + 3). That includes
`prop_sdram_spi_survives_cache_holds`, whose `decodeTarget (ioBase+16) ===
UnmappedTarget` the servo commit had broken, and a new
`prop_sdram_servo_write_is_answered`. The new
`boards/tangnano20k/sdram/servo_pwm_tb.v` checks widths, invalid and
high-bit commands, disable, frame-boundary latching and reset. It passes, and
fails a width-check mutant.

## Open

- The servo image is a 3-of-4 netlist with +0.050 ns at its placement. It
  passes, but it is not qualified the way fprisc-84 was. Making it robust is
  the canon's own problem: area and loop wire length (AMENDED-PROPOSAL).
  Moving servo logic around does not fix it.
- The stock and servo images share a ROM build id (both `33394a20cd85190e`
  from one tree). The manifest does not record `SDRAM_SERVO`, so the fprisc
  runner and `--manifest` checks cannot tell them apart.
- qos's servo HAL uses a compile-time `SPECTRE_SERVO_MMIO`. On a stock image
  the write at `ioBase+16` is unmapped and faults. The SDK proposal's board
  capability identifier would close that.

Builds: `output/tangnano20k/motor-timing-20261122/{stock,servo}-{head,fix,final}`
and `sweep/`.
