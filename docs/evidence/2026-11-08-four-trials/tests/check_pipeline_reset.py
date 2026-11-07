#!/usr/bin/env python3
"""Compare baseline/candidate observed cores through warm resets and holds.

A shared fixed-latency memory model supplies a small arithmetic/load/store loop.
Compare valid retirements, fetches and side effects. This complements, rather
than replaces, the full cache/CDC guest regression. The negative control makes
the candidate ignore warm resets and must be rejected after the first reset.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
from run_perf import sv_safe

HERE = Path(__file__).resolve().parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline', type=Path, required=True)
    parser.add_argument('--candidate', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    receipt = {'passed': False, 'sources': {}}
    sources = []
    for name in ('baseline', 'candidate'):
        original = getattr(args, name).resolve()
        data = original.read_bytes()
        receipt['sources'][name] = {'path': str(original), 'sha256': hashlib.sha256(data).hexdigest()}
        source = sv_safe(data.decode())
        assert source.count('module sdram_pipeline_risc\n') == 1
        source = source.replace('module sdram_pipeline_risc\n', f'module {name}_core\n')
        target = out / f'{name}.sv'
        target.write_text(source)
        sources.append(target)
    tb = HERE / 'pipeline_reset_tb.v'
    receipt['testbench_sha256'] = hashlib.sha256(tb.read_bytes()).hexdigest()
    result_path = out / 'results.json'
    result_path.write_text(json.dumps(receipt, indent=2))
    with (out / 'build.log').open('w') as log:
        subprocess.run(['verilator', '--binary', '--timing', '-O3', '-Wno-fatal',
                        '-Wno-lint', '-Wno-style', '--top-module', 'reset_equivalence_tb',
                        '--Mdir', str(out / 'obj'), '-j', '4', *map(str, sources), str(tb)],
                       stdout=log, stderr=subprocess.STDOUT, check=True, timeout=300)
    executable = out / 'obj/Vreset_equivalence_tb'
    for name, extra in (('pass', []), ('negative', ['+IGNORE_CANDIDATE_RESET'])):
        result = subprocess.run([str(executable), *extra], text=True, capture_output=True, timeout=120)
        output = result.stdout + result.stderr
        (out / f'{name}.log').write_text(output)
        if name == 'pass':
            assert result.returncode == 0 and 'PASS: reset equivalence' in output, output
        else:
            assert result.returncode != 0 and 'mismatch' in output and 'epoch=1' in output, output
        receipt[name] = {'returncode': result.returncode, 'output_sha256': hashlib.sha256(output.encode()).hexdigest()}
        print(output, end='')
    receipt['passed'] = True
    result_path.write_text(json.dumps(receipt, indent=2))
    print('PASS: ignored warm reset is rejected by equivalence monitor')


if __name__ == '__main__':
    main()
