from pathlib import Path
import hashlib,json,re
B=Path(__file__).resolve().parent
p=json.loads((B/'protocol.json').read_text())
def sha(f): return hashlib.sha256(f.read_bytes()).hexdigest()
for f,h in p['hashes'].items(): assert sha(B/f)==h,f
base=(B/'baseline.cst').read_text()
for v,types in [('anchors',['INS_LOC','INS_LOC']),('grouping',['GROUP','GRP_LOC'])]:
 t=(B/(v+'.cst')).read_text();assert t.startswith(base)
 lines=[l for l in t[len(base):].splitlines() if l.strip() and not l.lstrip().startswith('//')]
 assert [l.split()[0] for l in lines]==types,lines
rows=[]
for v in ('baseline','anchors','grouping'):
 for n in range(5):
  d=B/f'{v}-p{n}';t=(d/'build.tcl').read_text()
  for k,val in [('frequency',89),('global_freq',89),('map_option',3),('route_option',1),('route_maxfan',8),('place_option',n),('num_critical_paths',3000)]:
   assert re.search(rf'^set_option -{k} {val}$',t,re.M),(d,k)
  assert sha(d/'clocks.sdc')==p['imported_controls'][0]['sdc_sha256']
  assert (B/(v+'.cst')).read_text().strip() in (d/'pins.cst').read_text()
  if v=='baseline':
   c=p['imported_controls'][n]
   for f,key in [('pins.cst','pins_sha256'),('pnr.log','pnr_log_sha256'),('impl/pnr/sdram_test.tr','timing_sha256')]:
    if c[key]:assert sha(d/f)==c[key],(d,f)
  rows.append({'variant':v,'placement':n,'pins_sha256':sha(d/'pins.cst'),'sdc_sha256':sha(d/'clocks.sdc'),'checks':'pass'})
(B/'input-audit.json').write_text(json.dumps({'frozen_hashes_verified':p['hashes'],'isolated_additions_verified':True,'runs':rows},indent=2)+'\n')
print('Input audit passed for all 15 runs')
