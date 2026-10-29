from pathlib import Path
import subprocess,sys
root=Path(__file__).resolve().parents[3];out=Path(__file__).resolve().parent
freq=int(sys.argv[1]); image=out/(sys.argv[3] if len(sys.argv)>3 else f"raw-{freq}")/"impl/pnr/sdram_test.fs"
order=sys.argv[2] if len(sys.argv)>2 else "zero,ones,sequence"
label=(sys.argv[3] if len(sys.argv)>3 else f"raw-{freq}")+("-order-"+order.split(",")[0] if len(sys.argv)>2 else "")
restore=root/"output/tangnano20k/btbdef-54/impl/pnr/sdram_test.fs"
loader="/Users/jasonqin/Documents/Libs/oss-cad-suite/bin/openFPGALoader"
def program(path,name):
 with (out/name).open("w") as log:subprocess.run([loader,"-b","tangnano20k",str(path)],stdout=log,stderr=subprocess.STDOUT,check=True,timeout=90)
try:
 program(image,f"{label}-program.log")
 with (out/f"{label}-probe.log").open("w") as log:
  result=subprocess.run([sys.executable,str(root/"boards/tangnano20k/sdram/diagnose_output.py"),"--uploads-only","--raw-readback","--pattern-order",order,"--freq-mhz",str(freq),"--bitstream",str(image),"--out",str(out/f"{label}-probe")],stdout=log,stderr=subprocess.STDOUT,timeout=240)
 print("raw readback",freq,"exit",result.returncode,flush=True)
finally:
 program(restore,f"{label}-restore54-program.log")
 with (out/f"{label}-restore54.log").open("w") as log:
  subprocess.run([sys.executable,str(root/"boards/tangnano20k/sdram/diagnose_output.py"),"--uploads-only","--freq-mhz","54","--bitstream",str(restore),"--out",str(out/f"{label}-restore54")],stdout=log,stderr=subprocess.STDOUT,check=True,timeout=180)
 print("Restored original 54 MHz image and verified all CRC probes",flush=True)
