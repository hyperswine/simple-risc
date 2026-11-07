from pathlib import Path
import shutil,hashlib,difflib,json,subprocess
r=Path.cwd();b=r/'output/refactor-four-2026-11-08';e=r/'docs/evidence/2026-11-08-four-trials';e.mkdir(parents=True,exist_ok=True)
def cp(s,d):
 if s.is_file():
  d.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(s,d)
for p in b.glob('*.py'):cp(p,e/'scripts'/p.name)
cp(b/'wider.plan',e/'scripts/wider.plan')
for p in b.glob('*.log'):cp(p,e/'logs'/p.name)
for name in ('fanout.json','fanout.txt','summary.json'):cp(b/name,e/name)
for p in b.glob('*-results.json'):cp(p,e/p.name)
# Complete patches relative to committed baseline, including the retained helper.
for v in ('all-reset','dsp','division'):
 patch=[]
 for p in sorted((b/(v+'-source')/'src').rglob('*.hs')):
  rel=p.relative_to(b/(v+'-source'));old=subprocess.run(['git','show','dcd220d:'+str(rel)],capture_output=True,text=True)
  if old.stdout!=p.read_text():patch.extend(difflib.unified_diff(old.stdout.splitlines(True),p.read_text().splitlines(True),fromfile='a/'+str(rel) if old.returncode==0 else '/dev/null',tofile='b/'+str(rel)))
 (e/(v+'.patch')).write_text(''.join(patch))
 physical=b/(v+'-physical')
 for name in ('area.json','area.txt','layout.json','experiment.json','synthesis.log','pins.cst','clocks.sdc','floorplan.cst','build.tcl'):
  cp(physical/name,e/v/'synthesis'/name)
 for p in (physical/'impl/gwsynthesis').glob('*.html'):cp(p,e/v/'synthesis'/p.name)
 for kind in ('rtl-check','reset-csr-check'):
  for p in (b/(v+'-'+kind)).glob('*'):
   if p.suffix in ('.json','.log','.S'):cp(p,e/v/kind/p.name)
 for d in b.glob(v+'-*-p[03]'):
  for name in ('pnr.log','build.tcl','pins.cst','clocks.sdc'):cp(d/name,e/v/d.name/name)
  for p in (d/'impl/pnr').glob('*'):
   if p.suffix in ('.tr','.posp') or p.name.endswith('.rpt.txt'):cp(p,e/v/d.name/p.name)
for p in (b/'dsp').glob('*'):
 if p.suffix in ('.v','.log'):cp(p,e/'dsp/model-test'/p.name)
cp(b/'division-source/ServiceCheck.hs',e/'division/ServiceCheck.hs')
for name in ('pipeline_reset_tb.v','check_pipeline_reset.py'):cp(r/'boards/tangnano20k/sdram'/name,e/'tests'/name)
inputs={}
for v in ('all-reset','dsp','division'):
 for p in (b/(v+'-generated')).rglob('*.v'):inputs[str(p.relative_to(r))]=hashlib.sha256(p.read_bytes()).hexdigest()
 for p in (b/(v+'-physical')/'impl/gwsynthesis').glob('*.vg'):inputs[str(p.relative_to(r))]=hashlib.sha256(p.read_bytes()).hexdigest()
model=Path('/Applications/GowinIDE.app/Contents/Resources/Gowin_EDA/IDE/simlib/gw2a/prim_sim.v');inputs[str(model)]=hashlib.sha256(model.read_bytes()).hexdigest()
(e/'input-sha256.json').write_text(json.dumps(inputs,indent=2)+'\n')
print('Archived',sum(p.is_file() for p in e.rglob('*')),'files')
