#!/usr/bin/env python3
"""Extract Gowin resource, high-fanout and worst-path evidence without rebuilding."""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import re


def setup_details(timing):
    """Keep physical endpoint pins and per-hop evidence, not just path names.

    A path ending at D and one ending at CE can have the same register name
    in the summary table. Inferring enable depth from that table loses the
    distinction this analysis is intended to measure.
    """
    section = timing.rsplit('3.3.1 Setup Analysis Report\n', 1)[1].split('3.3.2 Hold Analysis Report', 1)[0]
    paths = []
    for block in re.split(r'\bPath(\d+)\s*\n', section)[1:][1::2]:
        arrival = block.split('Data Arrival Path:', 1)[1].split('Data Required Path:', 1)[0]
        hops = []
        for line in arrival.splitlines():
            parts = line.split()
            if len(parts) == 7 and parts[2] in ('tNET', 'tINS', 'tC2Q'):
                hops.append(dict(arrival_ns=float(parts[0]), delay_ns=float(parts[1]),
                                 kind=parts[2], edge=parts[3], fanout=int(parts[4]),
                                 location=parts[5], node=parts[6]))
        if not hops or hops[0]['kind'] != 'tC2Q':
            # Clock-route hops precede the launching Q. Keep only the data
            # path; a malformed or incomplete report must not look successful.
            first_q = next((i for i, h in enumerate(hops) if h['kind'] == 'tC2Q'), None)
            if first_q is None:
                raise ValueError('setup path has no launching Q')
            hops = hops[first_q:]
        stats = re.search(r'Arrival Data Path Delay: \(cell: ([\d.]+) [\d.]+%,\s*'
                          r'route: ([\d.]+) [\d.]+%,\s*tC2Q: ([\d.]+)', block)
        if stats is None:
            raise ValueError('setup path lacks cell/route/C2Q statistics')
        endpoint = hops[-1]['node']
        paths.append(dict(
            source=re.search(r'^From\s*:\s*(\S+)', block, re.M)[1],
            destination=re.search(r'^To\s*:\s*(\S+)', block, re.M)[1],
            slack_ns=float(re.search(r'^Slack\s*:\s*([\d.-]+)', block, re.M)[1]),
            endpoint=endpoint, endpoint_pin=endpoint.rsplit('/', 1)[-1],
            logic_levels=int(re.search(r'Logic Level: (\d+)', block)[1]),
            cell_ns=float(stats[1]), route_ns=float(stats[2]), clock_to_q_ns=float(stats[3]),
            max_data_fanout=max(h['fanout'] for h in hops), hops=hops))
    if not paths:
        raise ValueError('missing detailed setup paths')
    return paths


def attribute_fields(report, generated_path, layout_path, bindings):
    """Attribute selected physical registers using checked host metadata.

    Bindings are an explicit analyst assertion about register ownership. Width
    checks against the exact generated RTL are mandatory; this does not infer
    ownership from an unstable generated name or prove whole-netlist equality.
    """
    generated = generated_path.read_text()
    layouts = {item['type']: item for item in json.loads(layout_path.read_text())}
    bound = {}
    for binding in bindings:
        register, name = binding.split('=', 1)
        layout = layouts[name]
        match = re.search(r'\breg\s+\[(\d+):0\]\s+' + re.escape(register) + r'\s*=', generated)
        if not match or int(match[1]) + 1 != layout['bits']:
            raise ValueError(f'generated register/layout width mismatch: {binding}')
        bound[register] = layout

    def field(hop):
        cell = hop.get('cell')
        if cell is None or 'Q' not in cell['ports']:
            return None
        match = re.fullmatch(r'\\?([^\s\[]+)\s*\[(\d+)\]', cell['ports']['Q'])
        if not match or match[1] not in bound:
            return None
        layout, bit = bound[match[1]], int(match[2])
        for item in layout['fields']:
            if item['low'] <= bit <= item['high']:
                return dict(type=layout['type'], field=item['name'], bit=bit - item['low'], register=match[1])
        raise ValueError('mapped register bit outside source field layout')

    for path in report['detailed_setup_paths']:
        path['source_field'] = field(path['hops'][0])
        path['destination_field'] = field(path['hops'][-1])
    report['field_attribution'] = dict(bindings={register: item['type'] for register, item in bound.items()},
        generated_sha256=hashlib.sha256(generated_path.read_bytes()).hexdigest(),
        layout_sha256=hashlib.sha256(layout_path.read_bytes()).hexdigest(),
        contract='Explicit ownership bindings; checked generated widths; not automatic ownership inference or equivalence proof.')


def analyze(netlist_path, timing_path, utilization_path):
    netlist, timing, utilization = (p.read_text() for p in (netlist_path, timing_path, utilization_path))
    modules, drivers, instances = {}, {}, {}
    for module in re.finditer(r'^module (\w+)\s*\(.*?^endmodule', netlist, re.M | re.S):
        name, body = module[1], module[0]
        inits = dict(re.findall(r'defparam\s+(\S+)\s*\.INIT\s*=\s*([^;]+)', body))
        cells = list(re.finditer(r'^  (\w+)\s+(\S+)\s*\(\s*(.*?)^\);', body, re.M | re.S))
        counts = Counter(cell[1] for cell in cells)
        enables = Counter()
        modules[name] = dict(cells=dict(counts),
            flip_flops=sum(v for k, v in counts.items() if k.startswith('DFF')),
            lut_primitives=sum(v for k, v in counts.items() if k.startswith('LUT')),
            mux_primitives=sum(v for k, v in counts.items() if k.startswith('MUX')))
        for cell in cells:
            ports = dict(re.findall(r'\.(\w+)\((.*?)\)', cell[3]))
            instance = cell[2].lstrip('\\')
            item = dict(cell_type=cell[1], instance=instance, ports=ports, init=inits.get(cell[2]))
            instances[name, instance] = item
            if cell[1].startswith('DFF') and 'CE' in ports:
                enables[ports['CE'].strip()] += 1
            for output in ('Q', 'F', 'O'):
                if output not in ports:
                    continue
                drivers[name, ports[output].strip()] = item
        modules[name]['clock_enable_nets'] = [dict(net=net, register_loads=count)
                                               for net, count in enables.most_common()]
    resources = {}
    for label in ('Logic', 'Register', 'CLS', 'BSRAM', 'DSP'):
        found = re.search(r'^\s*'+label+r'\s*\|\s*(\d+(?:\.\d+)?)/(\d+)\s*\|\s*(\d+)%', utilization, re.M)
        if not found:
            raise ValueError(f'missing resource: {label}')
        resources[label] = dict(used=float(found[1]), available=int(found[2]), percent=int(found[3]))
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
    detailed = setup_details(timing)
    scope_modules = {'core': 'sdram_pipeline_risc', 'cache': 'sdram_pipeline_cache',
                     'mem': 'sdram_burst_memory', 'pll': 'sdram_pll'}
    for path in detailed:
        for hop in path['hops']:
            scope, _, local = hop['node'].partition('/')
            instance = local.rsplit('/', 1)[0]
            hop['cell'] = instances.get((scope_modules.get(scope, scope), instance))
    return dict(resources=resources, synthesized_modules=modules, high_fanout=fanout,
                setup_paths=paths, detailed_setup_paths=detailed,
                setup_endpoint_pins=dict(Counter(path['endpoint_pin'] for path in detailed)),
                target_mhz=float(frequency[1]), fmax_mhz=float(frequency[2]),
                inputs={str(p.resolve()): hashlib.sha256(p.read_bytes()).hexdigest()
                        for p in (netlist_path, timing_path, utilization_path)})


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('build', type=Path, help='Gowin output directory containing impl/')
    p.add_argument('--out', type=Path, required=True)
    p.add_argument('--generated', type=Path, help='exact generated CPU RTL, for checked field attribution')
    p.add_argument('--layout', type=Path, help='JSON emitted by cabal run -v0 pipeline-layout')
    p.add_argument('--register-layout', action='append', default=[], metavar='REGISTER=TYPE',
                   help='explicit register ownership binding, checked against generated width')
    args = p.parse_args()
    if any((args.generated, args.layout, args.register_layout)) and not all((args.generated, args.layout, args.register_layout)):
        p.error('field attribution requires --generated, --layout and --register-layout together')
    report = analyze(args.build/'impl/gwsynthesis/sdram_test.vg',
                     args.build/'impl/pnr/sdram_test.tr', args.build/'impl/pnr/sdram_test.rpt.txt')
    if args.layout:
        attribute_fields(report, args.generated, args.layout, args.register_layout)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(report, indent=2)+'\n')
    print(f'Logic {report["resources"]["Logic"]["used"]}, registers {report["resources"]["Register"]["used"]}, Fmax {report["fmax_mhz"]:.3f} MHz')


if __name__ == '__main__':
    main()
