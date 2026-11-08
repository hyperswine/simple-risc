#!/usr/bin/env python3
"""Experimental GW2AR-18C front-end floorplan, sized from the core census.

Keeps the existing slow-path boundary exclusion, groups fetch/A/F/BTB,
and anchors the two BTB RAM halves on adjacent central-row sites.
No default preset uses this generator. Capacity is a conservative rectangular
estimate (four CLS per tile, excluding all RAM/DSP rows), not a device mapper.
"""
import argparse
import json
import math
import re
from pathlib import Path

import area_census
import floorplan_cst
import path_census

HARD_ROWS = {10, 19, 28, 37, 46}


def capacity(region):
    r0, r1, c0, c1 = region
    return sum(r not in HARD_ROWS for r in range(r0, r1 + 1)) * (c1 - c0 + 1) * 4


def sized_region(required, anchor, columns):
    """Smallest row band within 2..53, centered at anchor (ties toward top)."""
    options = []
    for lo in range(2, 54):
        for hi in range(lo, 54):
            region = (lo, hi, *columns)
            if lo <= anchor <= hi and capacity(region) >= required:
                options.append((hi - lo, abs((lo + hi) / 2 - anchor), lo, region))
    if not options:
        raise ValueError('region demand exceeds the selected column band')
    return min(options)[-1]


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('netlist', type=Path)
    p.add_argument('--layout', type=Path, required=True)
    p.add_argument('--packing-report', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--json', type=Path, required=True)
    args = p.parse_args()
    text = args.netlist.read_text()
    module, instance = floorplan_cst.locate_core(text)
    layout = path_census.load_layout(args.layout)
    cells = area_census.core_cells(text, module)
    labels = {i: ': '.join(area_census.group(kind, name, layout))
              for i, (kind, name, _, _) in enumerate(cells) if kind not in area_census.LOGIC}
    boundary = floorplan_cst.boundary(cells, labels, re.compile('^pipeline'))
    _, _, charged, _, _ = area_census.census(cells, layout)
    rpt = args.packing_report.read_text()
    logic = int(re.search(r'^  Logic\s+\|\s+(\d+)/', rpt, re.M)[1])
    slices = int(re.search(r'^  CLS\s+\|\s+(\d+)/', rpt, re.M)[1])
    packing = logic / slices
    specs = [('csr', r'^machine: csr, trap, counters', 2, (2, 55)),
             ('bus', r'^machine: bus and devices', 53, (2, 19)),
             ('front', r'^pipeline: (fetch|A|F|btb):', 28, (16, 55))]
    lines = ['// Experimental census-sized BTB/front-end floorplan']
    records = []
    for group, pattern, anchor, cols in specs:
        selector = re.compile(pattern)
        names = [name for i, (kind, name, _, _) in enumerate(cells)
                 if kind.startswith('DFF') and '$' not in name and selector.search(labels[i])
                 and (group == 'front' or i not in boundary)]
        # Charge the entire selected field, even when boundary registers are
        # left free: conservative slow-region sizing rather than prorating it.
        luts = sum(v for key, v in charged.items() if selector.search(': '.join(key)))
        required = math.ceil(1.5 * max(luts / packing, len(names) / 2))
        region = sized_region(required, anchor, cols)
        r0, r1, c0, c1 = region
        loc = f'R[{r0}:{r1}]C[{c0}:{c1}]'
        if not names:
            raise ValueError(f'empty group: {group}')
        lines += [f'GROUP {group} = {{' + ' '.join(f'"{instance}/{n}"' for n in names) + '};',
                  f'GRP_LOC {group} {loc};']
        records.append(dict(group=group, selector=pattern, registers=len(names),
                            charged_lut_equivalents=luts, required_cls=required,
                            region=loc, conservative_capacity_cls=capacity(region)))
    btb = sorted(name for kind, name, _, _ in cells
                 if kind == 'SDPB' and re.fullmatch(r'RAM_1_RAM_1_0_[01]_s', name))
    if len(btb) != 2:
        raise ValueError('expected exactly two known BTB RAM halves; inspect this netlist')
    sites = ['BSRAM_R28[12]', 'BSRAM_R28[13]']
    for name, site in zip(btb, sites):
        lines.append(f'INS_LOC "{instance}/{name}" {site};')
    args.output.write_text('\n'.join(lines) + '\n')
    record = dict(core_module=module, instance=instance, headroom=1.5,
                  measured_logic_per_cls=packing, capacity_excluded_rows=sorted(HARD_ROWS),
                  regions=records, bram_sites=dict(zip(btb, sites)))
    args.json.write_text(json.dumps(record, indent=2) + '\n')
    print(json.dumps(record, indent=2))


if __name__ == '__main__':
    main()
