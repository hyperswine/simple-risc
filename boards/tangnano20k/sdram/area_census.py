#!/usr/bin/env python3
"""Where the core's logic goes: LUTs by the register they feed.

Reads the synthesized netlist (impl/gwsynthesis/sdram_test.vg), takes the
core module, and walks back from every register, block RAM and DSP through
the LUT and ALU cells that feed it. A cell is charged to the group of the
register it feeds; a cell feeding several groups is split evenly between
them, and the "only" column counts cells that feed one group alone. Registers
are named by path_census.classify, and the machine's bits outside the pipe by
the Machine record from `cabal run pipeline-layout`.

Sizes are LUT4 equivalents: a LUT5 is two LUT4s and a mux, an ALU cell is
one. The total matches the "LUT + ALU" line of the synthesis resource report.

  area_census.py NETLIST.vg --layout layout.json [--json out.json] [--top 40]
"""
import argparse
import collections
import json
import re
from pathlib import Path

import path_census

OUTPUT_PINS = {'F', 'SUM', 'COUT', 'Q', 'DO', 'DOUT', 'O', 'CASO', 'SOA', 'SOB'}
LOGIC = {'LUT1': 1, 'LUT2': 1, 'LUT3': 1, 'LUT4': 1, 'LUT5': 2, 'LUT6': 4, 'LUT7': 8, 'LUT8': 16,
         'ALU': 1, 'INV': 0, 'MUX2_LUT5': 0, 'MUX2_LUT6': 0, 'MUX2_LUT7': 0, 'MUX2_LUT8': 0}
INSTANCE = re.compile(r'^  ([A-Za-z0-9_]+) (\S+)\s+\(\n(.*?)\n\);', re.S | re.M)
PIN = re.compile(r'\.(\w+)\((.*?)\)\s*,?\s*$', re.M)

# Machine fields outside the pipe, by what they are for.
MACHINE_PARTS = [
    ('csr, trap, counters', r'cpu(TrapRegisters|Exception.*|Scratch|InterruptEnable|Csr.*|Cycle|Instret|Count.*|InterruptDue|Wake)$'),
    ('bus and devices', r'systemBus|cpuBus.*|cpuDevices|rxHolding|bootCause'),
    ('multiply/divide', r'cpuMul.*'),
    ('register write-back', r'cpuRegValid|cpuPendingWrite|cpuReadIndices|cpuRf.|clearRegisters'),
    ('phase datapath', r'cpu.*'),
]


def nets(expression):
    expression = expression.strip()
    if expression.startswith('{'):
        expression = expression[1:-1]
    names = (n.strip() for n in expression.split(','))
    return [n for n in names if n and n not in ('GND', 'VCC') and not re.match(r"^\d+'", n)]


def core_cells(netlist, module):
    m = re.search(r'^module ' + re.escape(module) + r' \(.*?^endmodule', netlist, re.S | re.M)
    if not m:
        raise SystemExit(f'no module {module} in the netlist')
    cells = []
    for kind, name, pins in INSTANCE.findall(m.group(0)):
        ins, outs = [], []
        for pin, expression in PIN.findall(pins):
            (outs if pin in OUTPUT_PINS else ins).extend(nets(expression))
        cells.append((kind, name.lstrip('\\'), ins, outs))
    return cells


def group(kind, name, layout):
    """(part, field) of a register or block."""
    if not kind.startswith('DFF'):
        return ('blocks', kind)
    stage, field = path_census.classify('core/' + name, layout)
    if stage == 'machine' and field == 'machine':
        bit = int(re.match(r'machine_0_(\d+)', name).group(1))
        field = path_census.field_at(layout['Machine'], bit) if 'Machine' in layout else 'machine'
        part = next((part for part, pattern in MACHINE_PARTS if re.match(pattern, field)), 'machine')
        return ('machine: ' + part, field)
    if field == 'heldState':
        return ('machine: csr, trap, counters', 'heldState')
    if stage == 'core-other':
        return ('unnamed', field)
    return ('pipeline: ' + stage, field)


def census(cells, layout):
    driver = {net: i for i, cell in enumerate(cells) for net in cell[3]}
    members = collections.defaultdict(list)
    for i, (kind, name, _, _) in enumerate(cells):
        if kind not in LOGIC:
            members[group(kind, name, layout)].append(i)
    feeds = collections.defaultdict(set)
    for key, indices in members.items():
        stack = [net for i in indices for net in cells[i][2]]
        seen = set()
        while stack:
            d = driver.get(stack.pop())
            if d is None or d in seen:
                continue
            seen.add(d)
            if cells[d][0] in LOGIC:
                feeds[d].add(key)
                stack.extend(cells[d][2])
    split, only = collections.Counter(), collections.Counter()
    total = unattributed = 0
    for i, (kind, _, _, _) in enumerate(cells):
        if kind not in LOGIC:
            continue
        size = LOGIC[kind]
        total += size
        keys = feeds.get(i)
        if not keys:
            unattributed += size
            continue
        if len(keys) == 1:
            only[next(iter(keys))] += size
        for key in keys:
            split[key] += size / len(keys)
    registers = {key: len(indices) for key, indices in members.items()}
    return total, unattributed, split, only, registers


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('netlist', type=Path)
    p.add_argument('--layout', type=Path, required=True)
    p.add_argument('--module', default='sdram_pipeline_risc')
    p.add_argument('--json', type=Path)
    p.add_argument('--top', type=int, default=40)
    args = p.parse_args()
    layout = path_census.load_layout(args.layout)
    cells = core_cells(args.netlist.read_text(), args.module)
    total, unattributed, split, only, registers = census(cells, layout)
    print(f'{args.module}: {total} LUT4 equivalents; {unattributed} feed no register in the module')
    parts = collections.defaultdict(lambda: [0, 0.0, 0])
    for key in registers:
        row = parts[key[0]]
        row[0] += registers[key]
        row[1] += split[key]
        row[2] += only[key]
    print(f'\n  {"part":32}{"regs":>6}{"LUTs":>8}{"only":>8}{"share":>8}')
    for part, (regs, luts, alone) in sorted(parts.items(), key=lambda kv: -kv[1][1]):
        print(f'  {part:32}{regs:6}{luts:8.0f}{alone:8}{100 * luts / total:7.1f}%')
    print(f'\n  {"field":44}{"regs":>6}{"LUTs":>8}{"only":>8}')
    for key, luts in sorted(split.items(), key=lambda kv: -kv[1])[:args.top]:
        print(f'  {(key[0] + ": " + key[1])[:44]:44}{registers[key]:6}{luts:8.0f}{only[key]:8}')
    if args.json:
        args.json.write_text(json.dumps({
            'total': total, 'unattributed': unattributed,
            'parts': {part: dict(registers=r, luts=round(l, 1), only=o) for part, (r, l, o) in parts.items()},
            'fields': [dict(part=k[0], field=k[1], registers=registers[k], luts=round(split[k], 1), only=only[k])
                       for k in sorted(split, key=lambda k: -split[k])],
        }, indent=1))


if __name__ == '__main__':
    main()
