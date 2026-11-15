import subprocess
from pathlib import Path
for freq in (108,135,141,144,162,216):
 out=Path('output/tangnano20k/four-trials-20261110')/f'ceiling-{freq}'
 subprocess.run(['python3','boards/tangnano20k/fast-probe/run_sweep.py','--out',str(out),'--freq',str(freq),'--target','240','--variants','lfsr'],check=True)
