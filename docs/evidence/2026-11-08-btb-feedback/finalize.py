from pathlib import Path
import json,statistics
R=Path(__file__).resolve().parents[2];B=R/'output/btb-feedback-2026-11-08'
j=json.loads((B/'summary.json').read_text());rows=j['runs'];summary=j['summary'];diag=json.loads((B/'feedback-diagnostics.json').read_text());loops=json.loads((B/'loop-census.json').read_text())
assert len(rows)==15 and all(summary[v]['recorded']==5 for v in ('baseline','anchors','feedback'))
assert {r['status'] for r in rows}<={'pass','timing-fail','unrouted','timeout'}
def row(v,p):return next(x for x in rows if x['variant']==v and x['placement']==p)
def fmt(r):
 if 'fmax_mhz' in r:return f"{r['fmax_mhz']:.3f} MHz / {r['worst_setup_ns']:+.3f} ns ({r['status']})"
 return f"{r['unrouted_nets']:,} unrouted nets" if r['status']=='unrouted' else 'Timeout (1,800 s); no timing report'
lines=['Five new feedback-region attempts are complete. The ten baseline and',
'anchors-only controls are imported from the preceding sweeps.','',
'| Arm | Passes / 5 | Timing failures | Unrouted | Timeouts | Timing reports | Median completed Fmax |',
'|---|---:|---:|---:|---:|---:|---:|']
for v in ('baseline','anchors','feedback'):
 s=summary[v];c=s['status_counts'];m=s['median_completed_fmax_mhz'];m='Unavailable' if m is None else f'{m:.3f} MHz'
 lines.append(f"| {v} | {c.get('pass',0)} | {c.get('timing-fail',0)} | {c.get('unrouted',0)} | {c.get('timeout',0)} | {s['timing_reports']} | {m} |")
lines+=['','Medians exclude failures without timing reports and are therefore conditional,',
'not full-grid medians when fewer than five reports exist.','',
'| Placement | Baseline (imported) | Anchors only (imported) | Anchors + feedback region |',
'|---:|---|---|---|']
for p in range(5):lines.append('| '+str(p)+' | '+' | '.join(fmt(row(v,p)) for v in ('baseline','anchors','feedback'))+' |')
lines+=['','## Area and routing','',
'No synthesis change was made: this is the same logic, registers, DSPs and',
'BRAMs. Logical fanout is unchanged. Occupied CLS can change through packing; a',
'lower CLS count on a failed route is not a usable area win.','',
'| Placement | Baseline CLS | Anchors CLS | Feedback CLS | Feedback peak reported congestion |',
'|---:|---:|---:|---:|---:|']
for p in range(5):
 c=row('feedback',p).get('peak_reported_congestion');c='Unavailable' if c is None else f'{c:.3f}'
 lines.append('| '+str(p)+' | '+' | '.join(str(row(v,p).get('CLS','Unavailable')) for v in ('baseline','anchors','feedback'))+' | '+c+' |')
lines+=['','Matched completed placement comparisons:','']
comparisons={}
for control in ('baseline','anchors'):
 ds=[row('feedback',p)['fmax_mhz']-row(control,p)['fmax_mhz'] for p in range(5) if 'fmax_mhz' in row('feedback',p) and 'fmax_mhz' in row(control,p)]
 comparisons[control]={'paired':len(ds),'faster':sum(d>0 for d in ds),'slower':sum(d<0 for d in ds),'median_delta_mhz':statistics.median(ds) if ds else None}
 if ds:lines.append(f"- Versus {control}: {len(ds)} matched reports, {sum(d>0 for d in ds)} faster and {sum(d<0 for d in ds)} slower; median paired Fmax change {statistics.median(ds):+.3f} MHz.")
 else:lines.append(f'- Versus {control}: no mutually completed timing reports.')
lines+=['','Placements 1 and 2 duplicate each other in both control arms. Report fingerprints',
'compare the parsed timing paths and hard-block sites, not every placed fabric cell.','',
'| Arm | Distinct passing report fingerprints |','|---|---:|']
for v in ('baseline','anchors','feedback'):
 lines.append(f"| {v} | {len({r['report_fingerprint'] for r in rows if r['variant']==v and r['status']=='pass'})} |")
lines+=['','## Feedback-path observations','',
'| Completed feedback placement | Worst structure | Worst slack | Worst-path routing | Observed grouped cells / 37 | BTB DO-to-ADB paths in sample |',
'|---:|---|---:|---:|---:|---:|']
for p in range(5):
 key=f'feedback-p{p}'
 if key not in diag['runs']:continue
 d=diag['runs'][key];g=min(loops[key]['structures'],key=lambda x:x['worst_slack'])
 lines.append(f"| {p} | {g['structure']} | {g['worst_slack']:+.3f} ns | {d['worst_path_details']['route_ns']:.3f} ns | {d['observed_members']} | {d['btb_feedback_paths']} |")
lines+=['','All observed grouped-cell coordinates in completed feedback runs lie inside',
'R[27:29]C[35:46]; all completed runs retain the requested RAM anchors. The',
'reports do not expose every grouped cell, so this is partial location validation.','',
'| Placement | Comparison | Matching BTB endpoint pairs | Median route-delay change |',
'|---:|---|---:|---:|']
for x in diag['paired']:
 d=x['median_matched_route_delta_ns'];d='Unavailable' if d is None else f'{d:+.3f} ns'
 lines.append(f"| {x['placement']} | Feedback versus {x['control']} | {x['matched_endpoints']} | {d} |")
lines+=['','An absent BTB feedback path in the 3,000-path sample is not a measured zero',
'delay or a quantified improvement. The worst reported path can move elsewhere',
'without proving all BTB paths improved. Matching endpoint pins also does not',
'guarantee identical intermediate arcs or transition polarity.','',
'## Decision','',
'Do not adopt this feedback region. It routes all five options, matching','anchors-only, but passes two rather than three. Placements 0 and 4 improve','against anchors-only by +0.309 and +3.027 MHz; placements 1 and 2 lose','14.842 MHz each and placement 3 loses 2.588 MHz. The completed-grid median','falls from 81.171 to 76.389 MHz. These are different statistics from the','median paired change above. Placements 1 and 2 also duplicate each other in','the feedback arm, so the five options are not independent observations.','','The two passing margins are only +0.073 and +0.010 ns. Occupied CLS rises','in four of five placements against anchors-only, with medians 8,782 versus','8,718. There is no area or fanout win. The canonical preset remains unchanged;','anchors-only retains its earlier status as an optional candidate.','','The targeted group changes the limiting path without delivering an overall','improvement. All five new worst paths lie outside the 37 constrained cells:','A-to-F for placements 0–3 and M-to-D for placement 4. At placement 1, the','worst path has just five logic levels, 1.918 ns of cell delay and 12.812 ns','of routing delay (85.631% of its arrival data-path delay). This supports an','adverse change in surrounding placement/routing, not a claim that the BTB','feedback cone itself remains critical. It does not identify a unique router','mechanism or quantify how much the unreported BTB feedback paths improved.','','This negative result applies to this fixed 37-cell region, anchors and frozen','netlist, not every possible feedback floorplan. Before more geometry sweeps,','a useful next investigation would obtain targeted post-route BTB timing and','trace the shared address-mux side inputs and A-to-F control/data routes.','Broadening the region again is not justified by these results.','',
'## Evidence and validation','',
'Input hashes, all 15 netlist/constraint/option combinations, imported-control',
'provenance and the exact two-statement addition were checked. The graph-selected',
'cone covers the intermediate cells in all reported BTB DO-to-ADB paths. Tool',
'logs contain the constraint acceptance and route outcomes. Python compilation',
'and whitespace checks pass. Functional simulation was not rerun because no RTL',
'or synthesized netlist changed. No board was programmed and no preset changed.','',
'[Evidence, scripts and manifests](evidence/2026-11-08-btb-feedback/) retain the',
'compact reports and full-report hashes. Full timing reports remain under',
'`output/btb-feedback-2026-11-08/`. Changes are local and uncommitted.']
p=R/'docs/2026-11-08-BTB-FEEDBACK-REGION.md';s=p.read_text().replace('Status: running,','Status: complete,');p.write_text(s.split('## Results\n')[0]+'## Results\n\n'+'\n'.join(lines)+'\n')
(B/'paired-comparison.json').write_text(json.dumps(comparisons,indent=2)+'\n')
print('Final report written')
