# SimpleRisc block-RAM core on the Arty S7-50

The same Clash core as the Tang Nano's block-RAM image
(`boards/tangnano20k/top.v`), wrapped for the Arty S7-50 and built with the
open-source openXC7 flow (see `../blink-echo/README.md` for the toolchain).

- An `MMCME2_BASE` makes the core clock from the 12 MHz oscillator
  (`FREQ_MHZ`, default 54: x63 / 14, VCO 756 MHz).
- The UART runs at `FREQ_MHZ * 1e6 / 868` baud, as on the Tang Nano
  (62,212 baud at 54 MHz); the board scripts take `--freq-mhz`.
- BTN0 resets the core. LED 0 is a heartbeat, LED 1 lights when the core is
  out of reset. There is no microSD slot, so the SPI port is tied off.

```sh
boards/artys7/core/build.sh                    # -> output/artys7/core-54/top.bit
openFPGALoader -b arty_s7_50 --ftdi-serial 210352B840A3 output/artys7/core-54/top.bit
python3 boards/tangnano20k/check_processor.py --port /dev/cu.usbserial-210352B840A31 --freq-mhz 54
```

Results 2026-11-17 at 54 MHz: 97.09 MHz Fmax; 16 RAMB36 + 1 RAMB18,
4 DSP48E1, ~9,700 flip-flops. On the board (FPGA SRAM): `check_processor.py`,
`check_rv32m.py` (30,720 checks) and `check_rv32i.py` (38,400 checks) pass.
