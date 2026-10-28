# Controlled classifier benchmark evidence

The experiment starts at SimpleRisc revision
`9d29a6b746c4472795ac56516c96b2096e6b70b8`. The guest is the original
153,280-byte RV32IMC Base+GC small classifier, compiled with a 72 MHz timer.
Its binary is frozen, so concurrent compiler work cannot change this comparison.
`guest-results.json` records the original compiler and classifier hashes;
its old board time is provenance, **not a result of this experiment**.

`base.bin.gz`, `base.elf.gz`, and `cpu-{on,off}.v.gz` are compressed exact
replay inputs. `experiment.json` identifies the input hashes and the independent
reference. `bridge-old.v` is from commit
`417053d3099dfa52b6ae497d796086a75dc5d4ab`; `bridge-new.v` is the current source.
The only Haskell change in the prediction-off snapshot adds
`&& not (cpuCompressed machine)` to the BTB lookup's `hit` predicate.
`cpu-on-generation-provenance.json` connects the prediction-on RTL to the
earlier fresh generation and source hashes. The raw off-generation log is retained.
`cache.v` freezes the cache before the subsequent MRU resource reduction;
select it explicitly when replaying these measurements.

To replay the exact inputs from the SimpleRisc root, with Verilator, the RISC-V
ELF tools and the sibling fprisc checkout available:

```bash
python3 - <<'PY'
from pathlib import Path
import gzip, shutil
src = Path('docs/evidence/2026-10-28-controlled-benchmark')
out = Path('output/tangnano20k/controlled-replay')
out.mkdir(parents=True, exist_ok=False)
(out/'input').mkdir()
for name in ('base.bin', 'base.elf'):
    (out/'input'/name).write_bytes(gzip.decompress((src/(name+'.gz')).read_bytes()))
for predictor in ('on', 'off'):
    directory = out/f'generated-{predictor}/SdramPipeline.topEntity'
    directory.mkdir(parents=True)
    (directory/'sdram_pipeline_risc.v').write_bytes(
        gzip.decompress((src/f'cpu-{predictor}.v.gz').read_bytes()))
for name in ('experiment.json', 'bridge-old.v', 'bridge-new.v', 'cache.v'):
    shutil.copy2(src/name, out/name)
PY
python3 boards/tangnano20k/sdram/benchmark_matrix.py \
  --out output/tangnano20k/controlled-replay \
  --cache-rtl output/tangnano20k/controlled-replay/cache.v
```

The frozen reference is rechecked against the sibling fprisc oracle. For a new
experiment generated from the current Haskell source, use
`prepare_benchmark_matrix.py --image ... --elf ... --out NEW_DIRECTORY` with
the same small-classifier parameters and 72 MHz guest timer, then run
`benchmark_matrix.py --out NEW_DIRECTORY`. Preparation refuses an existing
directory. Generation paths can affect Clash's emitted names and comments;
the exact replay above retains the measured netlists.

`--resume` reuses only results whose source/configuration, simulator executable,
build receipt, UART output and independent classifier check still match.
Each case uses a bounded build and run. The final gate requires the same
guest, shared RTL, clocks, total cache capacity and write policy in all eight
cases. The simulation UART divider is shortened consistently; simulated
window time includes data generation, training, evaluation and the final output.

Physical results, when present, use 48/48 MHz, three alternating runs per
configuration, fresh uploads, and the same guest bytes. Their reported guest
elapsed value is multiplied by 72/48. This guest interval ends before the final
elapsed/exit print, so it differs from the simulation window. The clock bridge
is bypassed in a single-clock image. `run_board.py` records the board procedure
and restores the known-good 48 MHz image in `finally`; it is an experiment log
with local paths, not a general deployment tool.
