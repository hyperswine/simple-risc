"""Six alternating SRAM-only runs, with mandatory known-good image restoration."""
from pathlib import Path
import hashlib
import importlib.util
import json
import statistics
import subprocess
import sys

ROOT = Path('/Users/jasonqin/Documents/GitHub/simple-risc')
OUT = ROOT/'output/tangnano20k/control-area-20261028'
GUEST = ROOT/'output/tangnano20k/benchmark-matrix-20261028'
FPR = ROOT.parent/'fprisc'
LOADER = Path('/Users/jasonqin/Documents/Libs/oss-cad-suite/bin/openFPGALoader')
RESTORE = ROOT/'output/tangnano20k/fprisc-48/impl/pnr/sdram_test.fs'
RESTORE_SHA = '30a3f82d8249fe1db0e35c51e7b3b9abb269b729e6b16b60ded71fdf57d986c3'
PORT = '/dev/cu.usbserial-20250303171'

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def command(args, log, timeout):
    with log.open('w') as stream:
        result = subprocess.run([str(arg) for arg in args], cwd=ROOT, stdout=stream,
                                stderr=subprocess.STDOUT, timeout=timeout)
    if result.returncode:
        raise RuntimeError(f'command failed: {log}')
    return log.read_text()

assert sha(RESTORE) == RESTORE_SHA
experiment = json.loads((GUEST/'experiment.json').read_text())
assert sha(GUEST/'input/base.bin') == experiment['image_sha256']
spec = importlib.util.spec_from_file_location('oracle', FPR/'tests/check_tangnano20k_dtree.py')
oracle = importlib.util.module_from_spec(spec)
spec.loader.exec_module(oracle)
assert oracle.reference(128, 64, 8, 5, 2) == experiment['reference']
report = dict(passed=False, restored=False, cpu_mhz=48, memory_mhz=48,
              guest_timer_mhz=72, image_sha256=experiment['image_sha256'],
              elapsed_correction='guest elapsed_us * 72 / 48', upload_protocol='legacy Q/V/H with readback verification', runs=[], timing={})
destination = OUT/'hardware/board-results.json'
images = {}
for name in ('mru-ram',):
    directory = OUT/name
    fs = directory/'impl/pnr/sdram_test.fs'
    timing = directory/'impl/pnr/sdram_test.tr'
    command([sys.executable, ROOT/'boards/tangnano20k/check_gowin_timing.py', timing,
             '--freq-mhz', '48'], directory/'timing-gate.log', 30)
    images[name] = fs
    report['timing'][name] = dict(bitstream_sha256=sha(fs), timing_sha256=sha(timing),
                                timing_gate=(directory/'timing-gate.log').read_text())
destination.write_text(json.dumps(report, indent=2)+'\n')
attempted_programming = False
try:
    for repeat in range(1, 4):
        for name in ('mru-ram',):
            prefix = OUT/f'hardware/{name}-{repeat}'
            print(f'{name} repeat {repeat}: programming SRAM and uploading frozen image', flush=True)
            attempted_programming = True
            command([LOADER, '-b', 'tangnano20k', images[name]], prefix.with_suffix('.program.log'), 60)
            output = command([sys.executable, FPR/'tools/run_tangnano20k_base.py', GUEST/'input/base.bin',
                              '--root', GUEST/'input', '--port', PORT, '--freq-mhz', '48', '--protocol', 'q', '--timeout', '90'],
                             prefix.with_suffix('.uart.log'), 180)
            elapsed = oracle.validate(output, experiment['reference'])
            assert output.splitlines().count('FPR EXIT 0') == 1 and output.splitlines().count('DONE') == 1
            report['runs'].append(dict(configuration=name, repeat=repeat, guest_elapsed_us=elapsed,
                                       corrected_elapsed_us=elapsed*72/48,
                                       log_sha256=sha(prefix.with_suffix('.uart.log'))))
            destination.write_text(json.dumps(report, indent=2)+'\n')
            print(f'{name} repeat {repeat}: PASS corrected elapsed {elapsed*72/48:.1f} us', flush=True)
    report['medians_us'] = {name: statistics.median(run['corrected_elapsed_us'] for run in report['runs']
                            if run['configuration'] == name) for name in images}
    report['previous_combined_median_us'] = 2805255.0
    report['passed'] = True
except BaseException as error:
    report['error'] = str(error)
    raise
finally:
    if attempted_programming:
        try:
            command([LOADER, '-b', 'tangnano20k', RESTORE], OUT/'hardware/restore.program.log', 60)
            command([sys.executable, FPR/'tools/run_tangnano20k_base.py', '--probe', '--port', PORT,
                     '--freq-mhz', '48'], OUT/'hardware/restore.probe.log', 20)
            report['restored'] = True
            report['restore_sha256'] = sha(RESTORE)
        except BaseException as error:
            report['passed'] = False
            report['restore_error'] = str(error)
    destination.write_text(json.dumps(report, indent=2)+'\n')
print(json.dumps(report, indent=2), flush=True)
if not report['passed'] or not report['restored']:
    raise SystemExit(1)
