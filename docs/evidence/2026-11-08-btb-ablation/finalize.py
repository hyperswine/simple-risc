from pathlib import Path
import json
R=Path(__file__).resolve().parents[2];B=R/'output/btb-ablation-2026-11-08';j=json.loads((B/'summary.json').read_text());rows=j['runs'];s=j['summary']
assert len(rows)==15 and all(s[v]['recorded']==5 for v in ('baseline','anchors','grouping'))
assert {r['status'] for r in rows}<={'pass','timing-fail','unrouted','timeout'}
def fmt(r):
 if 'fmax_mhz' in r:return f"{r['fmax_mhz']:.3f} MHz / {r['worst_setup_ns']:+.3f} ns ({r['status']})"
 return f"{r['unrouted_nets']:,} unrouted nets" if r['status']=='unrouted' else 'Timeout; no timing report'
lines=['Ten new routes are complete; the five imported baseline controls provide',
'a matched reference across the same five placement options.','',
'| Arm | Passes / 5 | Timing failures | Unrouted | Timeouts | Timing reports | Median completed Fmax |',
'|---|---:|---:|---:|---:|---:|---:|']
for v in ('baseline','anchors','grouping'):
 c=s[v]['status_counts'];m=s[v]['median_completed_fmax_mhz'];m='Unavailable' if m is None else f'{m:.3f} MHz'
 lines.append(f"| {v} | {c.get('pass',0)} | {c.get('timing-fail',0)} | {c.get('unrouted',0)} | {c.get('timeout',0)} | {s[v]['timing_reports']} | {m} |")
lines+=['','Medians are conditional on completed timing reports. Baseline has four',
'reports, anchors has five; missing routes are not assigned zero Fmax. The',
'median paired Fmax change for anchors on the four mutually completed',
'placements is +1.435 MHz, with three faster and one slower.','',
'| Placement | Baseline (imported) | Anchors only | Grouping only |','|---:|---|---|---|']
for p in range(5):
 r={v:next(r for r in rows if r['variant']==v and r['placement']==p) for v in ('baseline','anchors','grouping')}
 lines.append('| '+str(p)+' | '+' | '.join(fmt(r[v]) for v in ('baseline','anchors','grouping'))+' |')
lines+=['','Occupied CLS reported by the placer (including failed routes):','',
'| Placement | Baseline CLS | Anchors CLS | Grouping CLS |','|---:|---:|---:|---:|']
for p in range(5):
 lines.append('| '+str(p)+' | '+' | '.join(str(next(r for r in rows if r['variant']==v and r['placement']==p).get('CLS','Unavailable')) for v in ('baseline','anchors','grouping'))+' |')
lines+=['','## What the isolation shows','',
'**Anchoring is a viable placement candidate, with a tradeoff.** It completes',
'all five routes and passes three options, versus four completed routes and',
'two passes for baseline. It improves placements 0, 1 and 2 and makes',
'placement 4 routable, but loses the baseline placement-3 pass. Its best',
'margin is +0.079 ns versus baseline +0.504 ns; its passing margins are only',
'+0.026 to +0.079 ns. These are gains on the tested grid, not an across-the-board',
'improvement or a board-qualified replacement.','',
'Placements 1 and 2 have identical timing/site fingerprints in both baseline',
'and anchors. Both arms therefore still have two distinct *passing* reported',
'implementations. The 3/5 pass count is useful for these tool settings, but',
'it is not three independent passing placements.','',
'**The anchors do not eliminate the BTB feedback bottleneck.** Every anchored',
'worst path returns from a BTB RAM output to a BTB RAM address input. At',
'placement 3, median sampled BTB-to-BTB routing delay rises from 5.615 to',
'6.306 ns despite the adjacent sites. At placement 1, the failing baseline',
'fetch loop (-0.350 ns) and reset-to-E2-enable paths (-0.249 ns) recover;',
'anchored reset-to-E2-enable slack is +0.932 ns and BTB feedback becomes',
'limiting at +0.079 ns. The evidence points to a changed overall placement,',
'not a demonstrated shortening of the BTB return path.','',
'**This front-end region is harmful on the tested grid.** At placement 3 it',
'reaches only 67.992 MHz with 255 setup violations, and its reported peak',
'congestion is 0.972 versus baseline 0.917. The worst path is A to F. The',
'sampled median route delay grows from 6.172 to 8.492 ns for fetch-to-fetch,',
'and 6.390 to 9.153 ns for fetch-to-A. The register rectangle does not bind',
'every feeding LUT; free BTB RAMs land at R10[8] and R10[7], above the',
'R17–36 front region in that run. Restricting the state did not achieve the',
'intended improvement in physical locality.','',
'The critical-path samples can contain different endpoints across runs.',
'Their medians are diagnostic samples, not all-wire statistics or proof of',
'a particular congestion mechanism. The identical netlist gives no synthesis',
'area or logical fanout reduction. Occupied CLS is not uniformly lower with',
'anchors (for example, placement 0 rises from 8,687 to 8,776).','',
'Anchors alone and grouping alone both produce a routed timing report at',
'placement 3; the earlier combined experiment did not. That supports testing',
'constraint interactions, but does not identify a unique cause: the combined',
'experiment also widened the bus region. No full factorial test was run.','',
'## Decision and evidence','',
'Keep the canonical preset. Retain anchors-only as an optional candidate for',
'further qualification, particularly when testing future netlists. Do not',
'adopt this broad front-end group. A more targeted investigation should',
'examine the BTB feedback logic and its locality rather than assuming that',
'adjacent RAMs or a large register rectangle shorten the complete loop.','',
'Constraint membership, imported-control provenance and frozen hashes were',
'checked. The post-place files verify both requested anchor sites on every',
'completed anchored route (`CST_BSRAM` marks constrained sites). All reports',
'request 3,000 paths, and the same 81/48 MHz timing gate is used. No RTL or',
'default preset changed; no board was programmed. New functional simulation',
'was unnecessary for the identical frozen netlist.','',
'[Scripts, constraints, receipts and summaries](evidence/2026-11-08-btb-ablation/)',
'are retained with hashes. Full timing reports remain under',
'`output/btb-ablation-2026-11-08/`, with imported baseline report origins',
'explicitly recorded. Changes remain local and uncommitted.']
p=R/'docs/2026-11-08-BTB-PLACEMENT-ABLATIONS.md';t=p.read_text().replace('Status: running,','Status: complete,');p.write_text(t.split('## Results\n')[0]+'## Results\n\n'+'\n'.join(lines)+'\n')
p=R/'docs/README.md';t=p.read_text().replace('separate BTB anchors and front-end register grouping against the canonical five-placement baseline (running)','separate BTB anchors and front-end grouping across five placements; anchors route all five with 3 passes versus baseline 2; broad grouping rejected');p.write_text(t)
print('Final report written')
