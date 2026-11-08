from pathlib import Path
import hashlib,json,re
B=Path(__file__).resolve().parent
p=json.loads((B/'protocol.json').read_text())
def sha(f):return hashlib.sha256(f.read_bytes()).hexdigest()
for f,h in p['hashes'].items():assert sha(B/f)==h,f
assert (B/'feedback.cst').read_text()==(B/'anchors.cst').read_text()+(B/'feedback-group.cst').read_text()
assert [l.split()[0] for l in (B/'feedback-group.cst').read_text().splitlines()]==['GROUP','GRP_LOC']
region=json.loads((B/'feedback-region.json').read_text())
names=re.findall(r'"([^"]+)"',(B/'feedback-group.cst').read_text())
assert set(names)=={c['name'] for c in region['cells']} and len(names)==region['members']==37
assert len(names)==len(set(names))
assert 'exclusive' not in (B/'feedback-group.cst').read_text()
for control in p['imported_controls']:
 for f,h in control['hashes'].items():assert sha(B/f"{control['variant']}-p{control['placement']}"/f)==h
assert (B/'baseline-p0/clocks.sdc').read_text() == (B/'frozen/clocks.sdc').read_text() + ('report_timing -setup -from_clock [get_clocks {clk_core}] -to_clock [get_clocks {clk_core}] -max_paths 3000 -max_common_paths 1\nreport_high_fanout_nets -max_nets 50\nreport_route_congestion -max_grids 50\n')
rows=[]
for v in ('baseline','anchors','feedback'):
 for n in range(5):
  d=B/f'{v}-p{n}';t=(d/'build.tcl').read_text()
  for k,val in [('frequency',89),('global_freq',89),('map_option',3),('route_option',1),('route_maxfan',8),('place_option',n),('num_critical_paths',3000)]:
   assert re.search(rf'^set_option -{k} {val}$',t,re.M),(d,k)
  netlist=Path(re.search(r'add_file -type netlist "([^"]+)"',t)[1]);assert sha(netlist)==p['hashes']['frozen/impl/gwsynthesis/sdram_test.vg']
  assert sha(d/'clocks.sdc')==p['imported_controls'][0]['hashes']['clocks.sdc']
  if v=='feedback':assert (d/'pins.cst').read_text()==(B/f'anchors-p{n}'/'pins.cst').read_text()+(B/'feedback-group.cst').read_text()
  assert (B/(v+'.cst')).read_text().strip() in (d/'pins.cst').read_text()
  rows.append({'variant':v,'placement':n,'pins_sha256':sha(d/'pins.cst'),'sdc_sha256':sha(d/'clocks.sdc'),'checks':'pass'})
(B/'input-audit.json').write_text(json.dumps({'frozen_hashes_verified':p['hashes'],'isolated_additions_verified':True,'runs':rows},indent=2)+'\n')
print('Input audit passed for all 15 runs')
