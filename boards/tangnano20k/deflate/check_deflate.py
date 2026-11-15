#!/usr/bin/env python3
"""Check generated decoder RTL against the shared zlib-oracle corpus."""
import argparse
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--rtl', type=Path, default=ROOT/'output/tangnano20k/deflate-generated/Deflate.topEntity/deflate_inflate.v')
    parser.add_argument('--out', type=Path, default=ROOT/'output/tangnano20k/deflate-check')
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    exe = args.out/'tb_deflate'
    subprocess.run(['iverilog','-g2012','-s','tb_deflate','-o',str(exe),str(HERE/'tb_deflate.v'),str(args.rtl)],check=True)
    manifest=json.loads((HERE/'vectors/vectors.json').read_text())
    results=[]
    for name, case in manifest.items():
        for i,o in [(0,0),(1,0),(0,3),(7,11)]:
            command=['vvp',str(exe),f'+VECTOR={HERE}/vectors/{name}',
                     f'+INPUT_LEN={case["deflate_bytes"]}',f'+OUTPUT_LEN={case["expected_bytes"]}',
                     f'+REJECT={int(case["must_reject"])}',f'+INPUT_SEED={i}',f'+OUTPUT_SEED={o}']
            run=subprocess.run(command,text=True,capture_output=True,timeout=120)
            log=run.stdout+run.stderr
            (args.out/f'{name}-i{i}-o{o}.log').write_text(log)
            if run.returncode or 'PASS ' not in log or 'FAIL' in log:
                raise RuntimeError(log)
            results.append(dict(name=name,input_seed=i,output_seed=o,result='pass'))
    # Negative control: the checker must fail a corrupted expected byte.
    name='hello'
    negative=args.out/'negative'
    negative.with_suffix('.deflate.hex').write_text((HERE/f'vectors/{name}.deflate.hex').read_text())
    expected=(HERE/f'vectors/{name}.expected.hex').read_text().splitlines()
    expected[0]=f'{int(expected[0],16)^1:02x}'
    negative.with_suffix('.expected.hex').write_text('\n'.join(expected)+'\n')
    case=manifest[name]
    run=subprocess.run(['vvp',str(exe),f'+VECTOR={negative}',f'+INPUT_LEN={case["deflate_bytes"]}',
                        f'+OUTPUT_LEN={case["expected_bytes"]}','+REJECT=0','+INPUT_SEED=0','+OUTPUT_SEED=0'],text=True,capture_output=True)
    assert run.returncode != 0 and 'byte 0' in run.stdout, run.stdout
    (args.out/'negative-control.log').write_text(run.stdout+run.stderr)
    (args.out/'results.json').write_text(json.dumps(dict(cases=results,negative_control='rejected'),indent=2)+'\n')
    print(f'PASS {len(results)} RTL cases; corrupted-output negative control rejected')

if __name__=='__main__':
    main()
