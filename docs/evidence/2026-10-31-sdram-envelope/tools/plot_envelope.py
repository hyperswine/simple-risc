#!/usr/bin/env python3
"""Render the exported envelope summary (requires matplotlib)."""
import argparse
import json
from pathlib import Path
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.lines import Line2D

def main():
    p=argparse.ArgumentParser();p.add_argument('summary',type=Path);p.add_argument('output',type=Path)
    a=p.parse_args();s=json.loads(a.summary.read_text())
    styles={'repeated_pass':('o','#087f5b'),'single_pass':('o','#e6a100'),
            'fail':('x','#c92a2a'),'intermittent_fail':('X','#d9480f'),
            'inconclusive':('s','#868e96'),'unmeasured':('+','#ced4da')}
    fig,axes=plt.subplots(2,1,figsize=(12,6),sharex=True,layout='constrained')
    for ax,kind,title in zip(axes,['standalone','integrated'],['Standalone: all 8 MiB','Integrated: 7.875 MiB through CPU and cache']):
        for g in s['groups']:
            if g['kind']!=kind:continue
            for point in g['points']:
                marker,color=styles[point['status']]
                ax.scatter(point['phase_degrees'],g['frequency_mhz'],marker=marker,c=color,s=100,zorder=3)
        ax.set_title(title,loc='left',fontsize=12,fontweight='bold')
        ax.set_yticks([48,54,60]);ax.set_ylim(46,62)
        ax.set_ylabel('Clock (MHz)');ax.grid(alpha=.2);ax.set_axisbelow(True)
        for edge in ('top','right'):ax.spines[edge].set_visible(False)
    axes[-1].set_xticks([22.5*i for i in range(16)])
    axes[-1].set_xticklabels([f'{22.5*i:g}' for i in range(16)],rotation=45,ha='right')
    axes[-1].set_xlim(-10,347.5);axes[-1].set_xlabel('SDRAM PLL phase (degrees)')
    legend=[Line2D([0],[0],marker=m,color='none',markeredgecolor=c,markerfacecolor=c,
                   label=label,markersize=8) for label,(m,c) in [
        ('Repeated complete pass',styles['repeated_pass']),
        ('Data/readback failure',styles['fail']),
        ('Protocol/incomplete test',styles['inconclusive']),
        ('Mixed pass/failure',styles['intermittent_fail']),
        ('Single complete pass',styles['single_pass']),
        ('Not measured',styles['unmeasured'])]]
    fig.legend(handles=legend,loc='outside lower center',ncol=3,frameon=False,fontsize=9)
    fig.suptitle('Measured SDRAM phase envelope — one board, fixed images\n'
                 'Sampled points only; temperature and supply not instrumented',fontsize=14)
    fig.savefig(a.output,dpi=180)

if __name__=='__main__':main()
