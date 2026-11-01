#!/usr/bin/env python3
"""Summarize discrete phase observations without inventing electrical bounds."""
import argparse
import json
from pathlib import Path

FAILURES={'memory_fail','readback_fail','digest_fail'}

def classify(runs):
    if any(r['status'] in FAILURES for r in runs):
        return 'intermittent_fail' if any(r['status']=='pass' for r in runs) else 'fail'
    passes=sum(r['status']=='pass' for r in runs)
    return 'repeated_pass' if passes>=2 else 'single_pass' if passes else 'inconclusive' if runs else 'unmeasured'

def windows(phases, freq):
    indices={round(p/22.5) for p in phases}
    if not indices:return []
    if len(indices)==16:return [dict(all_sampled_phases_pass=True,edges_unlocated=True)]
    result=[]
    for start in sorted(indices):
        if (start-1)%16 in indices:continue
        seq=[start]
        while (seq[-1]+1)%16 in indices:seq.append((seq[-1]+1)%16)
        midpoint=(len(seq)-1)/2
        pick=min(range(len(seq)),key=lambda i:(abs(i-midpoint),abs(seq[i]*22.5-112.5)))
        margin=min(pick,len(seq)-1-pick)*22.5
        result.append(dict(passing_samples_degrees=[i*22.5 for i in seq],
            sampled_span_degrees=(len(seq)-1)*22.5,
            sampled_span_ns=(len(seq)-1)*22.5/360*1000/freq,
            lower_neighbor_degrees=(start-1)%16*22.5,
            upper_neighbor_degrees=(seq[-1]+1)%16*22.5,
            central_sample_degrees=seq[pick]*22.5,
            distance_to_passing_endpoint_degrees=margin,
            distance_to_passing_endpoint_ns=margin/360*1000/freq,
            phase_resolution_ns=1000/freq/16))
    return result

def summarize(base):
    data=json.loads((base/'measurements.json').read_text())['cases']
    groups=[]
    for freq in (48,54,60):
        for kind in ('standalone','integrated'):
            points=[]
            for i in range(16):
                phase=i*22.5
                runs=[c for c in data if c['frequency_mhz']==freq and c['kind']==kind and c['phase_degrees']==phase]
                points.append(dict(phase_degrees=phase,status=classify(runs),runs=len(runs),
                    passes=sum(c['status']=='pass' for c in runs),
                    inconclusive=sum(c['status']=='inconclusive' for c in runs)))
            group=dict(kind=kind,frequency_mhz=freq,points=points,
                observed_windows=windows([p['phase_degrees'] for p in points if p['status'] in ('single_pass','repeated_pass')],freq),
                repeated_windows=windows([p['phase_degrees'] for p in points if p['status']=='repeated_pass'],freq))
            for w in group['observed_windows']+group['repeated_windows']:
                if 'lower_neighbor_degrees' in w:
                    w['lower_neighbor_status']=points[round(w['lower_neighbor_degrees']/22.5)]['status']
                    w['upper_neighbor_status']=points[round(w['upper_neighbor_degrees']/22.5)]['status']
            groups.append(group)
    common=[]
    for freq in (48,54,60):
        relevant=[g for g in groups if g['frequency_mhz']==freq]
        phases=set(p['phase_degrees'] for p in relevant[0]['points'] if p['status']=='repeated_pass')
        phases.intersection_update(p['phase_degrees'] for p in relevant[1]['points'] if p['status']=='repeated_pass')
        common.append(dict(frequency_mhz=freq,windows=windows(phases,freq)))
    return dict(electrical_signoff=False,groups=groups,common_repeated_windows=common,
        runs=len(data),conclusive=sum(c['status']!='inconclusive' for c in data),
        assumptions=['No interpolation of unsampled phases.',
            'Distances to passing endpoints describe measured samples, not guaranteed setup/hold slack.',
            'A single memory/data failure excludes a phase even if another run passes.',
            'Repeated FPGA SRAM loads are controller resets, not board power cycles.',
            'Temperature and supply voltage were not instrumented.'])

def main():
    p=argparse.ArgumentParser();p.add_argument('out',type=Path);a=p.parse_args()
    s=summarize(a.out)
    (a.out/'summary.json').write_text(json.dumps(s,indent=2)+'\n')
    for g in s['groups']:
        good=[p['phase_degrees'] for p in g['points'] if p['status'] in ('single_pass','repeated_pass')]
        incomplete=[p['phase_degrees'] for p in g['points'] if p['status'] in ('unmeasured','inconclusive')]
        print(g['kind'],g['frequency_mhz'],'passing',good,'unmeasured/incomplete',incomplete)
    print('Runs:',s['runs'])

if __name__=='__main__':main()
