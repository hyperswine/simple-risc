from pathlib import Path
import hashlib,json,shutil,gzip
R=Path.cwd();B=R/'output/a-to-f-2026-11-08';E=R/'docs/evidence/2026-11-08-a-to-f';E.mkdir(exist_ok=True)
def cp(p,q):
 if p.is_file():q.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(p,q)
for p in B.iterdir():
 if p.is_file() and p.suffix in ('.py','.json','.log','.txt','.patch'):cp(p,E/p.name)
for name in ('host-test','rtl-check','reset-check'):
 for p in (B/name).iterdir():
  if p.is_file() and p.suffix in ('.hs','.log','.json','.S'):cp(p,E/name/p.name)
P=B/'candidate-physical'
for name in ('synthesis.tcl','build.tcl','pins.cst','clocks.sdc','layout.json','floorplan.cst','floorplan.log','area.json','area.txt','synthesis.log','bootrom-sdram.hex'):cp(P/name,E/'synthesis'/name)
for p in (P/'inputs').iterdir():
 if p.name!='sdram_pipeline_risc.v':cp(p,E/'synthesis/inputs'/p.name)
for p in (P/'impl/gwsynthesis').glob('*.html'):cp(p,E/'synthesis'/p.name)
for p,n in [(P/'impl/gwsynthesis/sdram_test.vg','sdram_test.vg.gz'),(P/'inputs/sdram_pipeline_risc.v','production.v.gz'),(B/'candidate-generated/SdramPipelineObserved.topEntity/sdram_pipeline_risc.v','observed.v.gz')]:
 (E/'synthesis'/n).write_bytes(gzip.compress(p.read_bytes(),mtime=0))
for receipt in B.glob('*-p[0-4].json'):
 d=B/receipt.stem
 for name in ('build.tcl','pins.cst','clocks.sdc','pnr.log'):cp(d/name,E/d.name/name)
 for p in (d/'impl/pnr').glob('*'):
  if p.suffix=='.posp' or p.name.endswith('.rpt.txt'):cp(p,E/d.name/p.name)
 tr=d/'impl/pnr/sdram_test.tr'
 if tr.exists():(E/d.name/'timing-sha256.txt').write_text(hashlib.sha256(tr.read_bytes()).hexdigest()+'  sdram_test.tr\n')
for name in ('sdram_test_syn.rpt.html','sdram_test_syn_resource.html'):cp(R/'output/refactor-2026-11-07/baseline-physical/impl/gwsynthesis'/name,E/'baseline-synthesis'/name)
m={str(p.relative_to(E)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(E.rglob('*')) if p.is_file() and p.name!='manifest-sha256.json'}
(E/'manifest-sha256.json').write_text(json.dumps(m,indent=2)+'\n');print('Archived',len(m),'files')
