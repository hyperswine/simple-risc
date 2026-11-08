from pathlib import Path
import collections,json,re,sys,statistics
R=Path.cwd();B=R/'output/a-to-f-2026-11-08';sys.path.insert(0,str(R/'boards/tangnano20k/sdram'));import area_census as a,floorplan_cst as f
L={x['type']:x for x in json.loads((R/'output/btb-ablation-2026-11-08/frozen/layout.json').read_text())};A=next(x for x in L['Pipe']['fields'] if x['name']=='pA')
def nets(e):
 out=[]
 for n in a.nets(e):
  m=re.fullmatch(r'(.+)\[(\d+):(\d+)\]',n)
  out.extend([f'{m[1]}[{i}]' for i in range(min(int(m[2]),int(m[3])),max(int(m[2]),int(m[3]))+1)] if m else [n])
 return out
result={}
for v,path in [('baseline',R/'output/btb-ablation-2026-11-08/frozen/impl/gwsynthesis/sdram_test.vg'),('candidate',B/'candidate-physical/impl/gwsynthesis/sdram_test.vg')]:
 text=path.read_text();module,_=f.locate_core(text);body=re.search(r'^module '+re.escape(module)+r' \(.*?^endmodule',text,re.M|re.S)[0];loads=collections.Counter();drivers={};inputs=collections.defaultdict(list)
 for kind,name,ps in a.INSTANCE.findall(body):
  for pin,e in a.PIN.findall(ps):
   if pin in a.OUTPUT_PINS:
    for n in nets(e):drivers[n]=(kind,name.lstrip('\\'))
   elif pin not in ('CLK','CLK0','CLK1'):
    for n in nets(e):loads[n]+=1;inputs[n].append([kind,name.lstrip('\\'),pin])
 rows=[]
 for net,(kind,name) in drivers.items():
  m=re.fullmatch(r'pipeState_(\d+)_s\d+',name)
  if not m or not kind.startswith('DFF'):continue
  bit=int(m[1]);offset=bit-A['low']
  if not A['low']<=bit<=A['high']:continue
  field='valid' if bit==A['high'] else next(x['name'] for x in L['Fetched']['fields'] if x['low']<=offset<=x['high'])
  fieldbit=0 if field=='valid' else offset-next(x['low'] for x in L['Fetched']['fields'] if x['name']==field)
  rows.append({'register':name,'bit':bit,'field':field,'field_bit':fieldbit,'net':net,'input_pin_loads':loads[net],'sinks':inputs[net]})
 result[v]={'scope':'synthesized core module; direct non-clock input-pin loads; constants excluded; before PNR replication',
  'highest_core_input_loads':loads.most_common(12),'a_registers':rows,
  'a_valid_loads':sum(r['input_pin_loads'] for r in rows if r['field']=='valid'),
  'a_max_loads':max(r['input_pin_loads'] for r in rows),'a_median_loads':statistics.median(r['input_pin_loads'] for r in rows),
  'a_raw14_loads':sum(r['input_pin_loads'] for r in rows if r['field']=='fRaw' and r['field_bit']==14)}
(B/'fanout.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps({v:{k:x for k,x in r.items() if k!='a_registers'} for v,r in result.items()},indent=2))
