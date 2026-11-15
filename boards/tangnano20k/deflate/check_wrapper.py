#!/usr/bin/env python3
"""Verify the prepared FPGA wrapper/ROM, including reset with live RAM data."""
import argparse
from pathlib import Path
import subprocess

HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[2]

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('build',type=Path,help='build_deflate.sh output for DEFLATE_VECTOR=big')
    args=parser.parse_args()
    out=args.build.resolve()
    executable=out/'tb_wrapper'
    rtl=ROOT/'output/tangnano20k/deflate-generated/Deflate.topEntity/deflate_inflate.v'
    subprocess.run(['iverilog','-g2012','-s','tb_deflate_fpga','-o',str(executable),str(HERE/'tb_deflate_fpga.v'),
                    str(out/'deflate_top.v'),str(out/'vector_rom.v'),str(rtl)],check=True)
    result=subprocess.run(['vvp',str(executable),f'+EXPECTED={HERE}/vectors/big.expected.hex'],capture_output=True,text=True,timeout=120)
    log=result.stdout+result.stderr
    (out/'wrapper-check.log').write_text(log)
    if result.returncode or 'PASS wrapper' not in log: raise RuntimeError(log)
    print(log,end='')

if __name__=='__main__':
    main()
