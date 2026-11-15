#!/usr/bin/env python3
"""Simulate paired capture and independently check the host oracle's failures."""
from pathlib import Path
import struct, subprocess
from run_sweep import prepare, GENERATED
from check_board import decode_continuous, step
HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[2]
out=ROOT/'output/tangnano20k/continuous-check'
for frequency in (216,607.5,621):
 d=out/str(frequency)
 rtl=GENERATED/'FastProbe.lfsrTop/probe_lfsr.v'
 prepare(d,'probe_lfsr',rtl,frequency,650,0,True,True)
 exe=d/'test.vvp'
 subprocess.run(['iverilog','-g2012','-s','tb_continuous','-o',str(exe),str(HERE/'tb_continuous.v'),str(d/'top.v'),str(rtl)],check=True)
 r=subprocess.run(['vvp',str(exe)],capture_output=True,text=True,check=True)
 (d/'simulation.log').write_text(r.stdout+r.stderr)
 assert 'PASS continuous' in r.stdout
first=0x12345678;second=first
for _ in range(256):second=step(second)
def frame(first,second):
 b=b'FPC1'+struct.pack('<HHIII',621,0,256,first,second)
 checksum=0
 for byte in b:checksum^=byte
 return b+bytes([checksum])
assert decode_continuous(frame(first,second),621)['passes']
assert not decode_continuous(frame(first,second^1),621)['passes']
assert not decode_continuous(frame(0,0),621)['passes']
try:decode_continuous(frame(first,second)[:-1]+bytes([frame(first,second)[-1]^1]),621)
except ValueError:pass
else:raise AssertionError('checksum corruption accepted')
print('PASS: three simulated frequencies; corrupt state, zero lockup, checksum negative controls')
