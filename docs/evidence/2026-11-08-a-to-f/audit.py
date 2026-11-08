from pathlib import Path
import hashlib,json,re,subprocess,tempfile
R=Path.cwd();B=R/'output/a-to-f-2026-11-08';P=B/'candidate-physical';j=json.loads((B/'protocol.json').read_text())
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
for f,h in j['candidate_hashes'].items():assert sha(B/f)==h,f
for c in j['imported_controls']:
 for f,h in c['hashes'].items():assert sha(B/f"baseline-p{c['placement']}"/f)==h
sources=json.loads((B/'source-manifest.json').read_text())['source_hashes']
for f,h in sources.items():assert sha(B/'candidate-source'/f)==h,f
inputs=json.loads((B/'synthesis-inputs.json').read_text())
for x in inputs['inputs']:
 p=Path(x['copy'])
 if p.name!='pins.cst':assert sha(p)==x['sha256']
 if x['role']=='unchanged wrapper or peripheral RTL':assert sha(Path(x['source']))==sha(p)
assert sha(P/'bootrom-sdram.hex')==inputs['rom_sha256']==sha(R/'output/btb-ablation-2026-11-08/frozen/bootrom-sdram.hex')
assert sha(P/'layout.json')==sha(R/'output/btb-ablation-2026-11-08/frozen/layout.json')
layout={x['type']:x for x in json.loads((P/'layout.json').read_text())}
rtl=(P/'inputs/sdram_pipeline_risc.v').read_text();assert int(re.search(r'reg \[(\d+):0\] pipeState',rtl)[1])+1==layout['Pipe']['bits']
with tempfile.TemporaryDirectory(dir=B) as d:
 out=Path(d)/'floorplan.cst';subprocess.run(['python3','boards/tangnano20k/sdram/floorplan_cst.py','boards/tangnano20k/sdram/fprisc-81.plan',str(P/'impl/gwsynthesis/sdram_test.vg'),'--layout',str(P/'layout.json'),'-o',str(out)],check=True)
 assert out.read_bytes()==(P/'floorplan.cst').read_bytes()
def pin_commands(p):return [l.strip() for l in p.read_text().splitlines() if l.strip() and not l.lstrip().startswith(('//','GROUP ','GRP_LOC '))]
assert pin_commands(P/'pins.cst')==pin_commands(B/'baseline-p0/pins.cst')
assert re.findall(r'^GRP_LOC .*$',(P/'pins.cst').read_text(),re.M)==re.findall(r'^GRP_LOC .*$',(B/'baseline-p0/pins.cst').read_text(),re.M)
rows=[]
for v in ('baseline','candidate'):
 for n in range(5):
  d=B/f'{v}-p{n}';t=(d/'build.tcl').read_text()
  for k,val in [('frequency',89),('global_freq',89),('map_option',3),('route_option',1),('route_maxfan',8),('place_option',n),('num_critical_paths',3000)]:assert re.search(rf'^set_option -{k} {val}$',t,re.M),(v,n,k)
  netlist=Path(re.search(r'add_file -type netlist "([^"]+)"',t)[1]);expected=P/'impl/gwsynthesis/sdram_test.vg' if v=='candidate' else R/'output/btb-ablation-2026-11-08/frozen/impl/gwsynthesis/sdram_test.vg';assert sha(netlist)==sha(expected)
  assert sha(d/'clocks.sdc')==sha(B/'baseline-p0/clocks.sdc')
  if v=='candidate':assert sha(d/'pins.cst')==sha(P/'pins.cst')
  rows.append({'variant':v,'placement':n,'netlist_sha256':sha(netlist),'pins_sha256':sha(d/'pins.cst'),'sdc_sha256':sha(d/'clocks.sdc'),'checks':'pass'})
for f in ('host-receipt.json','rtl-validation.json','reset-check/results.json','rtl-check/results.json'):assert json.loads((B/f).read_text())['passed']
(B/'input-audit.json').write_text(json.dumps({'functional_gates_verified':True,'candidate_sources_verified':True,'same_pin_commands_and_region_policy':True,'same_rom_and_clocks':True,'layout_width_verified':True,'runs':rows},indent=2)+'\n');print('Audit passed: all ten comparisons and functional gates')
