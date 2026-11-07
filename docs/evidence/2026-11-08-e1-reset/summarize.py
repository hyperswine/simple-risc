import pathlib,sys,re,json,statistics
sys.path.insert(0,'boards/tangnano20k/sdram')
import path_census
b=pathlib.Path('output/refactor-e1-2026-11-08');rows=[]
for v in ('baseline','candidate'):
 for p in (3,0):
  d=b/f'{v}-p{p}';f=d/'impl/pnr/sdram_test.tr'
  if not f.exists(): continue
  t=f.read_text();paths=path_census.parse_report(t)
  rpt=(d/'impl/pnr/sdram_test.rpt.txt').read_text()
  fmax=re.search(r'clk_core\s+81\.000\(MHz\)\s+([\d.]+)\(MHz\)',t)
  congestion=path_census.section(t,'3.6 Route Congestions Report','3.7 Timing Exceptions Report')
  loads=path_census.section(t,'3.5 High Fanout Nets Report','3.6 Route Congestions Report')
  row=dict(variant=v,placement=p,fmax_mhz=float(fmax.group(1)) if fmax else None,reported_paths=len(paths),worst_setup_ns=min(x['slack'] for x in paths),mean_route_percent=statistics.mean(x['route_share'] for x in paths if x['route_share'] is not None),reset_start_paths=sum('reset_sync' in x['from'] for x in paths),ce_end_paths=sum(x['end_pin']=='CE' for x in paths),worst_path=paths[0],congestion_report=congestion,fanout_report=loads)
  for k in ('Logic','Register','CLS'):
   m=re.search(r'^  '+k+r'\s+\|\s+(\d+)/',rpt,re.M);row[k]=int(m.group(1)) if m else None
  rows.append(row)
(b/'physical-summary.json').write_text(json.dumps(rows,indent=2))
for r in rows: print({k:v for k,v in r.items() if k not in ('worst_path','congestion_report','fanout_report')})
