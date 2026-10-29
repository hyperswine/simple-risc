#!/usr/bin/env python3
"""Freeze one 72 MHz small-classifier image and generate both controlled CPUs."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
PREDICATE = '      hit =\n        isNothing flushing\n'
DISABLED = PREDICATE + '          && not (cpuCompressed machine) -- Controlled benchmark: compressed BTB off.\n'
OLD_BRIDGE = '417053d3099dfa52b6ae497d796086a75dc5d4ab'


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--image', required=True, type=Path, help='frozen train128/test64/bins8/depth5/minLeaf2 RV32IMC binary, CPU timer 72 MHz')
    p.add_argument('--elf', required=True, type=Path)
    p.add_argument('--out', required=True, type=Path, help='new experiment directory; never overwrites an existing experiment')
    p.add_argument('--fprisc', type=Path, default=ROOT.parent/'fprisc')
    args = p.parse_args()
    # Check all inputs before creating the experiment.
    image, elf = args.image.resolve(), args.elf.resolve()
    image_hash, elf_hash = sha(image), sha(elf)
    oracle_path = args.fprisc.resolve()/'tests/check_tangnano20k_dtree.py'
    spec = importlib.util.spec_from_file_location('dtree_oracle', oracle_path)
    oracle = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(oracle)
    source = (ROOT/'src/SimpleRisc.hs').read_text()
    if source.count(PREDICATE) != 1:
        p.error('BTB predicate changed; review the controlled source modification')
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=False)
    (out/'input').mkdir()
    shutil.copy2(image, out/'input/base.bin')
    shutil.copy2(elf, out/'input/base.elf')
    bridge = subprocess.run(['git', 'show', f'{OLD_BRIDGE}:boards/tangnano20k/sdram/clock_bridge.v'],
                            cwd=ROOT, capture_output=True, check=True).stdout
    (out/'bridge-old.v').write_bytes(bridge)
    shutil.copy2(HERE/'clock_bridge.v', out/'bridge-new.v')
    revision = subprocess.run(['git', 'rev-parse', 'HEAD'], cwd=ROOT, capture_output=True,
                              text=True, check=True).stdout.strip()
    experiment = dict(base_revision=revision, image_sha256=image_hash, elf_sha256=elf_hash,
                      guest_cpu_mhz=72, reference=oracle.reference(128, 64, 8, 5, 2),
                      predictor_off_change='Add not cpuCompressed to the BTB hit predicate; all other source is unchanged.',
                      bridge_old_revision=OLD_BRIDGE, sources={})
    for predictor in ('on', 'off'):
        directory = out/f'source-{predictor}'
        shutil.copytree(ROOT/'src', directory)
        if predictor == 'off':
            (directory/'SimpleRisc.hs').write_text(source.replace(PREDICATE, DISABLED))
        for path in sorted(directory.rglob('*.hs')):
            experiment['sources'][str(path.relative_to(out))] = sha(path)
        command = ['cabal', 'run', 'clash', '--', f'-i{directory}', '-hide-package', 'simple-risc',
                   '-DRISCV_COMPRESSED', str(directory/'SdramPipelineObserved.hs'), '--verilog',
                   '-fclash-clear', '-outputdir', str(out/f'generated-{predictor}')]
        with (out/f'generate-{predictor}.log').open('w') as log:
            subprocess.run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT,
                           check=True, timeout=600)
    for name in ('bridge-old.v', 'bridge-new.v'):
        experiment['sources'][name] = sha(out/name)
    experiment['frozen_inputs'] = {
        name: sha(out/name) for name in ['input/base.bin', 'input/base.elf', 'bridge-old.v', 'bridge-new.v',
            'generated-on/SdramPipelineObserved.topEntity/sdram_pipeline_risc.v',
            'generated-off/SdramPipelineObserved.topEntity/sdram_pipeline_risc.v']}
    experiment['profiling_abi'] = 'named-v1'
    (out/'experiment.json').write_text(json.dumps(experiment, indent=2)+'\n')
    print(f'Prepared {out}; run benchmark_matrix.py --out {out}')


if __name__ == '__main__':
    main()
