from pathlib import Path
import subprocess,sys,json,hashlib,importlib.util
root=Path(__file__).resolve().parents[3];out=Path(__file__).resolve().parent
image=out/"btb-only/hardware-60-p112/impl/pnr/sdram_test.fs";restore=root/"output/tangnano20k/btbdef-54/impl/pnr/sdram_test.fs"
loader="/Users/jasonqin/Documents/Libs/oss-cad-suite/bin/openFPGALoader"
def program(image,name):
 with (out/(name+".program.log")).open("w") as log:subprocess.run([loader,"-b","tangnano20k",str(image)],stdout=log,stderr=subprocess.STDOUT,check=True,timeout=90)
def run(name,command,timeout=300):
 with (out/(name+".log")).open("w") as log:subprocess.run(command,stdout=log,stderr=subprocess.STDOUT,check=True,timeout=timeout)
 print(name,"passed",flush=True)
try:
 program(image,"btb60")
 run("btb60-raw",[sys.executable,str(root/"boards/tangnano20k/sdram/diagnose_output.py"),"--uploads-only","--raw-readback","--pattern-order","sequence,zero,ones","--freq-mhz","60","--bitstream",str(image),"--out",str(out/"btb60-raw")])
 run("btb60-diagnostic",[sys.executable,str(root/"boards/tangnano20k/sdram/diagnose_output.py"),"--freq-mhz","60","--bitstream",str(image),"--repeat","1","--out",str(out/"btb60-diagnostic")])
 for script in ["check_rv32i.py","check_rv32m.py","check_processor.py"]:
  run("btb60-"+script.removesuffix(".py"),[sys.executable,str(root/"boards/tangnano20k"/script),"--freq-mhz","60"])
 run("btb60-compressed",[sys.executable,str(root/"boards/tangnano20k/sdram/check_compressed_board.py"),"--freq-mhz","60"])
 oracle=root/"docs/evidence/2026-10-28-controlled-benchmark/dtree-oracle.py"
 spec=importlib.util.spec_from_file_location("oracle",oracle);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
 results=[]
 for repetition in range(1,4):
  name=f"btb60-classifier-{repetition}"
  run(name,[sys.executable,str(root.parent/"fprisc/tools/run_tangnano20k_base.py"),str(root/"output/tangnano20k/structural-20261030/input/base.bin"),"--freq-mhz","60","--protocol","u","--timeout","45","--root",str(root/"output/tangnano20k/structural-20261030/input")],180)
  log=out/(name+".log");elapsed=m.validate(log.read_text(),m.reference(128,64,8,5,2))
  results.append(dict(repetition=repetition,guest_elapsed_us=elapsed,corrected_us=elapsed*72/60,output_sha256=hashlib.sha256(log.read_bytes()).hexdigest()))
 (out/"btb60-results.json").write_text(json.dumps(dict(passed=True,bitstream_sha256=hashlib.sha256(image.read_bytes()).hexdigest(),runs=results,scope="60 MHz experimental phase-112.5 physical acceptance; original 54 MHz image restored"),indent=2)+"\n")
finally:
 program(restore,"btb60-restore54")
 run("btb60-restore54",[sys.executable,str(root/"boards/tangnano20k/sdram/diagnose_output.py"),"--uploads-only","--freq-mhz","54","--bitstream",str(restore),"--out",str(out/"btb60-restore54")])
