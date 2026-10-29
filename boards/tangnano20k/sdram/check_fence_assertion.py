#!/usr/bin/env python3
"""Unit-test the CPU FENCE.I monitor and stale-buffer negative controls."""
from pathlib import Path
import argparse
import json
import subprocess

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
OUT = ROOT/'output/tangnano20k/fence-assertion'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, default=OUT, help='isolate artifacts for concurrent experiment callers')
    out = parser.parse_args().out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    results = []
    cases = [
        ('memory-refetch', 0, 0, 'PASS: FENCE.I commit requires a memory fetch'),
        ('stale-prefetch', 1, 1,
         'ASSERT: FENCE.I consumed pre-fence buffered instruction before memory refetch'),
        ('surviving-buffer', 2, 1, 'ASSERT: FENCE.I pre-fence pipeline state survived flush'),
    ]
    for name, stale, expected, required in cases:
        executable = out/(name+'-sim')
        command = ['iverilog', '-g2012', '-s', 'pipeline_fence_assertions_tb',
                   '-P', f'pipeline_fence_assertions_tb.STALE_SOURCE={stale}',
                   '-o', str(executable), str(HERE/'pipeline_fence_assertions.v'),
                   str(HERE/'pipeline_fence_assertions_tb.v')]
        compiled = subprocess.run(command, cwd=ROOT, capture_output=True, text=True, timeout=60)
        if compiled.returncode:
            raise AssertionError(compiled.stdout+compiled.stderr)
        executed = subprocess.run(['vvp', str(executable)], cwd=ROOT,
                                  capture_output=True, text=True, timeout=60)
        text = executed.stdout+executed.stderr
        (out/(name+'.log')).write_text(text)
        if executed.returncode != expected:
            raise AssertionError(f'{name}: exit {executed.returncode}\n{text}')
        if required not in text:
            raise AssertionError(f'{name}: missing expected result\n{text}')
        results.append({'name': name, 'passed': True, 'expected_exit': expected})
        print(f'{name}: PASS')
    (out/'results.json').write_text(json.dumps({'complete': True, 'cases': results}, indent=2)+'\n')


if __name__ == '__main__':
    main()
