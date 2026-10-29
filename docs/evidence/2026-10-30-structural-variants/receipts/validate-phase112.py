from pathlib import Path
import subprocess,sys,json,hashlib,importlib.util
root=Path(__file__).resolve().parents[3];out=Path(__file__).resolve().parent
image=out/"raw-60-p112/impl/pnr/sdram_test.fs";restore=root/"output/tangnano20k/btbdef-54/impl/pnr/sdram_test.fs"
loader="/Users/jasonqin/Documents/Libs/oss-cad-suite/bin/openFPGALoader"
def program(image,name):
 with (out/(name+".program.log")).open("w") as log:subprocess.run([loader,"-b","tangnano20k",str(image)],stdout=log,stderr=subprocess.STDOUT,check=True,timeout=90)
try:
 for name,order in [("phase112-zero","zero,ones,sequence"),("phase112-ones","ones,sequence,zero")]:
  program(image,name)
  with (out/(name+".log")).open("w") as log:
   subprocess.run([sys.executable,str(root/"boards/tangnano20k/sdram/diagnose_output.py"),"--uploads-only","--raw-readback","--pattern-order",order,"--freq-mhz","60","--bitstream",str(image),"--out",str(out/name)],stdout=log,stderr=subprocess.STDOUT,check=True,timeout=180)
  print(name,"all raw words passed",flush=True)
 # The last probe never executes its patterns. Replace them only through
 # the normal CRC-verified U/C/G path before running the frozen classifier.
 oracle=root/"docs/evidence/2026-10-28-controlled-benchmark/dtree-oracle.py"
 spec=importlib.util.spec_from_file_location("oracle",oracle);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
 results=[]
 for repetition in range(1,4):
  log=out/f"phase112-classifier-{repetition}.log"
  with log.open("w") as f:
   subprocess.run([sys.executable,str(root.parent/"fprisc/tools/run_tangnano20k_base.py"),str(root/"output/tangnano20k/structural-20261030/input/base.bin"),"--freq-mhz","60","--protocol","u","--timeout","45","--root",str(root/"output/tangnano20k/structural-20261030/input")],stdout=f,stderr=subprocess.STDOUT,check=True,timeout=150)
  elapsed=m.validate(log.read_text(),m.reference(128,64,8,5,2))
  results.append(dict(repetition=repetition,guest_elapsed_us=elapsed,guest_timer_mhz=72,cpu_mhz=60,corrected_us=elapsed*72/60,output_sha256=hashlib.sha256(log.read_bytes()).hexdigest()))
  print("phase112 classifier",repetition,"passed",elapsed,flush=True)
 (out/"phase112-classifier-results.json").write_text(json.dumps(dict(passed=True,runs=results,scope="Three small frozen classifier runs at 60 MHz/112.5 degrees; not I/O/PVT or large-workload qualification"),indent=2)+"\n")
finally:
 program(restore,"phase112-final-restore54")
 with (out/"phase112-final-restore54.log").open("w") as log:
  subprocess.run([sys.executable,str(root/"boards/tangnano20k/sdram/diagnose_output.py"),"--uploads-only","--freq-mhz","54","--bitstream",str(restore),"--out",str(out/"phase112-final-restore54")],stdout=log,stderr=subprocess.STDOUT,check=True,timeout=180)
 print("Restored original 54 MHz image; CRC probes pass",flush=True)
