# Step 2: standalone LiteDRAM core for simple-risc

`arty_s7.yml` generates `build/gateware/litedram_core.v` with `litedram_gen`:
the A7 PHY and controller for the Arty S7-50's DDR3L at 80 MHz (640 MT/s), an
embedded VexRiscv that calibrates at reset (its console on `uart_tx`), and one
native user port: 24-bit line address (2^24 x 16 bytes = 256 MiB), 128-bit
read/write data (one 16-byte cache line per access), 16-bit byte write mask,
`init_done` / `init_error`, in the `user_clk` / `user_rst` domain.

`top.v` is a board test: after calibration it writes 4096 lines at addresses
`i ^ (i << 12)` (every address bit) through the native port, reads them back,
compares, and prints `NATIVE PASS 04096` or `NATIVE FAIL <line>` on the UART.
`arty-s7-50-ddr3.xdc` holds the DDR3, clock, reset, UART and LED pins, taken
from LiteX's Arty S7 platform.

```sh
./build.sh                  # regenerates the core, -> build/gateware/test.bit
openFPGALoader -b arty_s7_50 --ftdi-serial 210352B840A3 build/gateware/test.bit
```

Result 2026-11-17: 106.79 MHz on the 80 MHz controller clock; on the board the
core calibrates (15+-8, 16+-9), its 2 MiB memtest passes, and the native-port
test prints `NATIVE PASS 04096`.

`top_rand.v` (`TOP=top_rand SKIP_GENERATE=1 ./build.sh`, then load
`build/gateware/top_rand-test.bit`) drives `../pipeline/ddr3_line_memory.v`
with random masked word writes and line reads over 64 lines, checked against a
shadow copy, and prints `RAND PASS <ops>` every second (or `RF ...` and stops on
a mismatch). 2026-11-17: about 42 million operations clean.

Step 3, the adapter to simple-risc's cache, is `../pipeline`.
