from pathlib import Path
import hashlib,json,shutil
R=Path(__file__).resolve().parents[2];B=R/'output/btb-feedback-2026-11-08';E=R/'docs/evidence/2026-11-08-btb-feedback';E.mkdir(exist_ok=True)
def cp(p,q):
 if p.is_file():q.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(p,q)
for p in B.iterdir():
 if p.is_file() and p.suffix in ('.py','.json','.log','.cst'):cp(p,E/p.name)
for n in ('layout.json','bootrom-sdram.hex','clocks.sdc'):cp(B/'frozen'/n,E/'inputs'/n)
for receipt in B.glob('*-p[0-4].json'):
 d=B/receipt.stem
 for n in ('build.tcl','clocks.sdc','pins.cst','pnr.log'):cp(d/n,E/d.name/n)
 for p in (d/'impl/pnr').glob('*'):
  if p.suffix=='.posp' or p.name.endswith('.rpt.txt'):cp(p,E/d.name/p.name)
 p=d/'impl/pnr/sdram_test.tr'
 if p.exists():(E/d.name/'timing-sha256.txt').write_text(hashlib.sha256(p.read_bytes()).hexdigest()+'  sdram_test.tr\n')
cp(R/'boards/tangnano20k/sdram/btb_feedback_floorplan.py',E/'btb_feedback_floorplan.py')
manifest={str(p.relative_to(E)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(E.rglob('*')) if p.is_file() and p.name!='manifest-sha256.json'}
(E/'manifest-sha256.json').write_text(json.dumps(manifest,indent=2)+'\n');print('Archived',len(manifest),'files')
