# Controlled FP-RISC classifier benchmark (2026-10-28)

Kind: experiment. Applies to SimpleRisc `9d29a6b746c4472795ac56516c96b2096e6b70b8`, with benchmark tooling added in this working tree.

The three recent optimizations reduce cycles by **7.52% together** (1.081x throughput) on one fixed small-classifier binary in RTL simulation. Compressed branch prediction provides the largest gain: **5.63–5.74%**. Equal-capacity two-way caching contributes **1.46–1.64%**, and the faster clock bridge **0.35–0.46%**. These ranges compare each change at all four settings of the other two factors; they are not statistical confidence intervals.

## Eight-case simulation matrix

All eight runs pass the independent Python classifier reference and `FPR EXIT 0`, with identical semantic output: 23 nodes, depth 5, training 124/128 with digest 21562, testing 61/64 with digest 909572, and root column 1 at approximately 0.750635343138128. Each case is a fresh deterministic simulation; the resume check subsequently verified all eight receipts, executable hashes, output hashes and shared controls.

| Compressed BTB | Ways | Bridge | Window cycles | Time at 72 MHz | Held cycles | Window refills | Execute redirects |
|---|---:|---|---:|---:|---:|---:|---:|
| off | 1 | old | 147,311,824 | 2.045998 s | 9.25% | 331,247 | 7,498,287 |
| off | 1 | new | 146,658,181 | 2.036919 s | 8.85% | 331,244 | 7,498,288 |
| off | 2 | old | 145,033,434 | 2.014353 s | 7.82% | 260,288 | 7,498,287 |
| off | 2 | new | 144,522,898 | 2.007262 s | 7.50% | 260,285 | 7,498,286 |
| on | 1 | old | 139,011,270 | 1.930712 s | 9.80% | 330,979 | 6,566,918 |
| on | 1 | new | 138,367,282 | 1.921768 s | 9.38% | 330,976 | 6,566,916 |
| on | 2 | old | 136,727,566 | 1.898994 s | 8.29% | 260,073 | 6,566,918 |
| on | 2 | new | 136,227,643 | 1.892051 s | 7.96% | 260,069 | 6,566,913 |

The baseline-to-combined saving is 11,084,181 cycles. Prediction cuts execute redirects from about 7.50 million to 6.57 million, while leaving the classifier results intact. Two-way caching reduces window refills from about 331,000 to 260,000. With prediction on and the new bridge, whole-run code refills fall from 73,445 to 26,084; those code counters include startup, unlike the window-refill column above.

## Physical confirmation at 48/48 MHz

Three alternating baseline/combined pairs pass on the Tang Nano 20K, using the exact same guest bytes and a fresh upload after each SRAM-only programming operation. Both images use 48 MHz CPU and memory clocks, phase 135 degrees and Gowin placement option 2. Baseline is prediction off / one-way; combined is prediction on / two-way. The clock bridge is bypassed at this clock setting.

| Configuration | Corrected times, seconds | Median | Internal Fmax | Worst setup slack |
|---|---|---:|---:|---:|
| baseline | 2.9950530, 2.9950515, 2.9950545 | 2.995053 s | 51.682 MHz | +1.484 ns |
| combined | 2.8052550, 2.8052565, 2.8052550 | 2.805255 s | 51.281 MHz | +1.333 ns |

Both timing reports have zero setup and hold violating endpoints under the supplied internal constraints. The median measured interval drops by **6.34%**. This is a separate clock ratio and measurement interval from the 72/54 MHz simulation, so it is not expected to reproduce the simulation percentage exactly. The frozen guest timer was compiled for 72 MHz; each physical `elapsed_us` is multiplied by 72/48. The interval includes ordinary UART output but ends before printing elapsed time and exit.

The physical comparisons use legacy `Q/V/H` upload with readback verification for **both** configurations. The first attempt through `U` on the experimental prediction-off baseline was rejected with `ERR HDR` before guest execution. That failure and successful restoration were retained, and no physical time was accepted from it. Upload behavior is separate from the successful classifier results; it needs follow-up before treating these images as release candidates.

A bounded follow-up used a four-byte NOP payload without executing it. The prediction-off baseline returned `ERR HDR` for both bulk transmission and 3 ms per-byte pacing. The combined prediction-on image accepted both and returned the expected CRC `63e8276d` through `C` readback. Identity queries confirmed 48/48 MHz on both. This isolates a difference between the experimental images; it does **not** establish the root cause or qualify a full-sized CRC upload on the combined image. The accepted image was restored again after the probe. See the [upload probe](evidence/2026-10-28-controlled-benchmark/hardware/upload-probe.json).

The known-good `fprisc-48` image, SHA-256 `30a3f82d8249fe1db0e35c51e7b3b9abb269b729e6b16b60ded71fdf57d986c3`, was restored and its UART diagnostic passed. The accepted preset and flash/SD contents are unchanged. The first combined Gowin attempt failed because the license server did not respond; an unchanged retry built successfully and passed timing.

See [physical results and restoration receipt](evidence/2026-10-28-controlled-benchmark/hardware/board-results.json), all six UART logs, complete timing reports and build-input hashes under the same evidence directory.

## Controls and measurement boundaries

- One unchanged 153,280-byte RV32IMC Base+GC guest, SHA-256 `f8abaa0ed11ef3e2576f4ccceccf33948982557c05c17927b15e9e62e4c9a9af`; train128/test64/bins8/depth5/minLeaf2, existing 48-step entropy calculation. The compiler was not rebuilt.
- CPU/SDRAM clocks fixed at 72/54 MHz, identical initial state and clock phase relationship in simulation. These clock rates are experimental and are not a new board qualification.
- Cache fixed at 64 KiB, 16-byte lines, four posted writes, write-update enabled. One-way uses `LINE_BITS=12`; two-way uses `LINE_BITS=11`.
- Prediction-off uses a source snapshot with one extra `not (cpuCompressed machine)` condition on BTB lookup hits. Production Haskell is unchanged. Prediction-on RTL is tied to the fresh generation recorded by the earlier formal/RTL evidence.
- The old bridge is the exact source from `417053d3099dfa52b6ae497d796086a75dc5d4ab`; the new bridge is the current production source. All other RTL is held fixed and hashed.
- The simulation window starts after the complete `DTREE BEGIN` line and ends at the complete successful exit line. It includes data generation, training, evaluation, cleanup and final output. UART acceleration is identical in every case. Window seconds are cycles divided by the actual simulated CPU frequency, not simulator wall time.
- Pipeline commits are an auxiliary observation of `mCommits`, approximately 39.52 million per case. They exclude slow-path handovers and are not an architectural retired-instruction count. Redirects observe the current generated `e2Moved` layout, verified against the generated assignments; changing that ABI requires reviewing the probes. Timer-printing paths can cause small instruction-count differences even with identical inputs.

## Interpretation and next work

The recent changes do address useful performance costs. Compressed prediction is the clear leader in this matrix; the cache and bridge gains are smaller. At the best setting, measured cache holds account for 7.96% of window cycles. Eliminating those holds alone could save at most that fraction; fixed memory-port latency and other processor stalls are outside that counter.

For board dependability, first investigate the prediction-off image's CRC-header failure and add a physical or RTL regression for the reproducer. Its successful classifier runs do not establish general correctness of that experimental variant.

The next performance investigation should attribute the remaining processor cycles to software arithmetic, branch penalties, dependency stalls and shared-port overhead before selecting another hardware change. The classifier uses software floating-point and a 48-step log2 routine, so its instruction mix is an important measurement target. These counters do not yet establish which of those costs dominates.

This is one small workload. It does not demonstrate a general FP-RISC speedup, larger-classifier endurance, full example-suite acceptance of two-way hardware, higher-clock reliability, or SDRAM electrical/PVT signoff. Keep the accepted 48 MHz preset unchanged until those acceptance checks pass.

## Evidence and reproduction

The [evidence directory](evidence/2026-10-28-controlled-benchmark/README.md) contains exact compressed guest/CPU inputs, source and tool hashes, all eight UART logs and simulator receipts, the independent oracle, [matrix results](evidence/2026-10-28-controlled-benchmark/matrix-results.json), and all twelve [controlled pairwise effects](evidence/2026-10-28-controlled-benchmark/effects.json).

The runner tests reject incomplete windows, simulation-limit exits, duplicate/missing counters and inconsistent matrix inputs. Separate negative controls reject a stale executable receipt and a corrupt classifier result. Fresh preparation generated both CPU variants and refused to overwrite an existing experiment.
