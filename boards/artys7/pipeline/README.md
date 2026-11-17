# simple-risc on the Arty S7-50 with DDR3

The fprisc-81 shape (RV32IM SDRAM-pipeline core, two-way 64 KiB cache, clock
bridge) with the Tang Nano's SDRAM controller replaced by `ddr3_line_memory.v`
over the standalone LiteDRAM core from `../litedram` (run its `build.sh` once).
CPU 81 MHz from the 12 MHz oscillator; memory 80 MHz, LiteDRAM's user clock.
The CPU is held in reset until DDR3 calibration finishes.

```sh
CPU_MHZ=81 ./build.sh   # -> output/artys7/pipeline-81/{top.bit,build-manifest.json}
openFPGALoader -b arty_s7_50 --ftdi-serial 210352B840A3 output/artys7/pipeline-81/top.bit
```

`build.sh` passes yosys `-nosrl`: with SRL inference, `synth_xilinx` maps some
of the Clash core's pipeline registers (reset to partly-x values) into SRL16E
shift registers that do not behave like the RTL. A gate-level simulation of
the synthesized core reproduced the board failure exactly; `-nosrl` alone
fixed it. `build-manifest.json` (preset `arty-s7-81`) is what FP-RISC's
`machine/tangnano20k/examples.sol --target board --preset arty-s7-81` checks.

The board's FTDI bridge drops what is written in roughly the first second after
the port opens: run the Tang Nano check scripts with
`SIMPLE_RISC_PORT_SETTLE=1`, e.g.

```sh
SIMPLE_RISC_PORT_SETTLE=1 python3 boards/tangnano20k/check_processor.py \
  --port /dev/cu.usbserial-210352B840A31 --freq-mhz 81
```

Results 2026-11-17/18 at CPU 81 / memory 80: CPU clock 99.6 MHz (nextpnr);
check_processor, check_rv32m (30,720) and check_rv32i (38,400) pass; the FP-RISC
example suite passes 7/7 (classifier 6.73 s a run).

`ddr3_line_memory_tb.v` checks the adapter against a random native-port model
(20,000 operations). `sim/burst_memory_ddr3.v` is a stand-in with the Tang
Nano burst memory's name and ports (the adapter plus a behavioural LiteDRAM
port), and `sim/burst_memory_with_adapter.v` is it concatenated with the
adapter, for `boards/tangnano20k/sdram/check_pipeline_rtl.py --burst-rtl`.
