# The fprisc-72 preset: CPU 72 / SDRAM 48 MHz on the board

Kind: preset, board run and historical comparison, 2026-11-01. Core: HEAD
d86cc47 (4-entry return stack, 128-entry BTB; the core is unchanged since
9fe276d). FP-RISC: main f3802f5 plus the working tree's list-fusion edits
(they do not change the classifier image: both runs below produced image
`1fb8dcafd0d4`).

## Result

`SDRAM_PRESET=fprisc-72` builds the CPU at 72 MHz behind the clock bridge
with the SDRAM at 48 MHz, and passes internal timing at 74.6 MHz (0.488 ns
spare). FP-RISC's whole Tang Nano suite passes on it through the regular
runner (`--preset fprisc-72`): hello, numeric, collections, host files,
arguments, `wc`, and the ten-run 512/128-row classifier, every run matching
the independent reference.

The earlier 72 MHz image (CPU 72 / SDRAM 54, 2026-10-20) was rejected for
this classifier because it intermittently produced a wrong tree. This one
gave the right answer in all 43 classifier runs on 2026-11-01 (30 of
today's binary, 10 of the 20 October binary, 3 of the smaller classifier).

## The preset

| Setting | fprisc-48 | fprisc-72 |
|---|---|---|
| CPU / SDRAM clock | 48 / 48 MHz | 72 / 48 MHz (clock bridge) |
| Cache | 64 KiB, one-way, 4096 lines | 64 KiB, two-way, 2048 lines per way |
| Memory phase | 135 degrees | 135 degrees |
| Placement, placer target | 2, 48 MHz | 0, 79 MHz |
| Map / route / route fan-out | defaults | 3 / 1 / 8 |

Both presets refuse conflicting settings, RTL and ROM overrides and what-if
constraints (`SDRAM_EXTRA_SDC`). `preset_manifest.py` records the preset's own
configuration, ROM identity (CPU 72, memory 48) and runs the timing gate at
both clocks. The output is `output/tangnano20k/fprisc-72/`.

```sh
SDRAM_PRESET=fprisc-72 boards/tangnano20k/sdram/build.sh
# from fprisc:
python3 tools/run_tangnano20k_examples.py --target board --preset fprisc-72 \
  --fpga-manifest ../simple-risc/output/tangnano20k/fprisc-72/build-manifest.json
```

## Compared with earlier weeks

All on the board, median of each run's repeats.

**512/128-row classifier** (16 bins, depth 6, ten runs, heap reporting on):

| Date | Image | Binary | Per run |
|---|---|---|---:|
| 2026-10-20 | 48/48, accepted | 20 Oct, collector | 12.92 s |
| 2026-10-21 | fprisc-48 preset | 21 Oct | 12.90 s |
| 2026-10-20 | 72/54, rejected (wrong trees) | 20 Oct, collector | 8.80 s |
| 2026-11-01 | fprisc-72 | 20 Oct, collector | **7.16 s** |
| 2026-11-01 | fprisc-72 | today, regions | 8.49 s |

**128/64-row classifier** (8 bins, depth 5):

| Date | Image | Per run |
|---|---|---:|
| 2026-10-18 | 48 MHz, no cache | 4.76 s |
| 2026-10-18 | 72 MHz, no cache | 6.61 s |
| 2026-10-19 | 72/54, one-way cache | 2.84 s |
| 2026-11-01 | fprisc-72, today's binary | 2.17 s |

What changed:

- **Hardware: 1.23x faster at the same clock, and correct.** The same
  20 October binary runs 8.80 s on its own 72/54 image and 7.16 s on
  fprisc-72, although the SDRAM now runs at 48 MHz instead of 54. That
  includes the predictor work (return stack, straddling branches, early
  correction, 128-entry BTB) and the cache and bridge changes since
  20 October; this comparison does not split them. Against the accepted
  48 MHz image the same workload is 1.80x faster.
- **Software: today's FP-RISC build is 1.19x slower on this classifier.**
  On the same fprisc-72 image, the 20 October binary takes 7.16 s and today's
  8.49 s (8.34 s without heap reporting), although today's image is half the
  size (74 KB against 152 KB). The likely candidates are the change from the
  conservative collector to compiler-placed regions (182 MB reclaimed over
  ten runs) and code generation changes since; this run does not separate
  them.
- **Overall:** today's binary on today's board is 1.52x faster than the
  accepted 48 MHz setup of 20-21 October, and 1.31x faster than 19 October's
  72/54 image on the smaller classifier.

## Open

- SDRAM I/O and PVT remain unqualified, as for every preset.
- The FP-RISC slowdown on the classifier is worth bisecting: rebuilding the
  20 October source with today's compiler, with and without regions, would
  locate it. Recovering it would make today's board about 1.8x the accepted
  48 MHz setup.

## Evidence

[evidence/2026-11-01-fprisc-72/](evidence/2026-11-01-fprisc-72/): the preset
`build-manifest.json`, `timing.txt`, the suite's `suite-results.json` and
`classifier-results.json`, `classifier-128-results.json`, and
`old-binary-on-new-fpga.log` (the 20 October binary on fprisc-72).
