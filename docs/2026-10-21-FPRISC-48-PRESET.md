# FP-RISC 48 MHz development preset

Kind: implementation and physical validation report. Applies to the standalone
SimpleRisc checkout and sibling FP-RISC checkout on 2026-10-21.

```sh
SDRAM_PRESET=fprisc-48 boards/tangnano20k/sdram/build.sh
```

The preset selects RV32IMC, CPU/SDRAM 48/48 MHz, 8 MiB SDRAM, a 64 KiB
write-update cache, 135-degree memory phase and Gowin placement option 2.
It rejects conflicting configuration and external RTL overrides. A fresh
build manifest remains incomplete until source generation, placement and
the internal setup/hold gate pass; it records source and artifact hashes.

The successful Gowin build reports 55.269 MHz Fmax under the 48 MHz
constraint, +2.740 ns worst setup slack and zero setup/hold violations.
Its bitstream SHA256 is
`30a3f82d8249fe1db0e35c51e7b3b9abb269b729e6b16b60ded71fdf57d986c3`.
The earlier license-server failures cleared on retry. SDRAM I/O/PVT
qualification remains open; internal STA is not electrical signoff.

From the sibling `fprisc` checkout, the new image was loaded and tested with:

```sh
python3 tools/run_tangnano20k_examples.py --target board \
  --fpga-manifest ../simple-risc/output/tangnano20k/fprisc-48/build-manifest.json \
  --out build/tangnano20k-examples/board-fresh-20261021
```

All seven cases passed: hello, numeric, collections, host services, arguments,
word count and classifier. Every guest exited successfully and returned to
ROM `DONE`. The ten classifier runs matched the independent reference,
taking 12.877–13.472 seconds each. They completed 22 collections, reclaimed
172,795,360 bytes and stayed within the 8,060,224-byte usable heap bound.
FPGA SRAM was programmed; flash and SD were unchanged. The board was left
idle on the new image.

The [evidence manifest](evidence/2026-10-21-fprisc-48/manifest.json) hashes
the build log, complete timing report, source/build manifest, board result,
programming log and classifier evidence. `board-summary.json` is a copy of
the FP-RISC summary; its own file references resolve in the sibling
`fprisc/docs/evidence/2026-10-21-tangnano20k-preset/fresh-board/` directory.
These are historical evidence snapshots, not loadable build directories.
Generated bitstreams remain in ignored `output/`.
