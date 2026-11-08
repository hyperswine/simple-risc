from pathlib import Path
import collections,hashlib,json,re,statistics,sys
R=Path(__file__).resolve().parents[2];B=R/'output/btb-ablation-2026-11-08'
sys.path.insert(0,str(R/'boards/tangnano20k/sdram'));import path_census,loop_census
layout=path_census.load_layout(B/'frozen/layout.json');rows=[];loops={}
for receipt in sorted(B.glob('*-p[0-4].json')):
 row=json.loads(receipt.read_text());name=receipt.stem;d=B/name;tr=d/'impl/pnr/sdram_test.tr';log=(d/'pnr.log').read_text()
 if row['status']=='tool-error':
  m=re.search(r'total (\d+) unrouted nets',log)
  if m:row.update(raw_status='tool-error',status='unrouted',unrouted_nets=int(m[1]))
 rpt=d/'impl/pnr/sdram_test.rpt.txt'
 if rpt.exists():
  for k in ('Logic','Register','CLS'):
   m=re.search(r'^  '+k+r'\s+\|\s+(\d+)/',rpt.read_text(),re.M);row[k]=int(m[1]) if m else None
 if tr.exists() and row['status'] in ('pass','timing-fail'):
  text=tr.read_text();paths=path_census.parse_report(text)
  m=re.search(r'clk_core\s+81\.000\(MHz\)\s+([\d.]+)\(MHz\)',text)
  row.update(fmax_mhz=float(m[1]),worst_setup_ns=min(p['slack'] for p in paths),reported_paths=len(paths),worst_path=min(paths,key=lambda p:p['slack']))
  for k in ('Setup','Hold'):
   row[k.lower()+'_violations']=int(re.search(r'<Numbers of '+k+r' Violated Endpoints>:(\d+)',text)[1])
  posp=(d/'impl/pnr/sdram_test.posp').read_text();sites=[s for s in posp.splitlines() if s and not s.startswith('//')]
  row['report_fingerprint']=hashlib.sha256(json.dumps([paths,sites],sort_keys=True).encode()).hexdigest()
  row['btb_sites']=[s for s in sites if 'core/RAM_1_RAM_1_0_' in s]
  if row['variant']=='anchors':
   row['anchors_verified']=all(re.search(r'core/RAM_1_RAM_1_0_'+str(i)+r'_s (?:CST|PLACE)_BSRAM_R28\['+str(12+i)+r'\]',posp) is not None for i in range(2))
   assert row['anchors_verified']
  congestion=path_census.section(text,'3.6 Route Congestions Report','3.7 Timing Exceptions Report')
  vals=[float(x) for x in re.findall(r'R\d+C\d+\s+([\d.]+)',congestion)];row['peak_reported_congestion']=max(vals) if vals else None
  count,groups=loop_census.census(tr,layout);delays=collections.defaultdict(list)
  blocks=re.split(r'\n\s*Path\d+\s*\n',path_census.section(text,'3.3.1 Setup Analysis Report','3.3.2 Hold Analysis Report'))[1:]
  for block in blocks:
   a=re.search(r'From\s*:\s*(\S+)',block);z=re.search(r'To\s*:\s*(\S+)',block)
   m=re.search(r'Arrival Data Path Delay:.*?cell:\s*([\d.]+).*?route:\s*([\d.]+)',block,re.S)
   if a and z and m:
    key=path_census.classify(a[1],layout)[0]+' -> '+path_census.classify(z[1],layout)[0];delays[key].append((float(m[1]),float(m[2])))
  loops[name]={'structures':groups,'absolute_delays_by_stage_pair':{k:{'paths':len(v),'median_cell_ns':statistics.median(x[0] for x in v),'median_route_ns':statistics.median(x[1] for x in v)} for k,v in delays.items()}}
 rows.append(row)
summary={}
for v in ('baseline','anchors','grouping'):
 rs=[r for r in rows if r['variant']==v];freqs=[r['fmax_mhz'] for r in rs if 'fmax_mhz' in r]
 summary[v]={'recorded':len(rs),'status_counts':dict(collections.Counter(r['status'] for r in rs)),'timing_reports':len(freqs),'median_completed_fmax_mhz':statistics.median(freqs) if freqs else None,'distinct_report_fingerprints':len({r['report_fingerprint'] for r in rs if 'report_fingerprint' in r})}
 paired=[]
 for a in [r for r in rows if r['variant']=='baseline' and 'fmax_mhz' in r]:
  other=next((r for r in rs if r['placement']==a['placement'] and 'fmax_mhz' in r),None)
  if other:paired.append(other['fmax_mhz']-a['fmax_mhz'])
 if v!='baseline':summary[v]['paired_completed']={'count':len(paired),'median_fmax_delta_mhz':statistics.median(paired) if paired else None,'faster_count':sum(d>0 for d in paired)}
(B/'summary.json').write_text(json.dumps({'summary':summary,'runs':rows},indent=2)+'\n');(B/'loop-census.json').write_text(json.dumps(loops,indent=2)+'\n');print(json.dumps(summary,indent=2))
