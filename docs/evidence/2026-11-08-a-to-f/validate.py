from pathlib import Path
import concurrent.futures,subprocess,json,hashlib,time
R=Path.cwd();B=R/'output/a-to-f-2026-11-08';generated=B/'candidate-generated/SdramPipelineObserved.topEntity';assert (generated/'sdram_pipeline_risc.v').exists()
commands={
'rtl-check':['python3','boards/tangnano20k/sdram/check_pipeline_rtl.py','--generated',str(generated),'--compressed','--simulator','verilator','--cache-line-bits','11','--cache-ways','2','--cdc-bridge','--out',str(B/'rtl-check')],
'reset-check':['python3','boards/tangnano20k/sdram/check_pipeline_reset.py','--baseline',str(R/'output/refactor-e1-2026-11-08/baseline-observed/SdramPipelineObserved.topEntity/sdram_pipeline_risc.v'),'--candidate',str(generated/'sdram_pipeline_risc.v'),'--out',str(B/'reset-check')]}
def run(item):
 name,cmd=item;start=time.time()
 with (B/(name+'.log')).open('w') as log:result=subprocess.run(cmd,cwd=R,stdout=log,stderr=subprocess.STDOUT)
 row={'name':name,'command':cmd,'returncode':result.returncode,'elapsed_seconds':time.time()-start,'log_sha256':hashlib.sha256((B/(name+'.log')).read_bytes()).hexdigest()}
 (B/(name+'-receipt.json')).write_text(json.dumps(row,indent=2)+'\n');print(name,result.returncode,flush=True);result.check_returncode();return row
with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:rows=list(pool.map(run,commands.items()))
(B/'rtl-validation.json').write_text(json.dumps({'passed':True,'checks':rows},indent=2)+'\n')
