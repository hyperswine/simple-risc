from pathlib import Path
import collections,json,re,statistics
B=Path(__file__).resolve().parent
region=json.loads((B/'feedback-region.json').read_text());names={c['name'] for c in region['cells']};r0,r1,c0,c1=region['region_coordinates'];runs={}
for receipt in sorted(B.glob('*-p[0-4].json')):
 row=json.loads(receipt.read_text());d=B/receipt.stem;tr=d/'impl/pnr/sdram_test.tr'
 if not tr.exists() or row['status'] not in ('pass','timing-fail'):continue
 text=tr.read_text();observed=set()
 for r,c,n in re.findall(r'\bR(\d+)C(\d+)\S*\s+(\S+)/[^\s/]+\s*$',text,re.M):
  if n in names:observed.add((n,int(r),int(c)))
 outside=[(n,r,c) for n,r,c in observed if not (r0<=r<=r1 and c0<=c<=c1)]
 if row['variant']=='feedback':assert not outside,(receipt,outside)
 blocks=re.split(r'\n\s*Path\d+\s*\n',text)[1:]
 worst=blocks[0];arrival=worst.split('Data Arrival Path:')[1].split('Data Required Path:')[0]
 worst_nodes={n.rsplit('/',1)[0] for n in re.findall(r'\s(core/\S+/\S+)\s*$',arrival,re.M)}
 delay=re.search(r'Arrival Data Path Delay:.*?cell:\s*([\d.]+).*?route:\s*([\d.]+)',worst,re.S)
 worst_details={'cell_ns':float(delay[1]),'route_ns':float(delay[2]),'grouped_cells':sorted(worst_nodes & names)}
 paths=[];endpoints={};missing=set()
 for block in re.split(r'\n\s*Path\d+\s*\n',text)[1:]:
  arrival=block.split('Data Arrival Path:')[-1].split('Data Required Path:')[0]
  nodes=re.findall(r'\s(core/\S+/\S+)\s*$',arrival,re.M)
  sources=[n for n in nodes if re.fullmatch(r'core/RAM_1_RAM_1_0_[01]_s/DO\[\d+\]',n)]
  targets=[n for n in nodes if re.fullmatch(r'core/RAM_1_RAM_1_0_[01]_s/ADB\[\d+\]',n)]
  if not sources or not targets:continue
  m=re.search(r'Arrival Data Path Delay:.*?cell:\s*([\d.]+).*?route:\s*([\d.]+)',block,re.S)
  if not m:continue
  internal={n.rsplit('/',1)[0] for n in nodes if '/RAM_1_RAM_1_0_' not in n}
  missing.update(internal-names)
  key=sources[0]+' -> '+targets[-1]
  p={'endpoint':key,'slack_ns':float(re.search(r'Slack\s*:\s*([-\d.]+)',block)[1]),'cell_ns':float(m[1]),'route_ns':float(m[2]),'members':sorted(internal)}
  paths.append(p)
  if key not in endpoints or p['slack_ns']<endpoints[key]['slack_ns']:endpoints[key]=p
 assert not missing,(receipt,missing)
 runs[receipt.stem]={'variant':row['variant'],'placement':row['placement'],'observed_members':len({n for n,_,_ in observed}),
  'unobserved_members':sorted(names-{n for n,_,_ in observed}),'observed_locations':sorted(observed),'outside_region':outside,
  'btb_feedback_paths':len(paths),'btb_feedback_cells_covered':True,
  'median_btb_route_ns':statistics.median(p['route_ns'] for p in paths) if paths else None,
  'worst_btb_slack_ns':min(p['slack_ns'] for p in paths) if paths else None,
  'worst_path_details':worst_details,'endpoints':endpoints}
paired=[]
for n in range(5):
 candidate=runs.get(f'feedback-p{n}')
 if not candidate:continue
 for control in ('baseline','anchors'):
  ref=runs.get(f'{control}-p{n}')
  if not ref:continue
  keys=sorted(candidate['endpoints'].keys() & ref['endpoints'].keys())
  deltas=[{'endpoint':k,'route_delta_ns':candidate['endpoints'][k]['route_ns']-ref['endpoints'][k]['route_ns'],
           'slack_delta_ns':candidate['endpoints'][k]['slack_ns']-ref['endpoints'][k]['slack_ns']} for k in keys]
  paired.append({'placement':n,'control':control,'matched_endpoints':len(keys),
    'median_matched_route_delta_ns':statistics.median(x['route_delta_ns'] for x in deltas) if deltas else None,
    'median_matched_slack_delta_ns':statistics.median(x['slack_delta_ns'] for x in deltas) if deltas else None,'deltas':deltas})
(B/'feedback-diagnostics.json').write_text(json.dumps({'runs':runs,'paired':paired},indent=2)+'\n')
print(json.dumps({'runs':{k:{f:v for f,v in x.items() if f not in ('observed_locations','outside_region','endpoints','unobserved_members')} for k,x in runs.items()},'paired':[{k:v for k,v in p.items() if k!='deltas'} for p in paired]},indent=2))
