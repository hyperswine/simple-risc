#!/usr/bin/env python3
"""Independent RTL references, board-transport simulation, and negative controls."""
import json
from pathlib import Path
import struct
import subprocess
from check_board import advance,step,decode_frame

HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[2]
OUT=ROOT/'output/tangnano20k/fast-probe-check'

def simulate(top,files,label,expect_failure=False):
    exe=OUT/f'{label}.sim'
    subprocess.run(['iverilog','-g2012','-s',top,'-o',str(exe),*[str(p) for p in files]],check=True)
    result=subprocess.run(['vvp',str(exe)],text=True,capture_output=True,timeout=120)
    log=result.stdout+result.stderr
    (OUT/f'{label}.log').write_text(log)
    if expect_failure:
        assert result.returncode!=0 and 'Mismatch cycle=' in log,log
    else:
        assert result.returncode==0 and 'PASS' in log,log


def main():
    OUT.mkdir(parents=True,exist_ok=True)
    generated=list((ROOT/'output/tangnano20k/fast-probe-generated').glob('FastProbe.*/*.v'))
    generated += [ROOT/'output/tangnano20k/fast-probe-extra/FastProbePipeline.topEntity/probe_bram_pipe_add.v',
                  ROOT/'output/tangnano20k/fast-probe-norst/FastProbeNoReset.topEntity/probe_bram_pipe_norst.v']
    assert len(generated)==6 and all(p.is_file() for p in generated)
    simulate('tb_probe',[HERE/'tb_probe.v',HERE/'reference.v',*generated],'rtl')
    corrupt=OUT/'reference-corrupt.v'
    source=(HERE/'reference.v').read_text()
    assert source.count('q[31]^q[21]^q[1]^q[0]')==1
    corrupt.write_text(source.replace('q[31]^q[21]^q[1]^q[0]','q[31]^q[21]^q[1]^~q[0]'))
    simulate('tb_probe',[HERE/'tb_probe.v',corrupt,*generated],'negative-rtl',True)
    for freq in (216,607.5):
        build=OUT/f'board-{freq}'
        subprocess.run(['python3',str(HERE/'run_sweep.py'),'--board','--prepare-only','--variants','lfsr',
                        '--freq',str(freq),'--out',str(build)],check=True)
        simulate('tb_board',[HERE/'tb_board.v',build/'lfsr/p0/top.v',
                 ROOT/'output/tangnano20k/fast-probe-generated/FastProbe.lfsrTop/probe_lfsr.v'],f'board-{freq}')
    x=1
    for n in range(10000):
        if n in (0,1,2,31,32,512,4096,9999): assert advance(n)==x
        x=step(x)
    for frequency in (216,607.5,621):
        half=frequency!=int(frequency)
        encoded=int(frequency*2) if half else int(frequency)
        frame=(b'FPH2' if half else b'FPH1')+struct.pack('<HHII',encoded,0,65536,advance(int(65536*frequency/27)))
        checksum=0
        for b in frame: checksum ^= b
        frame+=bytes([checksum])
        assert decode_frame(frame,frequency)['passes']
        bad=bytearray(frame);bad[12]^=4;bad[-1]^=4
        assert not decode_frame(bytes(bad),frequency)['passes']
        bad[-1]^=1
        try: decode_frame(bytes(bad),frequency)
        except ValueError: pass
        else: raise AssertionError('corrupt checksum accepted')
    summary=dict(equivalence_cycles=20000,circuits=6,board_simulated_mhz=[216,607.5],
                 negative_controls=['wrong RTL feedback','wrong signature with valid checksum','wrong checksum'],passes=True)
    (OUT/'results.json').write_text(json.dumps(summary,indent=2)+'\n')
    print('PASS six Clash circuits, board UART/window simulation, signature oracle and three negative controls')

if __name__=='__main__': main()
