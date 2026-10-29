#!/usr/bin/env python3
"""Sweep Gowin placement options (and optionally cache sizes) at an
over-constrained target.

Each case runs build.sh pipeline with SDRAM_TARGET_MHZ set about 10% above
the real CPU clock, so the placer keeps improving past the point where the
real clock is met. Timing reports are parsed for the reported core Fmax and
worst setup slack; build.sh's pass/fail gate is skipped so a case that misses
the target is still recorded. No electrical or I/O signoff is implied.

This is the placement half of the "smaller cache, region constraints and a
-place_option sweep at ~10% high" experiment. For a region constraint, prepare
a FloorPlanner-generated .cst and pass it through SDRAM_REGION_CST (build.sh
appends it to pins.cst).
"""
import argparse
import json
import math
import os
from pathlib import Path
import re
import subprocess
import sys

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
BUILD = HERE/'build.sh'


def parse_timing(report: Path):
    text = report.read_text()
    clock = re.search(r'^\s*\d+\s+clk_core\s+([\d.]+)\(MHz\)\s+([\d.]+)\(MHz\)', text, re.M)
    setup = re.search(r'<Numbers of Setup Violated Endpoints>:(\d+)', text)
    hold = re.search(r'<Numbers of Hold Violated Endpoints>:(\d+)', text)
    paths = re.search(r'3\.1\.1 Setup Paths Table\s*<Report Command>:(.*?)3\.1\.2 Hold Paths Table', text, re.S)
    slack = re.search(r'^\s*1\s+(-?[\d.]+)\s', paths[1], re.M) if paths else None
    if not all((clock, setup, hold, slack)):
        raise ValueError(f'{report}: missing core frequency, endpoint counts or setup paths')
    return {
        'constraint_mhz': float(clock[1]),
        'fmax_mhz': float(clock[2]),
        'worst_setup_slack_ns': float(slack[1]),
        'setup_violations': int(setup[1]),
        'hold_violations': int(hold[1]),
    }


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--base-freq-mhz', type=float, default=72.0,
                   help='real CPU clock the bitstream will run at (default 72)')
    p.add_argument('--memory-freq-mhz', type=float, default=54.0)
    p.add_argument('--target-pct', type=float, default=10.0,
                   help='over-constrain the placer target by this many percent')
    p.add_argument('--place-options', nargs='+', type=int, default=[0, 1, 2, 3, 4])
    p.add_argument('--cache-line-bits', nargs='+', type=int, default=[11])
    p.add_argument('--cache-ways', type=int, choices=[1, 2], default=2)
    p.add_argument('--rvc', type=int, choices=[0, 1], default=0)
    p.add_argument('--out', type=Path, required=True, help='per-case output parent directory')
    p.add_argument('--jobs', type=int, default=1, help='parallel build.sh processes (bounded)')
    p.add_argument('--resume', action='store_true', help='reuse existing reports instead of rebuilding')
    a = p.parse_args()

    if not math.isfinite(a.base_freq_mhz) or a.base_freq_mhz <= 0:
        p.error('--base-freq-mhz must be positive')
    if not math.isfinite(a.memory_freq_mhz) or a.memory_freq_mhz <= 0:
        p.error('--memory-freq-mhz must be positive')
    if not math.isfinite(a.target_pct) or a.target_pct < 0:
        p.error('--target-pct must be nonnegative')
    if a.base_freq_mhz != a.memory_freq_mhz and a.base_freq_mhz not in (72.0, 96.0, 108.0):
        p.error('separate clocks require --base-freq-mhz 72, 96 or 108')
    if not 0 < a.jobs <= 4:
        p.error('--jobs must be 1..4')
    for bits in a.cache_line_bits:
        if not 7 <= bits <= 12:
            p.error('--cache-line-bits must be 7..12')
        if a.cache_ways == 2 and bits == 12:
            p.error('two-way cache requires --cache-line-bits <= 11')
    if len(set(a.place_options)) != len(a.place_options) or any(x not in range(5) for x in a.place_options):
        p.error('--place-options must be distinct values 0..4')

    target = int(round(a.base_freq_mhz * (1.0 + a.target_pct / 100.0)))
    a.out = a.out.resolve()
    a.out.mkdir(parents=True, exist_ok=True)
    cases = [
        {'placement': place, 'line_bits': bits}
        for bits in a.cache_line_bits for place in a.place_options
    ]
    results = {'started_placeholder': True, 'base_freq_mhz': a.base_freq_mhz,
               'memory_freq_mhz': a.memory_freq_mhz, 'target_freq_mhz': target,
               'cases': []}

    def run_case(case):
        place, bits = case['placement'], case['line_bits']
        out = a.out/f'place{place}-l{bits}'
        report = out/'impl/pnr/sdram_test.tr'
        if a.resume and report.is_file():
            parsed = parse_timing(report)
            parsed.update(case, out=str(out))
            return parsed
        env = dict(os.environ)
        env.update({
            'SDRAM_FREQ_MHZ': f'{a.memory_freq_mhz:g}',
            'SDRAM_CPU_FREQ_MHZ': f'{a.base_freq_mhz:g}',
            'SDRAM_TARGET_MHZ': f'{target:g}',
            'SDRAM_CACHE_WAYS': str(a.cache_ways),
            'SDRAM_CACHE_LINE_BITS': str(bits),
            'SDRAM_RVC': str(a.rvc),
            'SDRAM_PLACE_OPTION': str(place),
            'SDRAM_SKIP_TIMING_CHECK': '1',
            'SDRAM_OUT': str(out),
        })
        print(f'[place {place}, line_bits {bits}] building into {out}', flush=True)
        proc = subprocess.run([str(BUILD), 'pipeline'], cwd=ROOT, env=env,
                              capture_output=True, text=True)
        if proc.returncode != 0:
            print(proc.stdout, file=sys.stderr)
            print(proc.stderr, file=sys.stderr)
            raise RuntimeError(f'build.sh pipeline failed for place={place} line_bits={bits}')
        if not report.is_file():
            raise RuntimeError(f'{report}: missing after build')
        parsed = parse_timing(report)
        parsed.update(case, out=str(out))
        return parsed

    if a.jobs > 1:
        import concurrent.futures
        with concurrent.futures.ThreadPoolExecutor(max_workers=a.jobs) as pool:
            parsed_cases = list(pool.map(run_case, cases))
    else:
        parsed_cases = [run_case(case) for case in cases]

    results['cases'] = parsed_cases
    results.pop('started_placeholder')
    (a.out/'sweep-results.json').write_text(json.dumps(results, indent=2, sort_keys=True) + '\n')
    print('\nplacement  line_bits  fmax_mhz  worst_slack_ns  setup  hold')
    for case in parsed_cases:
        print(f"{case['placement']:>9}  {case['line_bits']:>9}  {case['fmax_mhz']:>8.3f}  "
              f"{case['worst_setup_slack_ns']:>14.3f}  {case['setup_violations']:>5}  {case['hold_violations']:>4}")
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
