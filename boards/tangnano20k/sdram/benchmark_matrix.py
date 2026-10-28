#!/usr/bin/env python3
"""Run the frozen 2x2x2 classifier experiment; resume only source-validated runs."""
import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def check_controls(cases):
    """Refuse a matrix whose supposedly fixed inputs changed between builds."""
    expected = {(p, w, b) for p in ('off', 'on') for w in (1, 2) for b in ('old', 'new')}
    assert len(cases) == 8 and {(c['predictor'], c['ways'], c['bridge']) for c in cases} == expected
    common = []
    generated, bridges = {}, {}
    for case in cases:
        config = case['configuration']
        assert config['cpu_mhz'] == 72 and config['mem_mhz'] == 54 and config['cdc']
        assert config['profile_cpu'] and config['write_update'] == 1
        assert config['ways'] == case['ways'] and config['line_bits'] == (12 if case['ways'] == 1 else 11)
        inputs = dict(config['inputs'])
        bridge_path, = [path for path in inputs if Path(path).name == f'bridge-{case["bridge"]}.v']
        bridge_hash = inputs.pop(bridge_path)
        bridges.setdefault(case['bridge'], bridge_hash)
        assert bridges[case['bridge']] == bridge_hash
        generated.setdefault(case['predictor'], config['generated'])
        assert generated[case['predictor']] == config['generated']
        common.append((config['image_sha256'], config['elf_sha256'], inputs))
    assert all(value == common[0] for value in common), 'shared inputs changed during the experiment'


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--out', type=Path, default=ROOT/'output/tangnano20k/benchmark-matrix-20261028')
    p.add_argument('--fprisc', type=Path, default=ROOT.parent/'fprisc')
    p.add_argument('--cache-rtl', type=Path, default=HERE/'pipeline_cache.v',
                   help='cache implementation to hold fixed throughout the matrix')
    p.add_argument('--build-workers', type=int, default=2)
    p.add_argument('--run-workers', type=int, default=4)
    p.add_argument('--resume', action='store_true')
    args = p.parse_args()
    out = args.out.resolve()
    if min(args.build_workers, args.run_workers) < 1:
        p.error('worker counts must be positive')
    experiment = json.loads((out/'experiment.json').read_text())
    for path, digest in experiment.get('frozen_inputs', {}).items():
        assert sha(out/path) == digest, f'frozen experiment input changed: {path}'
    assert sha(out/'input/base.bin') == experiment['image_sha256']
    assert sha(out/'input/base.elf') == experiment['elf_sha256']
    oracle_path = args.fprisc.resolve()/'tests/check_tangnano20k_dtree.py'
    spec = importlib.util.spec_from_file_location('dtree_oracle', oracle_path)
    oracle = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(oracle)
    reference = oracle.reference(128, 64, 8, 5, 2)
    assert reference == experiment['reference'], 'reference changed from the frozen benchmark'
    report = dict(complete=False, passed=False, experiment=experiment, oracle_sha256=sha(oracle_path),
                  cpu_mhz=72, memory_mhz=54, cache_bytes=65536, cases=[])
    result_path = out/'matrix-results.json'
    result_path.write_text(json.dumps(report, indent=2)+'\n')
    cases = []
    for predictor in ('off', 'on'):
        for ways in (1, 2):
            for bridge in ('old', 'new'):
                name = f'btb-{predictor}-ways-{ways}-bridge-{bridge}'
                directory = out/name
                directory.mkdir(exist_ok=True)
                generated = out/f'generated-{predictor}/SdramPipeline.topEntity'
                if not (generated/'sdram_pipeline_risc.v').is_file():
                    raise SystemExit(f'missing generated CPU: {generated}')
                command = [sys.executable, str(HERE/'run_perf.py'), str(out/'input/base.bin'),
                           '--elf', str(out/'input/base.elf'), '--generated', str(generated),
                           '--cpu-mhz', '72', '--mem-mhz', '54', '--line-bits', str(12 if ways == 1 else 11),
                           '--ways', str(ways), '--bridge-rtl', str(out/f'bridge-{bridge}.v'),
                           '--cache-rtl', str(args.cache_rtl.resolve()),
                           '--write-update', '1', '--profile-cpu', '--jobs', '2', '--timeout', '1800',
                           '--out', str(directory)]
                case = dict(name=name, predictor=predictor, ways=ways, bridge=bridge, passed=False)
                cases.append((case, directory, command))
                report['cases'].append(case)

    def validate_result(case, directory):
        detail = json.loads((directory/'results.json').read_text())
        assert detail['passed'] and detail['output_sha256'] == sha(directory/'run.log')
        assert detail['build_manifest_sha256'] == sha(directory/'build-manifest.json')
        output = (directory/'run.log').read_text()
        elapsed = oracle.validate(output, reference)
        assert output.splitlines().count('FPR EXIT 0') == 1
        semantic_lines = [line for line in output.splitlines()
                          if (line.startswith('DTREE ') and not line.startswith('DTREE elapsed_us='))
                          or line.startswith('root ')]
        return dict(detail=detail, guest_elapsed_us=elapsed,
                    semantic_output_sha256=hashlib.sha256('\n'.join(semantic_lines).encode()).hexdigest())

    def build(item):
        case, directory, command = item
        if args.resume and (directory/'results.json').is_file():
            check = subprocess.run(command + ['--validate-only'], cwd=ROOT,
                                   capture_output=True, text=True, timeout=60)
            if check.returncode == 0:
                try:
                    result = validate_result(case, directory)
                    print(f'{case["name"]}: reused validated result', flush=True)
                    return item, result
                except (AssertionError, KeyError, ValueError, OSError):
                    pass
        print(f'{case["name"]}: building', flush=True)
        with (directory/'build-command.log').open('w') as log:
            result = subprocess.run(command + ['--build-only'], cwd=ROOT, stdout=log,
                                    stderr=subprocess.STDOUT, timeout=900)
        assert result.returncode == 0, f'build failed: {directory / "build-command.log"}'
        return item, None

    def run(item):
        case, directory, command = item
        print(f'{case["name"]}: running', flush=True)
        with (directory/'run-command.log').open('w') as log:
            result = subprocess.run(command + ['--run-only'], cwd=ROOT, stdout=log,
                                    stderr=subprocess.STDOUT, timeout=1900)
        assert result.returncode == 0, f'run failed: {directory / "run-command.log"}'
        return item, validate_result(case, directory)

    def record(item, result, reused=False):
        case, directory, _ = item
        detail = result.pop('detail')
        case.update(passed=True, reused=reused, metrics=detail['metrics'], measured_us=detail['measured_us'],
                    held_percent=detail['held_percent'], configuration=detail['configuration'],
                    result_sha256=sha(directory/'results.json'), **result)
        result_path.write_text(json.dumps(report, indent=2)+'\n')
        print(f'{case["name"]}: PASS {case["measured_us"]:.3f} us, held {case["held_percent"]:.2f}%', flush=True)

    try:
        with ThreadPoolExecutor(max_workers=args.build_workers) as builders, \
                ThreadPoolExecutor(max_workers=args.run_workers) as runners:
            running = []
            for future in as_completed([builders.submit(build, item) for item in cases]):
                item, cached = future.result()
                if cached is not None:
                    record(item, cached, True)
                else:
                    running.append(runners.submit(run, item))
            for future in as_completed(running):
                item, result = future.result()
                record(item, result)
        assert len({case['semantic_output_sha256'] for case in report['cases']}) == 1
        check_controls(report['cases'])
        report.update(complete=True, passed=True)
    except BaseException as error:
        report['error'] = str(error)
        raise
    finally:
        result_path.write_text(json.dumps(report, indent=2)+'\n')
    print(f'PASS: full eight-case controlled matrix; {result_path}', flush=True)


if __name__ == '__main__':
    main()
