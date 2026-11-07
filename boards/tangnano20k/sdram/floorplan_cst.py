#!/usr/bin/env python3
"""Region constraints for the core's registers, from a plan and a netlist.

A plan is a text file with one group per line:

  NAME  REGION  SELECTOR

REGION is a Gowin location range, R[first:last]C[first:last] (SUG1541: a
colon between two corners is a syntax error). SELECTOR is a regular
expression searched in "part: field", the names area_census.py prints, for
example `^machine: (csr|bus)` or `E2\\.e2Candidates`. Lines starting with #
are comments. A register matched by several lines belongs to the first.

Only registers are named: their LUTs carry generated names and follow the
registers they feed.

A line `free REGEX` (or --free REGEX, which wins) leaves out of every group
the registers that have a one-cycle path (through LUTs only) to or from a
register whose "part: field" matches REGEX. With `free ^pipeline` a group of
slow-path registers keeps only the ones the pipeline neither reads nor
writes directly, so moving the group cannot stretch a pipeline path.

The output is a .cst fragment for SDRAM_REGION_CST or pnr_only.sh, in the
two statements a group needs:

  GROUP name = {"core/reg_a" "core/reg_b"};
  GRP_LOC name R[2:9]C[2:55];

  floorplan_cst.py PLAN NETLIST.vg --layout layout.json [-o region.cst]
"""
import argparse
import re
import sys
from pathlib import Path

import area_census
import path_census

REGION = re.compile(r'^R\[\d+:\d+\]C\[\d+:\d+\]$')


def read_plan(path):
    """(groups, free pattern or None)."""
    plan, free = [], None
    for number, line in enumerate(Path(path).read_text().splitlines(), 1):
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        parts = line.split(None, 2)
        if len(parts) == 2 and parts[0] == 'free':
            free = parts[1]
            continue
        if len(parts) != 3 or not REGION.match(parts[1]) or not re.match(r'^[A-Za-z]\w*$', parts[0]):
            raise SystemExit(f'{path}:{number}: expected NAME R[a:b]C[c:d] SELECTOR')
        plan.append((parts[0], parts[1], re.compile(parts[2])))
    return plan, free


def boundary(cells, labels, pattern):
    """Registers one LUT cone away from a register whose label matches."""
    driver = {net: i for i, cell in enumerate(cells) for net in cell[3]}
    coupled = set()
    for i, label in labels.items():
        stack, seen, sources = list(cells[i][2]), set(), set()
        while stack:
            d = driver.get(stack.pop())
            if d is None or d in seen:
                continue
            seen.add(d)
            if cells[d][0] in area_census.LOGIC:
                stack.extend(cells[d][2])
            else:
                sources.add(d)
        if pattern.search(label):
            coupled.update(s for s in sources if not pattern.search(labels[s]))
        elif any(pattern.search(labels[s]) for s in sources):
            coupled.add(i)
    return coupled


MODULE = re.compile(r'^module (\S+) \(.*?^endmodule', re.S | re.M)
INSTANCE = re.compile(r'^  ([A-Za-z0-9_]+) (\S+)\s+\(', re.M)


def locate_core(netlist, module=None, instance=None):
    """The module whose registers are the pipeline's, and its path under top.

    The core is sdram_pipeline_risc itself in the usual build; a wrapper
    (package_dsp_counters.py) puts it one level down as sdram_pipeline_core,
    so the constraint names must carry the extra instance."""
    bodies = {m.group(1): m.group(0) for m in MODULE.finditer(netlist)}
    if module is None:
        module = next((name for name, body in bodies.items() if re.search(r'^  DFF\w* \\?pipeState_', body, re.M)), None)
        if module is None:
            raise SystemExit('no module with pipeState registers in the netlist')
    if instance is None:
        parents = {}
        for name, body in bodies.items():
            for kind, inst in INSTANCE.findall(body):
                if kind in bodies:
                    parents[kind] = (name, inst.lstrip('\\'))
        path, current = [], module
        while current in parents:
            parent, inst = parents[current]
            path.insert(0, inst)
            current = parent
        if not path:
            raise SystemExit(f'{module} is not instantiated under the top module')
        instance = '/'.join(path)
    return module, instance


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('plan', type=Path)
    p.add_argument('netlist', type=Path)
    p.add_argument('--layout', type=Path, required=True)
    p.add_argument('--instance', help='hierarchical instance name of the core module (found from the netlist when omitted)')
    p.add_argument('--module', help='module holding the pipeline registers (found from the netlist when omitted)')
    p.add_argument('--free', help='leave registers with a one-cycle path to or from a matching register unplaced')
    p.add_argument('-o', '--output', type=Path)
    args = p.parse_args()
    layout = path_census.load_layout(args.layout)
    plan, free = read_plan(args.plan)
    free = args.free or free
    netlist = args.netlist.read_text()
    module, instance = locate_core(netlist, args.module, args.instance)
    print(f'core module {module} at {instance}', file=sys.stderr)
    cells = area_census.core_cells(netlist, module)
    labels = {i: ': '.join(area_census.group(kind, name, layout))
              for i, (kind, name, _, _) in enumerate(cells) if kind not in area_census.LOGIC}
    coupled = boundary(cells, labels, re.compile(free)) if free else set()
    members = {name: [] for name, _, _ in plan}
    freed = {name: 0 for name, _, _ in plan}
    for i, (kind, name, _, _) in enumerate(cells):
        if not kind.startswith('DFF') or '$' in name:
            continue
        for group, _, selector in plan:
            if selector.search(labels[i]):
                if i in coupled:
                    freed[group] += 1
                else:
                    members[group].append(name)
                break
    lines = [f'// Generated by floorplan_cst.py from {args.plan.name}']
    for group, region, selector in plan:
        names = members[group]
        if not names:
            raise SystemExit(f'group {group}: no register matches {selector.pattern}')
        print(f'{group:12} {region:18} {len(names):5} registers, {freed[group]} left free', file=sys.stderr)
        lines.append(f'GROUP {group} = {{' + ' '.join(f'"{instance}/{n}"' for n in names) + '};')
        lines.append(f'GRP_LOC {group} {region};')
    text = '\n'.join(lines) + '\n'
    if args.output:
        args.output.write_text(text)
    else:
        sys.stdout.write(text)


if __name__ == '__main__':
    main()
