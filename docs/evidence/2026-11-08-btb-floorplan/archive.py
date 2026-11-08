from pathlib import Path
import hashlib,json,shutil
R=Path(__file__).resolve().parents[2];B=R/'output/btb-floorplan-2026-11-08';E=R/'docs/evidence/2026-11-08-btb-floorplan';E.mkdir(exist_ok=True)
def copy(p,d):
 if p.is_file():d.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(p,d)
for p in B.glob('*'):
 if p.is_file() and p.suffix in ('.py','.json','.log','.cst'):copy(p,E/p.name)
copy(R/'boards/tangnano20k/sdram/frontend_floorplan.py',E/'frontend_floorplan.py')
for name in ('layout.json','bootrom-sdram.hex','clocks.sdc'):copy(B/'frozen'/name,E/'inputs'/name)
for receipt in B.glob('*-t*-p*.json'):
 name=receipt.stem;d=B/name
 for f in ('build.tcl','pins.cst','clocks.sdc','pnr.log'):copy(d/f,E/name/f)
 for p in (d/'impl/pnr').glob('*'):
  if p.suffix=='.posp' or p.name.endswith('.rpt.txt'):copy(p,E/name/p.name)
 # Full long reports stay in output; compact census and hashes are retained.
 p=d/'impl/pnr/sdram_test.tr'
 if p.exists():(E/name/'timing-sha256.txt').write_text(hashlib.sha256(p.read_bytes()).hexdigest()+'  sdram_test.tr\n')
for p in (B/'preflight-invalid-site').glob('candidate-*/pnr.log'):copy(p,E/'preflight'/p.parent.name/'pnr.log')
manifest={str(p.relative_to(E)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(E.rglob('*')) if p.is_file() and p.name!='manifest-sha256.json'}
(E/'manifest-sha256.json').write_text(json.dumps(manifest,indent=2)+'\n')
print('Archived',len(manifest),'files')
