#!/usr/bin/env python3
"""Extract Gowin resource, high-fanout and worst-path evidence without rebuilding."""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import re


def analyze(netlist_path, timing_path, utilization_path):
    netlist, timing, utilization = (p.read_text() for p in (netlist_path, timing_path, utilization_path))
    modules, drivers = {}, {}
    for module in re.finditer(r'^module (\w+)\s*\(.*?^endmodule', netlist, re.M | re.S):
        name, body = module[1], module[0]
        inits = dict(re.findall(r'defparam\s+(\S+)\s*\.INIT\s*=\s*([^;]+)', body))
        cells = list(re.finditer(r'^  (\w+)\s+(\S+)\s*\(\s*(.*?)^\);', body, re.M | re.S))
        counts = Counter(cell[1] for cell in cells)
        modules[name] = dict(cells=dict(counts),
            flip_flops=sum(v for k, v in counts.items() if k.startswith('DFF')),
            lut_primitives=sum(v for k, v in counts.items() if k.startswith('LUT')),
            mux_primitives=sum(v for k, v in counts.items() if k.startswith('MUX')))
        for cell in cells:
            ports = dict(re.findall(r'\.(\w+)\((.*?)\)', cell[3]))
            for output in ('Q', 'F', 'O'):
                if output not in ports:
                    continue
                drivers[name, ports[output].strip()] = dict(cell_type=cell[1], instance=cell[2], ports=ports,
                                                          init=inits.get(cell[2]))
    resources = {}
    for label in ('Logic', 'Register', 'CLS', 'BSRAM', 'DSP'):
        found = re.search(r'^\s*'+label+r'\s*\|\s*(\d+)/(\d+)\s*\|\s*(\d+)%', utilization, re.M)
        if not found:
            raise ValueError(f'missing resource: {label}')
        resources[label] = dict(used=int(found[1]), available=int(found[2]), percent=int(found[3]))
    fanout_section = timing.split('3.5 High Fanout Nets Report\n')[-1].split('3.6 Route Congestions Report')[0]
    fanout = []
    for match in re.finditer(r'^\s*(\d+)\s+(\S+)\s+(-?[\d.]+)\s+([\d.]+)\s*$', fanout_section, re.M):
        count, net, slack, delay = match.groups()
        scope, _, local = net.partition('/')
        module = {'core': 'sdram_pipeline_risc', 'cache': 'sdram_pipeline_cache'}.get(scope)
        fanout.append(dict(net=net, fanout=int(count), worst_slack_ns=float(slack), max_delay_ns=float(delay),
                           driver=drivers.get((module, local))))
    paths_section = timing.split('3.1.1 Setup Paths Table\n')[-1].split('3.1.2 Hold Paths Table')[0]
    paths = []
    for line in paths_section.splitlines():
        parts = line.split()
        if len(parts) == 9 and parts[0].isdigit():
            paths.append(dict(number=int(parts[0]), slack_ns=float(parts[1]), source=parts[2],
                              destination=parts[3], relation_ns=float(parts[6]), delay_ns=float(parts[8])))
    frequency = re.search(r'^\s*\d+\s+clk_core\s+([\d.]+)\(MHz\)\s+([\d.]+)\(MHz\)', timing, re.M)
    if not modules or not fanout or not paths or frequency is None:
        raise ValueError('missing modules, high-fanout nets, setup paths or core Fmax')
    return dict(resources=resources, synthesized_modules=modules, high_fanout=fanout,
                setup_paths=paths, target_mhz=float(frequency[1]), fmax_mhz=float(frequency[2]),
                inputs={str(p.resolve()): hashlib.sha256(p.read_bytes()).hexdigest()
                        for p in (netlist_path, timing_path, utilization_path)})


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('build', type=Path, help='Gowin output directory containing impl/')
    p.add_argument('--out', type=Path, required=True)
    args = p.parse_args()
    report = analyze(args.build/'impl/gwsynthesis/sdram_test.vg',
                     args.build/'impl/pnr/sdram_test.tr', args.build/'impl/pnr/sdram_test.rpt.txt')
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(report, indent=2)+'\n')
    print(f'Logic {report["resources"]["Logic"]["used"]}, registers {report["resources"]["Register"]["used"]}, Fmax {report["fmax_mhz"]:.3f} MHz')


if __name__ == '__main__':
    main()
