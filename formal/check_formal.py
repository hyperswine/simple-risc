#!/usr/bin/env python3
"""Run the Maude safety searches and require their negative controls to fail."""
from pathlib import Path
import shutil
import subprocess

HERE = Path(__file__).resolve().parent
CASES = {
    'cache_coherence.maude': {'no_solution': 2, 'counterexamples': 1},
    'cache_cycle.maude': {'no_solution': 2, 'counterexamples': 2},
    'instruction_fence.maude': {'no_solution': 1, 'counterexamples': 1},
    'branch_prediction.maude': {'no_solution': 2, 'counterexamples': 2},
}


def main():
    if not shutil.which('maude'):
        raise SystemExit('Maude is required: https://maude.cs.illinois.edu/')
    root = HERE.parent
    out = root / 'output/formal'
    out.mkdir(parents=True, exist_ok=True)
    for filename, expected in CASES.items():
        result = subprocess.run(
            ['maude', '-no-banner', str(HERE / filename)],
            cwd=root, capture_output=True, text=True, timeout=60)
        output = result.stdout + result.stderr
        (out / (filename + '.log')).write_text(output)
        if result.returncode or 'Warning:' in output:
            raise AssertionError(f'{filename}: Maude failed\n{output}')
        actual = {
            'no_solution': output.count('No solution.'),
            'counterexamples': output.count('Solution 1 (state'),
        }
        if actual != expected:
            raise AssertionError(f'{filename}: expected {expected}, got {actual}\n{output}')
        print(f"PASS: {filename}: {actual['no_solution']} safety searches, "
              f"{actual['counterexamples']} expected counterexample(s)")


if __name__ == '__main__':
    main()
