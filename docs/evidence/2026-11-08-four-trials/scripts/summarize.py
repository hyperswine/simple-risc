import pathlib,re,json,sys,statistics
sys.path.insert(0,'boards/tangnano20k/sdram');import path_census
b=pathlib.Path('output/refactor-four-2026-11-08');rows=[]
for d in sorted(b.glob('*-p[03]')):
 tr=d/'impl/pnr/sdram_test.tr'
 if not tr.exists():continue
 t=tr.read_text();paths=path_census.parse_report(t);rpt=(d/'impl/pnr/sdram_test.rpt.txt').read_text()
 f=re.search(r'clk_core\s+81\.000\(MHz\)\s+([\d.]+)\(MHz\)',t)
 row={'run':d.name,'fmax_mhz':float(f.group(1)) if f else None,'worst_setup_ns':min(p['slack'] for p in paths),'reported_paths':len(paths),'mean_route_percent':statistics.mean(p['route_share'] for p in paths if p['route_share'] is not None),'reset_start_paths':sum('reset_sync' in p['from'] for p in paths),'ce_end_paths':sum(p['end_pin']=='CE' for p in paths),'worst_path':paths[0]}
 for name in ('Logic','Register','CLS'):
  m=re.search(r'^  '+name+r'\s+\|\s+(\d+)/',rpt,re.M);row[name]=int(m.group(1)) if m else None
 row['fanout_report']=path_census.section(t,'3.5 High Fanout Nets Report','3.6 Route Congestions Report')
 row['congestion_report']=path_census.section(t,'3.6 Route Congestions Report','3.7 Timing Exceptions Report')
 rows.append(row)
 print({k:v for k,v in row.items() if k not in ('worst_path','fanout_report','congestion_report')})
(b/'summary.json').write_text(json.dumps(rows,indent=2))
