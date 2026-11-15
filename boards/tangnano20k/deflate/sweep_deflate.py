#!/usr/bin/env python3
"""Route one frozen Deflate netlist at placement options 1..4 after build p0.
Usage: sweep_deflate.py OUTPUT_ROOT (containing the build_deflate.sh p0 build).
"""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time
from report_deflate import measure


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    root=Path(sys.argv[1]).resolve()
    source=root/'p0'
    netlist=source/'impl/gwsynthesis/deflate_test.vg'
    digest=sha(netlist)
    ratio=re.search(r'create_generated_clock.*?-multiply_by (\d+) -divide_by (\d+)',(source/'clocks.sdc').read_text())
    if not ratio: raise ValueError('missing clock ratio')
    frequency=27*int(ratio[1])/int(ratio[2])
    measure(source,frequency)
    ide=Path(os.environ.get('GOWIN_IDE','/Applications/GowinIDE.app/Contents/Resources/Gowin_EDA/IDE'))
    env=dict(os.environ,DYLD_LIBRARY_PATH=str(ide/'lib'),DYLD_FRAMEWORK_PATH=str(ide/'lib'))
    settings=[line for line in (source/'build.tcl').read_text().splitlines()
              if line.startswith(('set_device','set_option'))
              and not any(k in line for k in ['-top_module','-gen_verilog_sim_netlist','-place_option'])]
    for place in range(1,5):
        out=root/f'p{place}'; out.mkdir(parents=True,exist_ok=True)
        for name in ['pins.cst','clocks.sdc']:
            shutil.copyfile(source/name,out/name)
        tcl='\n'.join(settings+[f'set_option -place_option {place}',f'add_file -type netlist "{netlist}"',
                             f'add_file "{out}/pins.cst"',f'add_file "{out}/clocks.sdc"','run pnr','exit'])+'\n'
        (out/'build.tcl').write_text(tcl)
        start=time.monotonic()
        for attempt in range(3):
            with (out/'pnr.log').open('w') as log:
                result=subprocess.run([str(ide/'bin/gw_sh'),'build.tcl'],cwd=out,env=env,stdout=log,stderr=subprocess.STDOUT,timeout=900)
            if result.returncode==0: break
            if 'License verification failed' not in (out/'pnr.log').read_text():
                raise RuntimeError(f'placement {place} failed: {out}/pnr.log')
            time.sleep(5)
        if result.returncode: raise RuntimeError(f'placement {place}: license unavailable')
        assert sha(netlist)==digest
        measure(out,frequency)
        print(f'placement {place}: route completed in {time.monotonic()-start:.1f}s',flush=True)
    (root/'netlist-sha256.txt').write_text(digest+'  p0/impl/gwsynthesis/deflate_test.vg\n')
    print('All five placements available; inspect setup AND hold in each .tr report.')

if __name__=='__main__':
    main()
