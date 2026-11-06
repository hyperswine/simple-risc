#!/usr/bin/env python3
"""Where a placed design put each structure, from a Gowin timing report.

Every cell on a reported setup path carries its location (R<row>C<col>, or
BSRAM_R<row>[n] / DSP_R<row>[n] for block RAM and DSP columns). Cells are
grouped by structure: the top-level instance (cache, mem, the clock bridge)
or, inside the core, the pipeline stage of the register they belong to
(path_census.py's classification). A report with many paths
(SDRAM_REPORT_PATHS=3000) covers most of the timing-relevant logic; logic on
no reported path is invisible here.

  placement_map.py REPORT.tr --layout layout.json [--json out.json]
"""
import argparse
import collections
import json
import re
from pathlib import Path

import path_census

LOCATION = re.compile(r'^(?:R(\d+)C(\d+)|(BSRAM|DSP)_R(\d+))')


def cells(report):
    """(location (row, col or None, kind), node) for every arrival-path cell."""
    setup = path_census.section(report, '3.3.1 Setup Analysis Report', '3.3.2 Hold Analysis Report')
    seen = {}
    for line in setup.splitlines():
        parts = line.split()
        # AT DELAY TYPE [RF] FANOUT LOC NODE
        if len(parts) < 6 or not re.match(r'^[\d.]+$', parts[0]) or parts[2] not in ('tC2Q', 'tINS', 'tNET', 'tCL'):
            continue
        loc, node = parts[-2], parts[-1]
        m = LOCATION.match(loc)
        if not m:
            continue
        if m.group(1):
            where = (int(m.group(1)), int(m.group(2)), 'logic')
        else:
            where = (int(m.group(4)), None, m.group(3).lower())
        seen[node.rsplit('/', 1)[0] if '/' in node else node] = where
    return seen


def group(node, layout):
    top = node.split('/')[0]
    if top != 'core':
        return top
    stage, _ = path_census.classify(node, layout)
    return 'core:' + stage


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('report', type=Path)
    p.add_argument('--layout', type=Path, required=True)
    p.add_argument('--json', type=Path)
    args = p.parse_args()
    layout = path_census.load_layout(args.layout)
    found = cells(args.report.read_text(errors='replace'))
    groups = collections.defaultdict(list)
    for node, where in found.items():
        groups[group(node, layout)].append(where)
    out = {}
    print(f'{len(found)} placed cells on reported paths')
    print(f'  {"structure":18} {"cells":>6} {"rows":>9} {"cols":>9} {"centre":>11}  block RAM / DSP rows')
    for name, places in sorted(groups.items(), key=lambda kv: -len(kv[1])):
        logic = [(r, c) for r, c, kind in places if kind == 'logic']
        blocks = sorted({f'{kind}R{r}' for r, c, kind in places if kind != 'logic'})
        if logic:
            rows = [r for r, _ in logic]
            cols = [c for _, c in logic]
            centre = (sum(rows) / len(rows), sum(cols) / len(cols))
            span = f'{min(rows)}-{max(rows)}', f'{min(cols)}-{max(cols)}'
        else:
            centre, span = None, ('-', '-')
        out[name] = dict(cells=len(places), logic_cells=len(logic), rows=span[0], cols=span[1],
                         centre=centre, blocks=blocks)
        c = f'R{centre[0]:.0f}C{centre[1]:.0f}' if centre else '-'
        print(f'  {name[:18]:18} {len(places):6} {span[0]:>9} {span[1]:>9} {c:>11}  {" ".join(blocks[:6])}')
    if args.json:
        args.json.write_text(json.dumps(out, indent=1))


if __name__ == '__main__':
    main()
