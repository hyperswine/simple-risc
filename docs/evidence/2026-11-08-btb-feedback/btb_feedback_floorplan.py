#!/usr/bin/env python3
"""Experimental BTB DO-to-ADB combinational-cone region on the frozen netlist.

Keeps sequential boundaries free and closes whole ALU carry chains. Emits only
an added GROUP/GRP_LOC pair; callers retain canonical regions and RAM anchors.
"""
import argparse
import collections
import hashlib
import json
import math
import re
import statistics
from pathlib import Path

import area_census
import floorplan_cst
import frontend_floorplan


def scalar_nets(expression):
    result = []
    for net in area_census.nets(expression):
        match = re.fullmatch(r'(.+)\[(\d+):(\d+)\]', net)
        if match:
            lo, hi = sorted((int(match[2]), int(match[3])))
            result.extend(f'{match[1]}[{i}]' for i in range(lo, hi + 1))
        else:
            result.append(net)
    return result


def extract(text):
    module, instance = floorplan_cst.locate_core(text)
    body = re.search(r'^module ' + re.escape(module) + r' \(.*?^endmodule', text, re.S | re.M)[0]
    if re.search(r'\bassign\b', body):
        raise ValueError('continuous assignments require alias resolution')
    cells = []
    for kind, name, pins in area_census.INSTANCE.findall(body):
        pins = {pin: scalar_nets(expr) for pin, expr in area_census.PIN.findall(pins)}
        cells.append(dict(kind=kind, name=name.lstrip('\\'), pins=pins,
                          inputs=[n for p, ns in pins.items() if p not in area_census.OUTPUT_PINS for n in ns],
                          outputs=[n for p, ns in pins.items() if p in area_census.OUTPUT_PINS for n in ns]))
    btb = [i for i, c in enumerate(cells) if c['kind'] == 'SDPB'
           and re.fullmatch(r'RAM_1_RAM_1_0_[01]_s', c['name'])]
    if len(btb) != 2:
        raise ValueError('expected the two known BTB SDPB halves')
    driver = {}
    users = collections.defaultdict(set)
    for i, c in enumerate(cells):
        for net in c['outputs']:
            if net in driver:
                raise ValueError(f'multiple drivers for {net}')
            driver[net] = i
        for net in c['inputs']:
            users[net].add(i)
    def walk(nets, forward):
        seen, stack = set(), list(nets)
        while stack:
            net = stack.pop()
            ids = users[net] if forward else ([driver[net]] if net in driver else [])
            for i in ids:
                if cells[i]['kind'] in area_census.LOGIC and i not in seen:
                    seen.add(i)
                    stack.extend(cells[i]['outputs' if forward else 'inputs'])
        return seen
    forward = walk([n for i in btb for n in cells[i]['pins']['DO']], True)
    backward = walk([n for i in btb for n in cells[i]['pins']['ADB']], False)
    cone = forward & backward
    selected = set(cone)
    # Packing must not split a hard carry chain at the cone's boundary.
    stack = [i for i in cone if cells[i]['kind'] == 'ALU']
    while stack:
        i = stack.pop()
        neighbours = {driver[n] for n in cells[i]['pins'].get('CIN', []) if n in driver}
        neighbours.update(j for n in cells[i]['pins'].get('COUT', []) for j in users[n]
                          if n in cells[j]['pins'].get('CIN', []))
        for j in neighbours:
            if cells[j]['kind'] == 'ALU' and j not in selected:
                selected.add(j)
                stack.append(j)
    if not selected:
        raise ValueError('empty feedback cone')
    return instance, cells, cone, selected


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('netlist', type=Path)
    p.add_argument('--reports', type=Path, nargs='+', required=True)
    p.add_argument('--packing-report', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--json', type=Path, required=True)
    args = p.parse_args()
    instance, cells, cone, selected = extract(args.netlist.read_text())
    names = {instance + '/' + cells[i]['name'] for i in selected}
    locations, report_records = [], []
    for report in args.reports:
        text = report.read_text()
        observed = set()
        for row, col, name in re.findall(r'\bR(\d+)C(\d+)\S*\s+(\S+)/[^\s/]+\s*$', text, re.M):
            if name in names:
                observed.add((name, int(row), int(col)))
        locations.extend(observed)
        report_records.append(dict(path=str(report), sha256=hashlib.sha256(report.read_bytes()).hexdigest(),
                                   observed_members=len({n for n, _, _ in observed})))
    if not locations:
        raise ValueError('no feedback cells observed in reference timing reports')
    # Fixed 12-column band centered on median observed reference placement.
    # Each (cell, location) gets one vote per report, not one per timing path.
    center = math.floor(statistics.median(c for _, _, c in locations) + 0.5)
    col0 = max(2, min(44, center - 5))
    lut_eq = sum(area_census.LOGIC[cells[i]['kind']] for i in selected)
    rpt = args.packing_report.read_text()
    packing = int(re.search(r'^  Logic\s+\|\s+(\d+)/', rpt, re.M)[1]) / int(re.search(r'^  CLS\s+\|\s+(\d+)/', rpt, re.M)[1])
    demand = math.ceil(1.5 * lut_eq / packing)
    # Include fabric on both sides of the RAM row, then expand symmetrically.
    radius = 1
    region = (28 - radius, 28 + radius, col0, col0 + 11)
    while frontend_floorplan.capacity(region) < demand:
        radius += 1
        if radius > 25:
            raise ValueError('feedback demand exceeds available region')
        region = (28 - radius, 28 + radius, col0, col0 + 11)
    lo, hi, left, right = region
    loc = f'R[{lo}:{hi}]C[{left}:{right}]'
    args.output.write_text('GROUP btb_feedback = {' + ' '.join(f'"{n}"' for n in sorted(names)) + '};\n'
                           + f'GRP_LOC btb_feedback {loc};\n')
    record = dict(selection='combinational reachability from BTB DO intersected with fan-in of BTB ADB; complete carry chains',
                  netlist_sha256=hashlib.sha256(args.netlist.read_bytes()).hexdigest(),
                  cone_cells=len(cone), carry_closure_added=len(selected - cone), members=len(selected),
                  types=dict(collections.Counter(cells[i]['kind'] for i in selected)), lut_equivalents=lut_eq,
                  measured_logic_per_cls=packing, headroom=1.5, required_cls=demand,
                  region=loc, region_coordinates=region, conservative_capacity_cls=frontend_floorplan.capacity(region),
                  column_center_from_reference_median=center, reference_reports=report_records,
                  cells=[dict(name=instance+'/'+cells[i]['name'],kind=cells[i]['kind'],cone=i in cone) for i in sorted(selected)])
    args.json.write_text(json.dumps(record, indent=2)+'\n')
    print(json.dumps({k:v for k,v in record.items() if k not in ('cells','reference_reports')},indent=2))


if __name__ == '__main__':
    main()
