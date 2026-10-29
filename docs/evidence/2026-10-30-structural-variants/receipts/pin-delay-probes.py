from pathlib import Path
import subprocess,sys,json
root=Path(__file__).resolve().parents[3];out=Path(__file__).resolve().parent
common=[sys.executable,str(root/"boards/tangnano20k/sdram/check_pipeline_rtl.py"),"--generated",str(root/"output/tangnano20k/structural-20261030/observed/generated/SdramPipelineObserved.topEntity"),"--compressed","--cache-ways","2","--cache-line-bits","7","--boot-loader","--loader-command","U","--upload-pattern","sequence","--upload-words","16","--raw-readback","--rom-file",str(out/"readback-rom/readback.hex"),"--pin-model","--pin-freq-mhz","60","--pin-tac-ns","11","--simulator","verilator"]
results=[]
for phase,expected in [(135,False),(112.5,True)]:
 name=f"pins60-exact-p{phase}-tac11";log=out/(name+".log")
 with log.open("w") as f:
  p=subprocess.run([*common,"--pin-phase-degrees",str(phase),"--out",str(out/name)],stdout=f,stderr=subprocess.STDOUT,timeout=300)
 text=log.read_text()
 passed=p.returncode==0 if expected else p.returncode!=0 and "SDRAM capture word" in text
 results.append(dict(phase_degrees=phase,read_access_ns=11,expected_success=expected,exit=p.returncode,matched_expectation=passed))
 print(results[-1],flush=True)
 assert passed,text[-3000:]
(out/"pin-delay-exact-results.json").write_text(json.dumps(results,indent=2)+"\n")
