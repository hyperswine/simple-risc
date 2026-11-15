#!/usr/bin/env python3
"""Extract area and core-clock timing, rejecting missing/wrong constraints."""
import argparse
import json
from pathlib import Path
import re


def measure(directory, frequency):
    directory=Path(directory)
    timing=(directory/'impl/pnr/deflate_test.tr').read_text()
    usage=(directory/'impl/pnr/deflate_test.rpt.txt').read_text()
    def match(pattern,text=timing):
        found=re.search(pattern,text,re.M|re.S)
        if not found: raise ValueError(f'{directory}: missing {pattern}')
        return found
    clock=match(r'^\s*\d+\s+clk_core\s+([\d.]+)\(MHz\)\s+([\d.]+)\(MHz\)')
    if abs(float(clock[1])-frequency)>.001:
        raise ValueError(f'{directory}: expected {frequency} MHz, got {clock[1]}')
    setup=int(match(r'<Numbers of Setup Violated Endpoints>:(\d+)')[1])
    hold=int(match(r'<Numbers of Hold Violated Endpoints>:(\d+)')[1])
    table=match(r'3\.1\.1 Setup Paths Table\s*<Report Command>:(.*?)3\.1\.2 Hold Paths Table')[1]
    worst=match(r'^\s*1\s+(-?[\d.]+)\s+(\S+)\s+(\S+)\s',table)
    resources={name.lower():int(match(r'^\s*'+name+r'\s*\|\s*([\d,]+)/',usage)[1].replace(',',''))
               for name in ['Logic','Register','CLS','BSRAM']}
    detail=match(r'Path Summary:.*?Logic Level:\s*(\d+).*?Arrival Data Path Delay: \(cell:\s*([\d.]+).*?route:\s*([\d.]+)')
    pulse=float(match(r'MPW Summary:\s*Slack:\s*([-\d.]+)')[1])
    return dict(minimum_pulse_slack_ns=pulse,constraint_mhz=frequency,fmax_mhz=float(clock[2]),setup_slack_ns=float(worst[1]),
                setup_violations=setup,hold_violations=hold,passes=setup==0 and hold==0 and float(worst[1])>=0 and pulse>=0,
                worst_from=worst[2],worst_to=worst[3],logic_levels=int(detail[1]),
                cell_ns=float(detail[2]),route_ns=float(detail[3]),**resources)


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('root',type=Path)
    parser.add_argument('--freq',type=float,default=84)
    args=parser.parse_args()
    result={f'p{p}':measure(args.root/f'p{p}',args.freq) for p in range(5)}
    (args.root/'results.json').write_text(json.dumps(result,indent=2)+'\n')
    print('| Placement | Fmax MHz | Slack ns | Setup / hold violations | CLS | Cell / route ns |')
    print('|---:|---:|---:|---:|---:|---:|')
    for p,r in result.items():
        print(f'| {p} | {r["fmax_mhz"]:.3f} | {r["setup_slack_ns"]:+.3f} | {r["setup_violations"]} / {r["hold_violations"]} | {r["cls"]} | {r["cell_ns"]:.3f} / {r["route_ns"]:.3f} |')

if __name__=='__main__':
    main()
