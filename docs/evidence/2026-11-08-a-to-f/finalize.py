from pathlib import Path
import json,statistics
R=Path.cwd();B=R/'output/a-to-f-2026-11-08';j=json.loads((B/'summary.json').read_text());rows=j['runs'];s=j['summary'];af=json.loads((B/'af-paths.json').read_text());loops=json.loads((B/'loop-census.json').read_text())
assert len(rows)==10 and all(s[v]['recorded']==5 for v in ('baseline','candidate'))
assert {r['status'] for r in rows}<={'pass','timing-fail','unrouted','timeout'}
def row(v,p):return next(r for r in rows if r['variant']==v and r['placement']==p)
def fmt(r):
 if 'fmax_mhz' in r:return f"{r['fmax_mhz']:.3f} MHz / {r['worst_setup_ns']:+.3f} ns ({r['status']})"
 return f"{r['unrouted_nets']:,} unrouted nets" if r['status']=='unrouted' else 'Timeout (1,800 s); no timing report'
lines=['Five new candidate attempts are complete. Five baseline measurements are',
'explicitly imported from the earlier canonical sweep.','',
'| Arm | Passes / 5 | Timing failures | Unrouted | Timeouts | Timing reports | Median completed Fmax |',
'|---|---:|---:|---:|---:|---:|---:|']
for v in ('baseline','candidate'):
 c=s[v]['status_counts'];m=s[v]['median_completed_fmax_mhz'];m='Unavailable' if m is None else f'{m:.3f} MHz'
 lines.append(f"| {v} | {c.get('pass',0)} | {c.get('timing-fail',0)} | {c.get('unrouted',0)} | {c.get('timeout',0)} | {s[v]['timing_reports']} | {m} |")
lines+=['','Medians exclude attempts without completed timing reports. They are conditional,',
'not a full-grid median when reports are missing.','',
'| Placement | Baseline | Validity refactor | Baseline CLS | Candidate CLS |',
'|---:|---|---|---:|---:|']
for p in range(5):
 a=row('baseline',p);b=row('candidate',p);lines.append(f"| {p} | {fmt(a)} | {fmt(b)} | {a.get('CLS','Unavailable')} | {b.get('CLS','Unavailable')} |")
pair=s['candidate']['paired_completed']
if pair['count']:lines+=['',f"Across {pair['count']} mutually completed placements, the candidate is faster in {pair['faster_count']}; median paired Fmax change is {pair['median_fmax_delta_mhz']:+.3f} MHz."]
lines+=['','## A-to-F timing and remaining bottlenecks','',
'| Placement | Baseline sampled A-to-F worst slack | Candidate sampled A-to-F worst slack | Baseline / candidate median A-to-F route delay | Baseline / candidate A-valid paths | Candidate overall worst structure |',
'|---:|---:|---:|---:|---:|---|']
for p in range(5):
 a=af['runs'].get(f'baseline-p{p}');b=af['runs'].get(f'candidate-p{p}');k=f'candidate-p{p}'
 def worst(x):return f"{x['worst']['slack_ns']:+.3f} ns" if x and x['worst'] else 'Unavailable'
 def route(x):return f"{x['median_route_ns']:.3f}" if x and x['median_route_ns'] is not None else 'Unavailable'
 def valid(x):return str(x['valid_paths']) if x else 'Unavailable'
 structure=min(loops[k]['structures'],key=lambda g:g['worst_slack'])['structure'] if k in loops else 'No timing report'
 lines.append(f"| {p} | {worst(a)} | {worst(b)} | {route(a)} / {route(b)} ns | {valid(a)} / {valid(b)} | {structure} |")
lines+=['','These samples can have different endpoints and sizes. Positive sampled A-to-F',
'slack does not prove every unreported A-to-F path improved. Missing A-valid',
'paths are not assigned zero delay. Direct synthesized fanout is the independent',
'evidence that the RTL changed the targeted structure.','',
'| Placement | Matching A-to-F endpoint pairs | Median matched route-delay change |',
'|---:|---:|---:|']
for p in af['paired']:
 d=p['median_matched_route_delta_ns'];d='Unavailable' if d is None else f'{d:+.3f} ns'
 lines.append(f"| {p['placement']} | {p['matched_endpoints']} | {d} |")
lines+=['','Endpoint matches use source register and destination pin; intermediate arcs',
'and transition polarities may differ. See `af-paths.json` for all observations.','',
'## Decision','',
'Do not adopt this patch into the canonical preset. All five candidate routes','complete, versus four baseline routes, but none passes the 81 MHz gate. The','best candidate is placement 4 at 80.545 MHz with -0.070 ns slack; baseline','placement 3 remains 84.447 MHz with +0.504 ns. All four mutually completed','placements regress. Placements 1 and 2 have identical timing/site fingerprints','in both arms; these are duplicated reported outcomes, not independent seeds.','','The source-level hypothesis is partly confirmed: A-valid direct fanout drops','77.5%, whole-design synthesis logic drops 202, and no candidate A-valid-to-F','path appears in the sample. This does not establish a routing-delay win.','The four matching A-to-F endpoint pairs at placement 0 have a median +0.803 ns','route-delay change. The other matched placements have no shared sampled','endpoint pairs. Sample-wide medians improve at 0–2 but worsen at 3; comparing','them as though they were the same paths would be misleading.','','The raw decode bottleneck remains. At placement 3, A.fRaw[9] to F.fUsesRs2','has -0.289 ns slack and 9.249 ns of routing delay. The overall worst paths','are fetch-to-BTB at placement 0, BTB feedback at 1–3, and M-to-D at 4. The','refactor changes the placement of competing loops rather than solving them.','Placement 0 already puts the RAM halves at the previous R28[12]/R28[13]','anchor pair without constraints, yet fails on fetch-to-BTB; RAM adjacency','alone is not an adequate explanation or remedy.','','Fewer synthesized logic resources do not translate into a smaller physical','footprint here. Occupied CLS increases at every option; its grid median rises',"from 8,649 to 8,782 (including the baseline unrouted placement's packing).",'Register, DSP, BSRAM and reset-load counts do not change. Retain the patch as','a verified experimental primitive, not a timing-qualified replacement.','','The next RTL hypothesis should address the remaining raw-instruction and','compressed-decode fanout, while monitoring fetch/BTB and M-to-D as competing','limits. This trial provides no basis for combining the patch with the failed','broad front-end or BTB feedback regions. Any new combination needs its own','matched sweep rather than an assumed additive benefit.','',
'## Evidence and validation','',
'The input audit verifies all ten netlist/constraint/option combinations, ROM',
'and clock equality, imported-control provenance, the candidate source hashes,',
'and the generated Pipe width against layout metadata. The canonical floorplan',
'is regenerated and checked for deterministic membership. All non-core wrapper',
'and peripheral inputs are copied unchanged. Functional receipts retain the',
'positive and negative controls. Python compilation and whitespace checks pass.','',
'[Patch, scripts, reports and receipts](evidence/2026-11-08-a-to-f/) include',
'compressed production/observed RTL and the synthesized candidate netlist, with',
'a SHA-256 manifest. Full timing reports remain in `output/a-to-f-2026-11-08/`;',
'evidence retains their hashes and compact reports. No board was programmed.',
'Default source and presets remain unchanged; this experiment is local and',
'uncommitted.']
p=R/'docs/2026-11-08-A-TO-F-VALIDITY-REFACTOR.md';text=p.read_text().replace('Status: running,','Status: complete,').replace('real structural reduction, but its placement-level benefit remains to be tested.','real structural reduction; the placement-level results follow.');p.write_text(text.split('## Results\n')[0]+'## Results\n\n'+'\n'.join(lines)+'\n');print('Final report written')
