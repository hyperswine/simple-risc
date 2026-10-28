"""Bounded CRC header probe, with no guest execution and mandatory restoration."""
from pathlib import Path
import hashlib
import json
import os
import subprocess
import sys
import time

ROOT = Path('/Users/jasonqin/Documents/GitHub/simple-risc')
OUT = ROOT/'output/tangnano20k/benchmark-matrix-20261028/hardware'
FPR = ROOT.parent/'fprisc'
sys.path[:0] = [str(FPR/'tools'), str(ROOT/'boards/tangnano20k')]
from run_simple_risc import open_port
import rom_protocol

LOADER = '/Users/jasonqin/Documents/Libs/oss-cad-suite/bin/openFPGALoader'
RESTORE = ROOT/'output/tangnano20k/fprisc-48/impl/pnr/sdram_test.fs'
assert hashlib.sha256(RESTORE.read_bytes()).hexdigest() == '30a3f82d8249fe1db0e35c51e7b3b9abb269b729e6b16b60ded71fdf57d986c3'
report = dict(complete=False, restored=False, image_hex='13000000', cases=[])
destination = OUT/'upload-probe.json'

def program(image, log):
    with (OUT/log).open('w') as stream:
        subprocess.run([LOADER, '-b', 'tangnano20k', str(image)], stdout=stream,
                       stderr=subprocess.STDOUT, check=True, timeout=60)

try:
    for name in ('baseline', 'combined'):
        for pacing in (0, .003):
            label = f'{name}-upload-{int(pacing*1000)}ms'
            program(OUT/name/'impl/pnr/sdram_test.fs', label+'.program.log')
            fd = open_port('/dev/cu.usbserial-20250303171', round(48e6/868))
            try:
                transport = rom_protocol.FdTransport(fd)
                identity = rom_protocol.query_identity(transport, expected_mhz=48)
                frame, _, crc = rom_protocol.frame_u(bytes.fromhex(report['image_hex']))
                if pacing:
                    for byte in frame:
                        transport.write(bytes([byte])); time.sleep(pacing)
                else:
                    transport.write(frame)
                reply = transport.read_until(lambda b: b'\n' in b, 4)
                accepted = reply.strip() == f'OK {crc:08x}'.encode()
                readback = None
                if accepted:
                    transport.write(b'C')
                    readback = transport.read_until(lambda b: b'\n' in b, 4).decode('ascii', 'replace')
                    assert readback.strip() == f'{crc:08x}'
                report['cases'].append(dict(configuration=name, pacing_ms=pacing*1000,
                    identity=identity.raw, reply=reply.decode('ascii', 'replace'),
                    accepted=accepted, readback=readback))
                destination.write_text(json.dumps(report, indent=2)+'\n')
                print(json.dumps(report['cases'][-1]), flush=True)
            finally:
                os.close(fd)
    report['complete'] = True
finally:
    program(RESTORE, 'upload-probe-restore.program.log')
    with (OUT/'upload-probe-restore.probe.log').open('w') as stream:
        subprocess.run([sys.executable, str(FPR/'tools/run_tangnano20k_base.py'), '--probe',
            '--freq-mhz', '48', '--port', '/dev/cu.usbserial-20250303171'],
            stdout=stream, stderr=subprocess.STDOUT, check=True, timeout=20)
    report['restored'] = True
    destination.write_text(json.dumps(report, indent=2)+'\n')
