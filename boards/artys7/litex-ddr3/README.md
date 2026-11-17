# Step 1: LiteX DDR3 on the Arty S7-50, open-source flow

LiteX's `digilent_arty_s7` target (VexRiscv, A7DDRPHY, MT41K128M16) generates
the SoC Verilog, constraints and BIOS with `--no-compile-gateware`; `build.sh`
then runs yosys -> nextpnr-himbaechel (xilinx) -> Project X-Ray.
`read_boot.py` loads a bitstream while listening at 115200 and can run BIOS
console commands (`COMMANDS="mem_test 0x40000000 0x10000000"`).

```sh
SYS_MHZ=80 ./build.sh       # -> build-80mhz/gateware/top.bit
COMMANDS="mem_test 0x40000000 0x10000000" CMD_WAIT=240 python3 read_boot.py 30 \
  openFPGALoader -b arty_s7_50 --ftdi-serial 210352B840A3 build-80mhz/gateware/top.bit
```

LiteX lives in `~/Documents/Libs/litex` (litex_setup.py --config=standard, a
Python 3.13 venv with meson). nextpnr ignores the XDC's INTERNAL_VREF, but its
FASM writer turns on the bank's 0.675 V reference for any SSTL input, and it
writes IN_TERM for HR banks, so the A7 PHY's needs are covered.

Results 2026-11-17:

| System clock | DDR3 | Timing | Board |
|---|---|---|---|
| 100 MHz | 800 MT/s | 98.77 MHz, fails by 1.2% | calibrates, 2 MiB memtest OK, 40.8/48.7 MiB/s |
| 80 MHz | 640 MT/s | 102.52 MHz, passes | calibrates (15+-8, 16+-9), **all 256 MiB memtest OK**, 32.8/39.0 MiB/s |
