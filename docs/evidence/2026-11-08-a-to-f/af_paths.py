from pathlib import Path
import json,re,statistics,sys
R=Path.cwd();B=R/'output/a-to-f-2026-11-08';sys.path.insert(0,str(R/'boards/tangnano20k/sdram'));import path_census as pc
layout=pc.load_layout(B/'candidate-physical/layout.json');runs={}
def detail(node):
 m=re.search(r'pipeState_(\d+)_',node)
 if not m:return pc.classify(node,layout)[1]
 bit=int(m[1]);field=next(f for f in layout['Pipe'] if f['low']<=bit<=f['high']);offset=bit-field['low']
 if field['name']=='pA':
  if offset==133:return 'A.valid'
  sub=next(f for f in layout['Fetched'] if f['low']<=offset<=f['high']);return 'A.'+sub['name']+f"[{offset-sub['low']}]"
 if field['name']=='pFQueue':
  bank=1-offset//133;offset%=133;sub=next(f for f in layout['Fetched'] if f['low']<=offset<=f['high']);return f"F[{bank}].{sub['name']}[{offset-sub['low']}]"
 return field['name']+f'[{offset}]'
for receipt in sorted(B.glob('*-p[0-4].json')):
 row=json.loads(receipt.read_text());tr=B/receipt.stem/'impl/pnr/sdram_test.tr'
 if row['status'] not in ('pass','timing-fail') or not tr.exists():continue
 section=pc.section(tr.read_text(),'3.3.1 Setup Analysis Report','3.3.2 Hold Analysis Report');paths=[]
 for block in re.split(r'\n\s*Path\d+\s*\n',section)[1:]:
  start=re.search(r'From\s*:\s*(\S+)',block);end=re.search(r'To\s*:\s*(\S+)',block)
  if not start or not end or pc.classify(start[1],layout)[0]!='A' or pc.classify(end[1],layout)[0]!='F':continue
  a=block.split('Data Arrival Path:')[1].split('Data Required Path:')[0];nodes=re.findall(r'\s(core/\S+/\S+)\s*$',a,re.M);delay=re.search(r'Arrival Data Path Delay:.*?cell:\s*([\d.]+).*?route:\s*([\d.]+)',block,re.S)
  key=start[1]+' -> '+nodes[-1];p={'endpoint':key,'from_field':detail(start[1]),'to_field':detail(end[1]),'end_pin':nodes[-1].rsplit('/',1)[-1],
    'slack_ns':float(re.search(r'Slack\s*:\s*([-\d.]+)',block)[1]),'levels':int(re.search(r'Logic Level:\s*(\d+)',block)[1]),'cell_ns':float(delay[1]),'route_ns':float(delay[2])};paths.append(p)
 endpoints={}
 for p in paths:
  if p['endpoint'] not in endpoints or p['slack_ns']<endpoints[p['endpoint']]['slack_ns']:endpoints[p['endpoint']]=p
 valid=[p for p in paths if p['from_field']=='A.valid']
 runs[receipt.stem]={'paths':len(paths),'worst':min(paths,key=lambda p:p['slack_ns']) if paths else None,'median_route_ns':statistics.median(p['route_ns'] for p in paths) if paths else None,
 'valid_paths':len(valid),'valid_worst':min(valid,key=lambda p:p['slack_ns']) if valid else None,'endpoints':endpoints}
paired=[]
for n in range(5):
 a=runs.get(f'baseline-p{n}');b=runs.get(f'candidate-p{n}')
 if not a or not b:continue
 keys=a['endpoints'].keys()&b['endpoints'].keys();deltas=[{'endpoint':k,'route_delta_ns':b['endpoints'][k]['route_ns']-a['endpoints'][k]['route_ns'],'slack_delta_ns':b['endpoints'][k]['slack_ns']-a['endpoints'][k]['slack_ns']} for k in sorted(keys)]
 paired.append({'placement':n,'matched_endpoints':len(keys),'median_matched_route_delta_ns':statistics.median(x['route_delta_ns'] for x in deltas) if deltas else None,'median_matched_slack_delta_ns':statistics.median(x['slack_delta_ns'] for x in deltas) if deltas else None,'deltas':deltas})
(B/'af-paths.json').write_text(json.dumps({'runs':runs,'paired':paired},indent=2)+'\n')
print(json.dumps({'runs':{k:{f:v for f,v in r.items() if f!='endpoints'} for k,r in runs.items()},'paired':[{k:v for k,v in p.items() if k!='deltas'} for p in paired]},indent=2))
