#!/usr/bin/env python3
"""Logic depth of each pipeline structure, from a long timing report.

Groups the setup paths of a report (3,000 of them with SDRAM_REPORT_PATHS or
PNR_REPORT_PATHS) by structure, "from stage -> to stage", as path_census.py
does, and for each structure prints the number of paths, the worst slack, the
median and maximum logic levels and the median routing share. A structure
whose start and end stage are the same, or that goes between a stage and its
block RAM, is a loop: breaking it costs a cycle, so its depth is the number
that decides whether the design closes without placement luck.

Several reports can be given; the table is then per report, so the same
structure can be compared across netlists.

  loop_census.py REPORT.tr [REPORT.tr ...] --layout layout.json [--levels 7] [--json out.json]
"""
import argparse
import collections
import json
import statistics
from pathlib import Path

import path_census

LOOP_HINTS = {('btb', 'btb'), ('fetch', 'btb'), ('btb', 'fetch')}


def census(report, layout):
    paths = path_census.parse_report(Path(report).read_text(errors='replace'))
    groups = collections.defaultdict(list)
    for p in paths:
        a, af = path_census.classify(p['from'], layout)
        b, bf = path_census.classify(p['to'], layout)
        ce = ' (CE)' if p['end_pin'] == 'CE' else ''
        groups[f'{a} -> {b}{ce}'].append(dict(p, from_stage=a, to_stage=b, from_field=af, to_field=bf))
    rows = []
    for name, ps in groups.items():
        levels = [p['levels'] for p in ps if p['levels'] is not None]
        route = [p['route_share'] for p in ps if p['route_share'] is not None]
        worst = min(ps, key=lambda p: p['slack'])
        rows.append(dict(structure=name, paths=len(ps), failing=sum(p['slack'] < 0 for p in ps),
                         tight=sum(p['slack'] < 0.5 for p in ps), worst_slack=worst['slack'],
                         levels_median=statistics.median(levels) if levels else None,
                         levels_max=max(levels) if levels else None,
                         route_median=statistics.median(route) if route else None,
                         loop=(worst['from_stage'] == worst['to_stage']) or ((worst['from_stage'], worst['to_stage']) in LOOP_HINTS),
                         worst_from=worst['from_field'], worst_to=worst['to_field'], worst_levels=worst['levels']))
    rows.sort(key=lambda r: r['worst_slack'])
    return len(paths), rows


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('reports', nargs='+', type=Path)
    p.add_argument('--layout', type=Path, required=True)
    p.add_argument('--levels', type=int, default=7, help='also list the paths at or above this many levels')
    p.add_argument('--top', type=int, default=16)
    p.add_argument('--json', type=Path)
    args = p.parse_args()
    layout = path_census.load_layout(args.layout)
    out = {}
    for report in args.reports:
        total, rows = census(report, layout)
        out[str(report)] = dict(paths=total, structures=rows)
        print(f'\n{report}: {total} paths')
        print(f'  {"structure":34}{"paths":>6}{"fail":>5}{"<0.5":>5}{"worst":>8}{"lv med":>7}{"lv max":>7}{"route%":>7}  loop  worst path')
        for r in rows[:args.top]:
            print(f'  {r["structure"][:34]:34}{r["paths"]:6}{r["failing"]:5}{r["tight"]:5}{r["worst_slack"]:8.3f}'
                  f'{r["levels_median"] or 0:7.0f}{r["levels_max"] or 0:7}{r["route_median"] or 0:7.0f}  {"yes" if r["loop"] else "   "}  '
                  f'{r["worst_from"]} -> {r["worst_to"]} ({r["worst_levels"]} levels)')
        deep = [(r['structure'], r['levels_max'], r['worst_slack']) for r in rows if (r['levels_max'] or 0) >= args.levels]
        if deep:
            print(f'  structures with {args.levels}+ levels: ' + ', '.join(f'{s} ({l})' for s, l, _ in sorted(deep, key=lambda x: -x[1])))
    if args.json:
        args.json.write_text(json.dumps(out, indent=1))


if __name__ == '__main__':
    main()
