#!/usr/bin/env python3
"""Standalone frozen-netlist reproducer. Output directory must be new."""
import argparse, hashlib, json, os, re, subprocess, time
from pathlib import Path
p=argparse.ArgumentParser()
p.add_argument('--ide',type=Path,default=Path('/Applications/GowinIDE.app/Contents/Resources/Gowin_EDA/IDE'))
p.add_argument('--out',type=Path,required=True)
a=p.parse_args();root=Path(__file__).resolve().parent;out=a.out.resolve()
out.mkdir(parents=True,exist_ok=False)
env=dict(os.environ,DYLD_LIBRARY_PATH=str(a.ide/'lib'),DYLD_FRAMEWORK_PATH=str(a.ide/'lib'))
results={}
for variant,extra in [('default',''),('slow_only','set_operating_conditions -grade c -speed 8 -model slow -setup\nset_operating_conditions -grade c -speed 8 -model slow -hold\n')]:
 d=out/variant;d.mkdir()
 (d/'clocks.sdc').write_text((root/'clocks.sdc').read_text()+extra)
 (d/'build.tcl').write_text(f"""set_device -name GW2AR-18C GW2AR-LV18QN88C8/I7
set_option -output_base_name probe
set_option -opt_goal timing
set_option -map_option 3
set_option -route_option 1
set_option -route_maxfan 8
set_option -place_option 0
set_option -frequency 240
set_option -global_freq 240
add_file -type netlist "{root}/probe.vg"
add_file "{root}/pins.cst"
add_file "{d}/clocks.sdc"
run pnr
exit
""")
 for attempt in range(5):
  r=subprocess.run([str(a.ide/'bin/gw_sh'),'build.tcl'],cwd=d,env=env,capture_output=True,text=True,timeout=600)
  log=r.stdout+r.stderr;(d/f'tool-{attempt}.log').write_text(log)
  if r.returncode==0: break
  if 'License verification failed' not in log: raise RuntimeError(log[-2000:])
  time.sleep(5)
 if r.returncode: raise RuntimeError('license unavailable')
 t=(d/'impl/pnr/probe.tr').read_text()
 results[variant]={'pulse_slack_ns':float(re.search(r'MPW Summary:\s*Slack:\s*([-\d.]+)',t)[1]),'hashes':{ext:hashlib.sha256((d/f'impl/pnr/probe.{ext}').read_bytes()).hexdigest() for ext in ['bin','db']}}
 print(variant,results[variant],flush=True)
 (out/'results.json').write_text(json.dumps(results,indent=2)+'\n')
