from pathlib import Path
import json,statistics
R=Path(__file__).resolve().parents[2];B=R/'output/btb-floorplan-2026-11-08'
j=json.loads((B/'summary.json').read_text());rows=j['runs'];assert len(rows)==30
assert {r['status'] for r in rows}<={'pass','timing-fail','timeout','unrouted'}
def result(r):
 if 'fmax_mhz' in r:return f"{r['fmax_mhz']:.3f} MHz / {r['worst_setup_ns']:+.3f} ns ({r['status']})"
 if r['status']=='unrouted':return f"{r['unrouted_nets']:,} unrouted nets"
 return 'Timeout; no timing report'
def median(v):return 'Unavailable' if v is None else f'{v:.3f} MHz'
s=j['summary'];lines=['All 30 attempts are complete. Each arm used the same netlist and the same',
'30-minute route limit. Timeouts and unrouted results are non-passes, with',
'unknown Fmax; they are not assigned an artificial zero-frequency result.','',
'| Arm | Passes / 15 | Timing failures | Unrouted | Timeouts | Median of completed timing reports |',
'|---|---:|---:|---:|---:|---:|']
for v in ('baseline','candidate'):
 x=s[v];c=x['status_counts'];lines.append(f"| {v} | {c.get('pass',0)} | {c.get('timing-fail',0)} | {c.get('unrouted',0)} | {c.get('timeout',0)} | {median(x['median_completed_fmax_mhz'])} |")
lines+=['','The median column is conditional on completed reports and excludes unrouted',
'and timed-out settings. It must not be presented as the median of all 15',
'implementations. `summary.json` also records conservative bounds for the',
'full-grid median and counts distinct timing/site fingerprints.','',
'| Requested frequency option | Placement | Baseline | Candidate |','|---:|---:|---|---|']
for target in (87,89,91):
 for placement in range(5):
  pair={r['variant']:r for r in rows if r['target']==target and r['placement']==placement}
  lines.append(f"| {target} | {placement} | {result(pair['baseline'])} | {result(pair['candidate'])} |")
lines+=['','## Interpretation and decision','']
if s['candidate']['timed_reports']==0:
 lines+=['The candidate produced **no completed routed timing report**. Its pass count',
'is zero, and neither its Fmax distribution nor BTB/front-end route-delay',
'improvement can be measured from these attempts. The baseline has working',
'implementations under the same conditions. **Do not adopt this candidate.**','',
'This rejects the tested combination of region geometry, register grouping',
'and BTB anchors under this budget. It does not establish that locality is',
'unhelpful, or identify which of those three choices caused the failures.',
'The constraints bind registers and two RAMs; they do not explicitly bind',
'all feeding LUTs. The 50% area allowance is not a routing-capacity guarantee.','']
lines+=['The frequency-option repetitions did not add distinct baseline timing/site',
'outcomes in the completed comparisons. Treat the five placement options as',
'explicit configurations, and do not describe the requested 15 rows as 15',
'independent physical samples. Future target sweeps need a verified PNR',
'control that actually changes implementation while preserving an 81 MHz',
'acceptance check; synthesis-frequency options on a frozen netlist are not',
'established as that control.','',
'Synthesis area and logical fanout are identical by construction. In the',
'unrouted placement-4 reports, candidate occupied CLS is 8,610 versus baseline',
'8,629, but unrouted nets rise from 557 to 3,454. Those packing counts belong',
'to incomplete routes and do not constitute a usable area win.','',
'The next diagnostic would separate BTB anchoring from front-end grouping',
'and relax the region geometry, measuring each constraint contribution.',
'No further candidate is implemented or swept in this experiment.','',
'## Validation and evidence','',
'Baseline constraints regenerated identically; production netlist and ROM',
'hashes were shared by both arms. Generated instance membership was checked',
'for existence and duplicates. Gowin accepted the corrected constraints.',
'The existing baseline timing values reproduce exactly. No RTL changed, so',
'no new functional behavior or simulation qualification is claimed. No board',
'was programmed; canonical presets and floorplan remain unchanged.','',
'[Reproduction scripts, constraints, receipts and summaries](evidence/2026-11-08-btb-floorplan/)',
'are retained with a hash manifest. Full 3,000-path reports remain under',
'`output/btb-floorplan-2026-11-08/`, identified by per-run timing hashes.',
'All changes remain local and uncommitted.']
p=R/'docs/2026-11-08-BTB-FRONTEND-FLOORPLAN.md';text=p.read_text().replace('Status: running,','Status: complete,');text=text.split('## Results\n')[0]+'## Results\n\n'+'\n'.join(lines)+'\n';p.write_text(text)
p=R/'docs/README.md';t=p.read_text().replace('matched 15-setting baseline/candidate placement sweep (running)','completed 15-setting baseline/candidate placement sweep; candidate fails routability; frequency-option duplicates identified');p.write_text(t)
print('Report finalized')
