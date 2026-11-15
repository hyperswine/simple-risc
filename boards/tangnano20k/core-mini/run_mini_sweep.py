#!/usr/bin/env python3
"""CoreMini (custom-ISA five-stage core), frozen-netlist placement sweep.

Same harness as the core-probe sweep: one synthesis, placements 0..4 of that
exact netlist, setup-derived Fmax plus pulse-width and area from the reports.
The core lives in src/CoreMini.hs and its default program is baked into the
instruction ROM at Clash generation time.
"""
import argparse
import hashlib
import json
import os
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
sys.path.insert(0, str(HERE.parent / 'fast-probe'))
import importlib.util
_spec = importlib.util.spec_from_file_location('fp_run_sweep', HERE.parent / 'fast-probe' / 'run_sweep.py')
_fp = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_fp)
prepare, measure, run_tool = _fp.prepare, _fp.measure, _fp.run_tool

GENERATED = ROOT / 'output/tangnano20k/core-mini-generated'
VARIANTS = {
    'mini': ('mini_core', 'miniTop'),
}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--freq', type=float, default=216)
    parser.add_argument('--target', type=int, default=240)
    parser.add_argument('--variants', default=','.join(VARIANTS))
    parser.add_argument('--placements', default='0,1,2,3,4')
    args = parser.parse_args()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    ide = Path(os.environ.get('GOWIN_IDE', '/Applications/GowinIDE.app/Contents/Resources/Gowin_EDA/IDE'))
    results = {}
    places = [int(p) for p in args.placements.split(',')]
    assert places[0] == 0 and all(0 <= p <= 4 for p in places)
    for variant in args.variants.split(','):
        module, binding = VARIANTS[variant]
        rtl = GENERATED / f'CoreMini.{binding}' / f'{module}.v'
        if not rtl.is_file():
            raise FileNotFoundError(rtl)
        base = out / variant / 'p0'
        settings = prepare(base, module, rtl, args.freq, args.target, 0)
        run_tool(base, ide)
        netlist = base / 'impl/gwsynthesis/probe.vg'
        digest = hashlib.sha256(netlist.read_bytes()).hexdigest()
        results[variant] = {}
        for place in places:
            directory = out / variant / f'p{place}'
            if place:
                directory.mkdir(parents=True, exist_ok=True)
                for name in ('pins.cst', 'clocks.sdc'):
                    (directory / name).write_bytes((base / name).read_bytes())
                (directory / 'build.tcl').write_text(settings + f'set_option -place_option {place}\nadd_file -type netlist "{netlist}"\nadd_file "{directory}/pins.cst"\nadd_file "{directory}/clocks.sdc"\nrun pnr\nexit\n')
                run_tool(directory, ide)
            assert hashlib.sha256(netlist.read_bytes()).hexdigest() == digest
            result = measure(directory, args.freq)
            result['netlist_sha256'] = digest
            results[variant][str(place)] = result
            print(f'{variant} p{place}: {result}', flush=True)
            (out / 'results.json').write_text(json.dumps(dict(freq_mhz=args.freq, target_mhz=args.target, variants=results), indent=2) + '\n')


if __name__ == '__main__':
    main()
