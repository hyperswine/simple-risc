from pathlib import Path
import subprocess, sys
root = Path(__file__).resolve().parents[3]
out = Path(__file__).resolve().parent
loader = "/Users/jasonqin/Documents/Libs/oss-cad-suite/bin/openFPGALoader"
original = root / "output/tangnano20k/btbdef-54/impl/pnr/sdram_test.fs"
cases = [(54, original, "final-upload-54"),
         (60, root / "output/tangnano20k/btbdef-60-rvc/impl/pnr/sdram_test.fs", "final-upload-old60"),
         (60, out / "ordinary-60/impl/pnr/sdram_test.fs", "final-upload-new60")]
def program(image, name):
    with (out / (name + ".program.log")).open("w") as log:
        subprocess.run([loader, "-b", "tangnano20k", str(image)], stdout=log, stderr=subprocess.STDOUT, check=True, timeout=90)
def probe(freq, image, name):
    with (out / (name + ".log")).open("w") as log:
        p = subprocess.run([sys.executable, str(root / "boards/tangnano20k/sdram/diagnose_output.py"),
                            "--freq-mhz", str(freq), "--bitstream", str(image), "--uploads-only",
                            "--out", str(out / name)], stdout=log, stderr=subprocess.STDOUT, timeout=180)
    print(name, "exit", p.returncode, flush=True)
try:
    for freq, image, name in cases:
        program(image, name)
        probe(freq, image, name)
finally:
    program(original, "final-upload-restore54")
    probe(54, original, "final-upload-restore54")
