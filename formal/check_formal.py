#!/usr/bin/env python3
"""Check each named Maude search, including safety, mutations and reachability."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess

HERE = Path(__file__).resolve().parent
# Outcomes belong to individual initial states, never aggregate file counts.
# 'witness' checks non-vacuous progress/eviction; 'unreachable' is its mutant.
CASES = {
    'cache_coherence.maude': [
        ('initialUpdate', 'safe'), ('initialInvalidate', 'safe'),
        ('initialBroken', 'counterexample'),
        ('initialEviction0', 'witness'), ('initialEviction1', 'witness'),
    ],
    'cache_cycle.maude': [
        ('initialUpdate', 'safe'), ('initialInvalidate', 'safe'),
        ('initialBadWay1', 'counterexample'), ('initialNoDrain', 'counterexample'),
        ('initialRead', 'witness'), ('initialStuck', 'unreachable'),
        ('initialEviction0', 'witness'), ('initialEviction1', 'witness'),
    ],
    'instruction_fence.maude': [('initialGood', 'safe'), ('initialNoFlush', 'counterexample')],
    'branch_prediction.maude': [
        ('initialCorrect', 'safe'), ('initialWrong', 'safe'),
        ('initialNoFlush', 'counterexample'), ('initialBubbleFault', 'counterexample'),
    ],
    'btb_storage.maude': [
        ('initialGood', 'safe'), ('initialNoBypass', 'counterexample'),
        ('initialNoCommit', 'counterexample'), ('initialGood', 'witness'),
        ('initialNoHold', 'unreachable'),
    ],
    'fqueue_storage.maude': [
        ('initialGood', 'safe'), ('initialWrongSlot', 'counterexample'),
        ('initialNoCommit', 'counterexample'), ('initialGood', 'witness'),
        ('initialNoHold', 'unreachable'),
    ],
}


def validate_searches(output, expected):
    """Require the correct result for every echoed search, in its source order."""
    if re.search(r'\b(?:Warning|Error|Error is):', output, re.IGNORECASE):
        raise AssertionError('Maude reported a warning or error')
    searches = re.split(r'(?m)^search\b', output)[1:]
    if len(searches) != len(expected):
        raise AssertionError(f'expected {len(expected)} searches, got {len(searches)}')
    results = []
    for block, (name, outcome) in zip(searches, expected):
        if not re.search(r':\s*' + re.escape(name) + r'\s*=>', block):
            raise AssertionError(f'{name}: missing or reordered search')
        no_solution = bool(re.search(r'(?m)^No solution\.$', block))
        has_solution = bool(re.search(r'(?m)^Solution 1 \(state \d+\)', block))
        if no_solution == has_solution:
            raise AssertionError(f'{name}: missing or ambiguous search result')
        need_solution = outcome in ('witness', 'counterexample')
        if has_solution != need_solution:
            raise AssertionError(f'{name}: expected {outcome}, got '
                                 + ('solution' if has_solution else 'no solution'))
        states = re.search(r'(?m)^states: (\d+)', block)
        results.append(dict(name=name, expected=outcome, passed=True,
                            states=int(states[1]) if states else None))
    return results


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--models', nargs='+', choices=CASES, default=list(CASES))
    parser.add_argument('--out', type=Path, default=HERE.parent / 'output/formal')
    parser.add_argument('--timeout', type=int, default=300, help='seconds per model file')
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    report = dict(complete=False, models=[])
    result_path = args.out / 'results.json'
    result_path.write_text(json.dumps(report, indent=2) + '\n')
    try:
        if not shutil.which('maude'):
            raise SystemExit('Maude is required: https://maude.cs.illinois.edu/')
        if args.timeout <= 0:
            parser.error('--timeout must be positive')
        for filename in args.models:
            model = HERE / filename
            try:
                result = subprocess.run(['maude', '-no-banner', str(model)],
                                        cwd=HERE.parent, capture_output=True, text=True, timeout=args.timeout)
            except subprocess.TimeoutExpired as error:
                output = error.stdout or b''
                (args.out / (filename + '.log')).write_bytes(
                    output.encode() if isinstance(output, str) else output)
                raise
            output = result.stdout + result.stderr
            (args.out / (filename + '.log')).write_text(output)
            if result.returncode:
                raise AssertionError(f'{filename}: Maude exited {result.returncode}')
            checks = validate_searches(output, CASES[filename])
            report['models'].append(dict(file=filename, sha256=hashlib.sha256(model.read_bytes()).hexdigest(),
                                         checks=checks))
            print(f'PASS: {filename}: {len(checks)} individually checked searches', flush=True)
        report['complete'] = True
    except BaseException as error:
        report['error'] = str(error)
        raise
    finally:
        result_path.write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    main()
