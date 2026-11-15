#!/usr/bin/env python3
"""SRAM-only bounded LFSR window checks; restore and identify the original core.

Keeps one UART descriptor open across programming, respecting the BL616 bridge.
The required restore manifest/image must match the board before testing starts.
"""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import select
import struct
import subprocess
import sys
import termios
import time

HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[2]
sys.path.insert(0,str(HERE.parent))
import rom_protocol
import run_program


def step(x):
    return ((x<<1)&0xffffffff)|(((x>>31)^(x>>21)^(x>>1)^x)&1)

def transform(columns,x):
    value=0
    for bit in range(32):
        if x&(1<<bit): value ^= columns[bit]
    return value

def advance(n):
    columns=[step(1<<i) for i in range(32)]
    value=1
    while n:
        if n&1: value=transform(columns,value)
        columns=[transform(columns,c) for c in columns]
        n>>=1
    return value

def decode_frame(frame,frequency):
    if len(frame)!=17 or frame[:4] not in (b'FPH1',b'FPH2'): raise ValueError('bad frame magic/length')
    checksum=0
    for b in frame: checksum ^= b
    if checksum: raise ValueError('bad frame checksum')
    freq,index,cycles,state=struct.unpack('<HHII',frame[4:16])
    if frame[:4]==b'FPH2': freq=freq/2
    if freq!=frequency or cycles!=65536+index*256: raise ValueError('wrong frequency/window metadata')
    if cycles*freq%27: raise ValueError('noninteger test window')
    steps=int(cycles*freq/27)
    candidates={advance(steps+offset):offset for offset in (-1,0,1)}
    return dict(index=index,cycles=cycles,steps=steps,state=f'{state:08x}',
                passes=state in candidates,boundary_offset=candidates.get(state))

def baud(fd,value):
    fcntl.ioctl(fd,0x80085402,struct.pack('L',value))
    termios.tcflush(fd,termios.TCIOFLUSH)

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('builds',nargs='+',type=Path,help='run_sweep --board roots')
    parser.add_argument('--restore',type=Path,default=ROOT/'output/tangnano20k/fprisc-84')
    parser.add_argument('--port',default='/dev/cu.usbserial-20250303171')
    parser.add_argument('--loader',default='/Users/jasonqin/Documents/Libs/oss-cad-suite/bin/openFPGALoader')
    parser.add_argument('--out',type=Path,required=True)
    args=parser.parse_args()
    args.out.mkdir(parents=True,exist_ok=True)
    manifest=json.loads((args.restore/'build-manifest.json').read_text())
    restore=args.restore/'impl/pnr/sdram_test.fs'
    digest=hashlib.sha256(restore.read_bytes()).hexdigest()
    assert digest==manifest['artifacts']['impl/pnr/sdram_test.fs'], 'restore image hash mismatch'
    cpu_mhz=manifest['rom_identity']['cpu_mhz']
    restore_baud=round(cpu_mhz*1e6/868)
    candidates=[]
    for build in args.builds:
        place=build.name[1:] if build.name in ('p0','p1','p2','p3','p4') else '0'
        build=build.parent.parent if build.name in ('p0','p1','p2','p3','p4') else build
        report=json.loads((build/'results.json').read_text())
        assert report['board'] and set(report['variants'])=={'lfsr'}
        fs=build/f'lfsr/p{place}/impl/pnr/probe.fs'
        assert fs.is_file()
        candidates.append((build,fs,report,place))
    result=dict(restore_sha256=digest,tests=[])
    fd=run_program.open_port(args.port,restore_baud)
    def save(): (args.out/'results.json').write_text(json.dumps(result,indent=2)+'\n')
    def program(fs,log):
        with log.open('w') as output:
            subprocess.run([args.loader,'-b','tangnano20k',str(fs)],stdout=output,stderr=subprocess.STDOUT,check=True,timeout=90)
    changed=False
    try:
        identity=rom_protocol.query_identity(fd,expected_mhz=cpu_mhz)
        assert identity.build_id==manifest['rom_identity']['build_id'], 'current board does not match restore image'
        result['original_identity']=identity.raw; save()
        for build,fs,report,place in candidates:
            frequency=report['freq_mhz']
            baud(fd,115200)
            changed=True  # restoration is attempted even after a partial/failed load
            program(fs,args.out/f'load-{frequency}-p{place}.log')
            received=bytearray(); raw=bytearray(); samples=[]; deadline=time.monotonic()+10
            while time.monotonic()<deadline and len(samples)<32:
                readable,_,_=select.select([fd],[],[],.1)
                if not readable: continue
                chunk=os.read(fd,8192)
                raw.extend(chunk); received.extend(chunk)
                while len(received)>=17:
                    if received[:4] not in (b'FPH1',b'FPH2'): raise ValueError(f'Unexpected UART bytes at {frequency} MHz: {received[:32].hex()}')
                    sample=decode_frame(bytes(received[:17]),frequency)
                    del received[:17]
                    samples.append(sample)
            (args.out/f'uart-{frequency}-p{place}.bin').write_bytes(raw)
            indices=[s['index'] for s in samples]
            complete=indices==list(range(32))
            entry=dict(frequency_mhz=frequency,placement=int(place),bitstream_sha256=hashlib.sha256(fs.read_bytes()).hexdigest(),
                       sta=report['variants']['lfsr'][place],samples=samples,
                       passes=complete and all(s['passes'] for s in samples),complete=complete)
            result['tests'].append(entry); save()
            print(f'{frequency} MHz p{place}: {len(samples)}/32 frames, {sum(s["passes"] for s in samples)} matching signatures, timing result={entry["sta"]}',flush=True)
    finally:
        try:
            if changed:
                program(restore,args.out/'restore-load.log')
                baud(fd,restore_baud)
                identity=rom_protocol.query_identity(fd,expected_mhz=cpu_mhz)
                result['restored_identity']=identity.raw
                result['restored']=identity.build_id==manifest['rom_identity']['build_id']
                save()
                if not result['restored']: raise RuntimeError('restore identity mismatch')
                print('Restored '+identity.raw,flush=True)
        finally:
            os.close(fd)
    if not all(test['passes'] for test in result['tests']): raise SystemExit(2)

if __name__=='__main__': main()
