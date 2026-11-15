#!/usr/bin/env python3
"""Archive the completed trials without multi-megabyte programming images."""
from pathlib import Path
import gzip,hashlib,json,shutil
ROOT=Path(__file__).resolve().parents[3]
OUT=ROOT/'output/tangnano20k/four-trials-20261110'
DEST=Path(__file__).resolve().parent
for path in sorted(OUT.rglob('*')):
 if not path.is_file():continue
 rel=path.relative_to(OUT)
 if path.suffix in ('.json','.sdc','.tcl','.cst','.log','.hs','.py') or path.name=='gowin-mpw-reproducer.zip':
  target=DEST/rel;target.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(path,target)
 elif path.suffix in ('.tr','.vg') or path.name.endswith('.rpt.txt') or path.name in ('top.v','deflate_top.v','pll.v','vector_rom.v'):
  target=DEST/(str(rel)+'.gz');target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(gzip.compress(path.read_bytes(),mtime=0))
 elif path.suffix=='.fs':
  target=DEST/(str(rel)+'.sha256');target.parent.mkdir(parents=True,exist_ok=True);target.write_text(hashlib.sha256(path.read_bytes()).hexdigest()+'\n')
 elif path.name.startswith('uart-') and path.suffix=='.bin':
  target=DEST/rel;target.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(path,target)
for folder in ['output/tangnano20k/deflate-check','output/tangnano20k/continuous-check']:
 for path in (ROOT/folder).rglob('*'):
  if path.is_file() and path.suffix in ('.json','.log'):
   target=DEST/Path(folder).name/path.relative_to(ROOT/folder);target.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(path,target)
for name in ['src/Deflate.hs','boards/tangnano20k/fast-probe/board_continuous.v','boards/tangnano20k/fast-probe/run_sweep.py','boards/tangnano20k/fast-probe/check_board.py','boards/tangnano20k/fast-probe/check_continuous.py','boards/tangnano20k/fast-probe/tb_continuous.v','boards/tangnano20k/deflate/report_deflate.py']:
 path=ROOT/name;target=DEST/'sources'/name;target.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(path,target)
rtl=ROOT/'output/tangnano20k/deflate-generated/Deflate.topEntity/deflate_inflate.v'
(DEST/'deflate-generated.v.gz').write_bytes(gzip.compress(rtl.read_bytes(),mtime=0))
(DEST/'SHA256SUMS').write_text(''.join(f'{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.relative_to(DEST)}\n' for p in sorted(DEST.rglob('*')) if p.is_file() and p.name!='SHA256SUMS'))
