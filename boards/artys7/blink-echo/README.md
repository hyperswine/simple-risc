# Arty S7-50 blink + UART echo

Bring-up design for the Digilent Arty S7-50 (XC7S50-1CSGA324), built with the
open-source openXC7 flow: yosys, nextpnr-himbaechel (xilinx uarch) and
Project X-Ray. LED 0 blinks at 1 Hz from the 12 MHz oscillator; the USB UART
(115200 8-N-1) echoes every byte and sends `ARTY S7 ECHO READY` once after
configuration; LED 1 toggles per received byte, LEDs 2-3 show its low bits.

```sh
./build.sh                                   # -> build/top.bit
openFPGALoader -b arty_s7_50 build/top.bit   # FPGA SRAM (lost at power-off)
openFPGALoader -b arty_s7_50 -f build/top.bit  # SPI flash (boots on power-up)
python3 test_echo.py --program openFPGALoader -b arty_s7_50 build/top.bit
BANNER_WAIT=15 python3 test_echo.py --program openFPGALoader -b arty_s7_50 -r
```

Add `--ftdi-serial 210352B840A3` when the Tang Nano's FTDI is also plugged in.
Ports: `/dev/cu.usbserial-210352B840A30` is JTAG, `...A31` the UART.

Toolchain (`~/Documents/Libs/openxc7`, `OPENXC7` overrides):

- `nextpnr/` is openXC7/nextpnr built with `-DARCH=himbaechel
  -DHIMBAECHEL_UARCH=xilinx -DHIMBAECHEL_XILINX_DEVICES=xc7s50` and
  `HIMBAECHEL_PRJXRAY_DB` pointing at the database below. (The older
  openXC7/nextpnr-xilinx repository is archived.)
- `nextpnr-xilinx/xilinx/external/prjxray-db` is the Project X-Ray database
  (`spartan7/xc7s50csga324-1`).
- `prjxray/` is f4pga/prjxray: `build/tools/xc7frames2bit` (built with
  `CMAKE_POLICY_VERSION_MINIMUM=3.5` for CMake 4) and `utils/fasm2frames.py`.
- `venv/` is Python 3.13 with fasm (pure-Python parser), simplejson, pyyaml,
  intervaltree and textx.
- yosys comes from oss-cad-suite.

Results 2026-11-17: 288 MHz Fmax (12 MHz needed), about 60 LUTs and 114
flip-flops. From SRAM and from flash, the banner arrives and 2,000 echoed
bytes (every value 0-255 plus a random stream) match exactly. A flash boot
takes about 6.3 s, because the bitstream carries no SPI x4 or faster
configuration clock setting.
