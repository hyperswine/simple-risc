#!/usr/bin/env python3
"""Capture reports, manifests and hashes from this dated probe experiment."""
from pathlib import Path
import gzip,hashlib,json,shutil
ROOT=Path(__file__).resolve().parents[3]
OUT=Path(__file__).resolve().parent
BUILD=ROOT/'output/tangnano20k'
static=['fast-probe-216-20261109','fast-probe-pipelined-216-20261109','fast-probe-norst-216-20261109']
board=['fast-probe-board216-20261109']+[f'fast-probe-board{f}-settled-20261109' for f in ['216','324','432','540','594','621','607p5','621-grid']]

def copy(source,destination):
    destination.parent.mkdir(parents=True,exist_ok=True)
    shutil.copyfile(source,destination)

for name in static+board:
    source=BUILD/name
    copy(source/'results.json',OUT/name/'results.json')
    for tcl in source.glob('*/p*/build.tcl'):
        p=tcl.parent; d=OUT/name/p.relative_to(source)
        for file in ['build.tcl','clocks.sdc','pins.cst','tool.log','top.v','pll.v']:
            if (p/file).exists(): copy(p/file,d/file)
        for file in p.glob('impl/pnr/probe.*'):
            if file.suffix in ('.tr','.txt'):
                (d/(file.name+'.gz')).write_bytes(gzip.compress(file.read_bytes(),mtime=0))
        if (p/'impl/gwsynthesis/probe.vg').exists():
            (d/'netlist.vg.gz').write_bytes(gzip.compress((p/'impl/gwsynthesis/probe.vg').read_bytes(),mtime=0))
        fs=p/'impl/pnr/probe.fs'
        if fs.exists(): (d/'bitstream-sha256.txt').write_text(hashlib.sha256(fs.read_bytes()).hexdigest()+'  probe.fs\n')
for name in ['first','settled','ladder','refined']:
    source=BUILD/f'fast-probe-hardware-{name}-20261109'
    for file in source.iterdir():
        if file.is_file(): copy(file,OUT/f'hardware-{name}'/file.name)
for file in (BUILD/'fast-probe-check').iterdir():
    if file.is_file() and file.suffix in ('.log','.json'): copy(file,OUT/'rtl-checks'/file.name)
for folder in ['fast-probe-generated','fast-probe-extra','fast-probe-norst']:
    for file in (BUILD/folder).glob('*/*.v'):
        target=OUT/'generated'/folder/file.relative_to(BUILD/folder)
        target.parent.mkdir(parents=True,exist_ok=True)
        target.with_suffix('.v.gz').write_bytes(gzip.compress(file.read_bytes(),mtime=0))
copy(BUILD/'fprisc-84/build-manifest.json',OUT/'restore-manifest.json')
for source,name in [('/tmp/fast-probe-original-board.log','original-identity.log'),
                    ('/tmp/fast-probe-restored-processor.log','restored-processor.log'),
                    ('/tmp/fast-probe-clash.log','clash.log'),
                    ('/tmp/fast-probe-extra-clash.log','pipeline-clash.log'),
                    ('/tmp/fast-probe-norst-clash.log','noreset-clash.log')]:
    copy(Path(source),OUT/name)
inputs=list((ROOT/'src').glob('FastProbe*.hs'))+list((ROOT/'boards/tangnano20k/fast-probe').glob('*'))
inputs=[p for p in inputs if p.is_file()]
for file in inputs: copy(file,OUT/'source'/file.relative_to(ROOT))
(OUT/'inputs-sha256.json').write_text(json.dumps({str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs},indent=2)+'\n')
(OUT/'SHA256SUMS').write_text(''.join(hashlib.sha256(p.read_bytes()).hexdigest()+'  '+str(p.relative_to(OUT))+'\n' for p in sorted(OUT.rglob('*')) if p.is_file() and p.name!='SHA256SUMS'))
print('Captured',sum(p.is_file() for p in OUT.rglob('*')),'evidence files')
