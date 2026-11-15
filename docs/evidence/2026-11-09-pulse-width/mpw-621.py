from pathlib import Path
import sys,json,hashlib
root=Path('/Users/jasonqin/Documents/GitHub/simple-risc')
sys.path.insert(0,str(root/'boards/tangnano20k/fast-probe'))
from run_sweep import run_tool,measure
base=root/'output/tangnano20k/fast-probe-board621-settled-20261109/lfsr/p0'
out=root/'output/tangnano20k/pulse-width-20261109'
sdc=(base/'clocks.sdc').read_text()
variants={'621_slow_only':sdc+'set_operating_conditions -grade c -speed 8 -model slow -setup\nset_operating_conditions -grade c -speed 8 -model slow -hold\n'}
settings=(base/'build.tcl').read_text().split('add_file')[0]
results=json.loads((out/'results.json').read_text())
for name,constraints in variants.items():
 d=out/name;d.mkdir(parents=True,exist_ok=True)
 (d/'clocks.sdc').write_text(constraints)
 (d/'build.tcl').write_text(settings+f'add_file -type netlist "{base}/impl/gwsynthesis/probe.vg"\nadd_file "{base}/pins.cst"\nadd_file "{d}/clocks.sdc"\nrun pnr\nexit\n')
 try:
  run_tool(d,Path('/Applications/GowinIDE.app/Contents/Resources/Gowin_EDA/IDE'))
  try: results[name]=measure(d,621)
  except Exception as e: results[name]={'parse_error':str(e)}
 except Exception as e: results[name]={'error':str(e)}
 print(name,json.dumps(results[name]),flush=True)
 (out/'results.json').write_text(json.dumps(results,indent=2)+'\n')
