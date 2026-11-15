#!/usr/bin/env python3
"""Core-structure probes, each with a frozen-netlist placement sweep.

Reuses the Fast-Clash sweep harness (synthesis once, placements 0..4 of that
exact netlist, setup-derived Fmax plus pulse-width and area from the reports).
The probes live in src/CoreProbes.hs and model individual RV32IM arcs with the
core's own functions: alu (E1/E2 execute), shift (full single-cycle barrel),
btb (fetch/BTB feedback), hazard (decode hazard against three producers),
load (two-way cache read plus loadValue and store merge), mul (DSP partial
products and wide sum), branch (compare and target resolution).
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
sys.path.insert(0, str(HERE.parent / 'fast-probe'))
import importlib.util
_spec = importlib.util.spec_from_file_location('fp_run_sweep', HERE.parent / 'fast-probe' / 'run_sweep.py')
_fp = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_fp)
prepare, measure, run_tool = _fp.prepare, _fp.measure, _fp.run_tool

GENERATED = ROOT / 'output/tangnano20k/core-probe-generated'
VARIANTS = {
    'alu': ('probe_alu', 'aluProbeTop'), 'shift': ('probe_shift', 'shifterProbeTop'),
    'btb': ('probe_btb', 'btbProbeTop'), 'hazard': ('probe_hazard', 'hazardProbeTop'),
    'load': ('probe_load', 'loadProbeTop'), 'mul': ('probe_mul', 'mulProbeTop'),
    'branch': ('probe_branch', 'branchProbeTop'),
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
        rtl = GENERATED / f'CoreProbes.{binding}' / f'{module}.v'
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
