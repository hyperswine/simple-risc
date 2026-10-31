#!/usr/bin/env python3
"""Group every path in a Gowin timing report by the structure it belongs to.

The report's start and end registers are mapped to pipeline fields with the
layout from `cabal run pipeline-layout`: the pipe register's bits are 'Pipe'
fields, and the stage payload registers (ds3_0, ds4, ds5, ds6 in the generated
Verilog: D, E1, E2, M) are the stage records' fields. Fields are then grouped
into front-end stages, and each path is summarised as "from stage -> to stage
(end field)".

A path ending on a clock-enable pin is marked "(CE)": synthesis turns both the
cache hold and any "keep the old value unless updated" register into enables,
so a CE endpoint is not necessarily the hold.

Usage:
  path_census.py REPORT.tr --layout layout.json [--json out.json] [--slack-below 0]
"""

import argparse
import collections
import json
import re
from pathlib import Path

# Generated register names of the stage payloads, by the record they hold.
PAYLOADS = {'ds3_0': 'Fetched', 'ds4': 'ExecuteOne', 'ds5': 'ExecuteTwo', 'ds6': 'MemoryStage'}
PAYLOAD_STAGE = {'Fetched': 'D', 'ExecuteOne': 'E1', 'ExecuteTwo': 'E2', 'MemoryStage': 'M'}

# Pipe fields by front-end stage.
PIPE_STAGE = {
    'pFetchPc': 'fetch', 'pInstructionPc': 'fetch', 'pInflight': 'fetch', 'pQueue': 'fetch',
    'pQueueRead': 'fetch', 'pQueueWrite': 'fetch', 'pOutstanding': 'fetch',
    'pBtb': 'btb', 'pBtbWrite': 'btb',
    'pA': 'A', 'pRas': 'A', 'pRasTop': 'A', 'pRedirectFront': 'A', 'pFrontTarget': 'A',
    'pFQueue': 'F', 'pFRead': 'F', 'pFWrite': 'F', 'pFCount': 'F',
    'pDSlot': 'D', 'pDOperands': 'D', 'pDFresh': 'D', 'pDBlocked': 'D',
    'pE1Slot': 'E1', 'pE2Slot': 'E2', 'pRedirect': 'E2', 'pRasResolvedTop': 'E2',
    'pMSlot': 'M',
}


def load_layout(path):
    layout = {}
    for record in json.loads(Path(path).read_text()):
        layout[record['type']] = record['fields']
    return layout


def field_at(fields, bit):
    for f in fields:
        if f['low'] <= bit <= f['high']:
            return f['name']
    return '?'


def classify(node, layout):
    """(stage, field) for a register instance path such as core/pipeState_5927_s0."""
    inst = node.split('/')
    top, name = inst[0], inst[-1] if len(inst) > 1 else inst[0]
    if top != 'core':
        return (top, top)
    if name.startswith('RAM_1'):
        return ('btb', 'btb table RAM')
    m = re.match(r'valids_(\d+)', name)
    if m or name.startswith('valids'):
        return ('btb', 'btb valid')
    m = re.match(r'pipeState_(\d+)_', name)
    if m:
        field = field_at(layout['Pipe'], int(m.group(1)))
        return (PIPE_STAGE.get(field, 'pipe'), field)
    for prefix, record in PAYLOADS.items():
        m = re.match(re.escape(prefix) + r'_(\d+)_', name)
        if m:
            stage = PAYLOAD_STAGE[record]
            return (stage, stage + '.' + field_at(layout[record], int(m.group(1))))
    m = re.match(r'machine_0_(\d+)_', name)
    if m:
        return ('machine', 'machine')
    if name.startswith('heldState'):
        return ('machine', 'heldState')
    return ('core-other', re.sub(r'_\d+.*', '', name))


def section(text, start, end):
    """The body of a numbered report section (the directory's copy is indented)."""
    m = re.search(r'^' + re.escape(start) + r'.*$', text, re.M)
    if not m:
        return ''
    n = re.search(r'^' + re.escape(end) + r'.*$', text[m.end():], re.M)
    return text[m.end():m.end() + n.start()] if n else text[m.end():]


def parse_report(text):
    """Setup paths only: hold, recovery and removal checks are other sections."""
    paths = []
    setup = section(text, '3.3.1 Setup Analysis Report', '3.3.2 Hold Analysis Report')
    for block in re.split(r'\n\s*Path\d+\s*\n', setup)[1:]:
        def get(label):
            m = re.search(label + r'\s*:\s*(\S+)', block)
            return m.group(1) if m else None
        slack = get('Slack')
        if slack is None:
            continue
        arrival = block.split('Data Required Path')[0]
        nodes = re.findall(r'^\s*[\d.]+\s+[\d.]+\s+\w+.*\s(\S+)\s*$', arrival, re.M)
        end_pin = nodes[-1].rsplit('/', 1)[-1] if nodes else '?'
        levels = re.search(r'Logic Level:\s*(\d+)', block)
        route = re.search(r'Arrival Data Path Delay:.*?route:\s*([\d.]+)\s+([\d.]+)%', block, re.S)
        paths.append({
            'slack': float(slack),
            'from': get('From'),
            'to': get('To'),
            'launch': get('Launch Clk'),
            'latch': get('Latch Clk'),
            'end_pin': end_pin,
            'levels': int(levels.group(1)) if levels else None,
            'route_share': float(route.group(2)) if route else None,
        })
    return paths


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('report', type=Path)
    p.add_argument('--layout', type=Path, required=True)
    p.add_argument('--json', type=Path)
    p.add_argument('--slack-below', type=float, default=0.0, help='count paths with slack below this (ns)')
    p.add_argument('--top', type=int, default=25)
    args = p.parse_args()
    layout = load_layout(args.layout)
    text = args.report.read_text(errors='replace')
    paths = parse_report(text)
    for path in paths:
        path['from_stage'], path['from_field'] = classify(path['from'], layout)
        path['to_stage'], path['to_field'] = classify(path['to'], layout)
        ce = ' (CE)' if path['end_pin'] == 'CE' else ''
        path['structure'] = f"{path['from_stage']} -> {path['to_stage']}{ce}"
    failing = [x for x in paths if x['slack'] < args.slack_below]
    print(f'{len(paths)} paths reported, {len(failing)} with slack below {args.slack_below} ns; '
          f'worst {min(x["slack"] for x in paths):.3f} ns' if paths else 'no paths')

    def table(key, title):
        groups = collections.defaultdict(list)
        for x in failing:
            groups[key(x)].append(x)
        rows = sorted(groups.items(), key=lambda kv: min(y['slack'] for y in kv[1]))
        print(f'\n{title}')
        print(f'  {"group":56} {"paths":>6} {"ends":>5} {"worst":>8} {"levels":>7} {"route%":>7}')
        for name, xs in rows[:args.top]:
            ends = len({y['to'] for y in xs})
            lv = [y['levels'] for y in xs if y['levels'] is not None]
            rt = [y['route_share'] for y in xs if y['route_share'] is not None]
            print(f'  {name[:56]:56} {len(xs):6d} {ends:5d} {min(y["slack"] for y in xs):8.3f} '
                  f'{(max(lv) if lv else 0):7d} {(sum(rt) / len(rt) if rt else 0):7.1f}')
        return [{'group': n, 'paths': len(xs), 'ends': len({y['to'] for y in xs}),
                 'worst': min(y['slack'] for y in xs)} for n, xs in rows]

    out = {
        'report': str(args.report),
        'paths': len(paths),
        'failing': len(failing),
        'by_structure': table(lambda x: x['structure'], 'BY STRUCTURE (from stage -> to stage)'),
        'by_end_field': table(lambda x: x['to_field'] + (' (CE)' if x['end_pin'] == 'CE' else ''), 'BY END FIELD'),
        'by_start_field': table(lambda x: x['from_field'], 'BY START FIELD'),
        'by_clock': table(lambda x: f"{x['launch']} -> {x['latch']}", 'BY CLOCK'),
    }
    for start, end in (('3.5 High Fanout Nets Report', '3.6 Route Congestions Report'),
                       ('3.6 Route Congestions Report', '3.7 Timing Exceptions Report')):
        body = section(text, start, end).strip('\n')
        print('\n' + start.upper()[4:])
        print('\n'.join(line for line in body.splitlines() if line.strip() and not line.startswith('Report Command')))
        out[start[4:].lower().replace(' ', '_')] = body
    if args.json:
        out['detail'] = paths
        args.json.write_text(json.dumps(out, indent=1))


if __name__ == '__main__':
    main()
