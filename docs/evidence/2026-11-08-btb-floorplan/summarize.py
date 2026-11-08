from pathlib import Path
import collections,json,re,statistics,sys,math,hashlib
ROOT=Path(__file__).resolve().parents[2]; B=ROOT/'output/btb-floorplan-2026-11-08'
sys.path.insert(0,str(ROOT/'boards/tangnano20k/sdram'))
import path_census,loop_census
layout=path_census.load_layout(B/'frozen/layout.json');rows=[];loops={}
for receipt in sorted(B.glob('*-t*-p*.json')):
 row=json.loads(receipt.read_text());name=receipt.stem;d=B/name;t=d/'impl/pnr/sdram_test.tr'
 if row['status']=='tool-error' and (d/'pnr.log').exists():
  unrouted=re.search(r'total (\d+) unrouted nets',(d/'pnr.log').read_text())
  if unrouted:row.update(raw_status='tool-error',status='unrouted',unrouted_nets=int(unrouted[1]))
 if t.exists() and row['status'] in ('pass','timing-fail'):
  text=t.read_text();f=re.search(r'clk_core\s+81\.000\(MHz\)\s+([\d.]+)\(MHz\)',text)
  ps=path_census.parse_report(text)
  posp_text=(d/'impl/pnr/sdram_test.posp').read_text()
  sites=[x for x in posp_text.splitlines() if x and not x.startswith('//')]
  row['report_fingerprint']=hashlib.sha256(json.dumps([ps,sites],sort_keys=True).encode()).hexdigest()
  row.update(fmax_mhz=float(f[1]) if f else None,worst_setup_ns=min(p['slack'] for p in ps),reported_paths=len(ps),worst_path=min(ps,key=lambda p:p['slack']))
  for k in ('Setup','Hold'):
   m=re.search(r'<Numbers of '+k+r' Violated Endpoints>:(\d+)',text);row[k.lower()+'_violations']=int(m[1]) if m else None
  rpt=(d/'impl/pnr/sdram_test.rpt.txt').read_text()
  for k in ('Logic','Register','CLS'):
   m=re.search(r'^  '+k+r'\s+\|\s+(\d+)/',rpt,re.M);row[k]=int(m[1]) if m else None
  congestion=path_census.section(text,'3.6 Route Congestions Report','3.7 Timing Exceptions Report')
  values=[float(x) for x in re.findall(r'R\d+C\d+\s+([\d.]+)',congestion)]
  row['peak_reported_congestion']=max(values) if values else None
  count,groups=loop_census.census(t,layout)
  blocks=re.split(r'\n\s*Path\d+\s*\n',path_census.section(text,'3.3.1 Setup Analysis Report','3.3.2 Hold Analysis Report'))[1:]
  delays=collections.defaultdict(list)
  for block in blocks:
   a=re.search(r'From\s*:\s*(\S+)',block);z=re.search(r'To\s*:\s*(\S+)',block)
   match=re.search(r'Arrival Data Path Delay:.*?cell:\s*([\d.]+).*?route:\s*([\d.]+)',block,re.S)
   if a and z and match:
    key=path_census.classify(a[1],layout)[0]+' -> '+path_census.classify(z[1],layout)[0]
    delays[key].append((float(match[1]),float(match[2])))
  loops[name]={'structures':groups,'absolute_delays_by_stage_pair':{k:{'paths':len(v),'median_cell_ns':statistics.median(x[0] for x in v),'median_route_ns':statistics.median(x[1] for x in v)} for k,v in delays.items()}}
  if row['variant']=='candidate':
   posp=(d/'impl/pnr/sdram_test.posp').read_text()
   row['btb_sites_verified']=all(f'core/{n} PLACE_{site}' in posp for n,site in json.loads((B/'regions.json').read_text())['bram_sites'].items())
 resource=d/'impl/pnr/sdram_test.rpt.txt'
 if resource.exists() and 'CLS' not in row:
  for k in ('Logic','Register','CLS'):
   m=re.search(r'^  '+k+r'\s+\|\s+(\d+)/',resource.read_text(),re.M);row[k]=int(m[1]) if m else None
  row['resources_from_incomplete_route']=True
 rows.append(row)
summary={}
for v in ('baseline','candidate'):
 rs=[r for r in rows if r['variant']==v];values=[r['fmax_mhz'] for r in rs if 'fmax_mhz' in r];missing=15-len(values)
 # Report medians conditional on completion; bound the full-grid median
 # without silently dropping timeouts (unknown Fmax treated as 0/+infinity).
 summary[v]={'completed_attempts':len(rs),'status_counts':dict(collections.Counter(r['status'] for r in rs)),'timed_reports':len(values),'distinct_report_fingerprints':len({r['report_fingerprint'] for r in rs if 'report_fingerprint' in r}),'median_completed_fmax_mhz':statistics.median(values) if values else None,'full_grid_median_lower_bound_mhz':statistics.median(values+[0]*missing),'full_grid_median_upper_bound_mhz':statistics.median(values+[float('inf')]*missing)}
 paired=[]
 for a in [r for r in rows if r['variant']=='baseline' and 'fmax_mhz' in r]:
  match=next((r for r in rows if r['variant']=='candidate' and r['target']==a['target'] and r['placement']==a['placement'] and 'fmax_mhz' in r),None)
  if match:paired.append(match['fmax_mhz']-a['fmax_mhz'])
for item in summary.values():
 if not math.isfinite(item['full_grid_median_upper_bound_mhz']):item['full_grid_median_upper_bound_mhz']=None
summary['paired_completed']={'count':len(paired),'median_delta_mhz':statistics.median(paired) if paired else None,'candidate_faster_count':sum(d>0 for d in paired)}
(B/'summary.json').write_text(json.dumps({'summary':summary,'runs':rows},indent=2)+'\n')
(B/'loop-census.json').write_text(json.dumps(loops,indent=2)+'\n')
print(json.dumps(summary,indent=2))
