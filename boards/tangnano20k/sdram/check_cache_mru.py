#!/usr/bin/env python3
"""Compare RAM-backed replacement decisions with the former register-vector policy."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
MONITOR = r'''
 reg [(1<<LINE_BITS)-1:0] reference_mru;
 integer mru_checks=0,mru_collisions=0;
 always @(posedge clk)begin
   if(reset)reference_mru<=0;
   else begin
     if(cache.advance && cache.v1 && !cache.a1[21] && !cache.same_fill_set &&
        cache.entry_tag[19-LINE_BITS] && cache.entry_tag_way1[19-LINE_BITS])begin
       mru_checks=mru_checks+1;
       if(cache.victim_way1 !== ~reference_mru[cache.a1[LINE_BITS+1:2]])
         $fatal(1,"MRU replacement differs from register-vector reference");
     end
     if(cache.advance && cache.mru_write && !cache.clearing &&
        cache.mru_index==cache.cpu_address[LINE_BITS+1:2])mru_collisions=mru_collisions+1;
     if(cache.advance && cache.v2 && cache.hit2 && !cache.a2[21])
       reference_mru[cache.a2[LINE_BITS+1:2]]<=cache.way2;
     if(cache.tag_fill)reference_mru[cache.a2[LINE_BITS+1:2]]<=cache.way2;
   end
 end
'''
TRACE = r'''
   // Three tags in one set: hits change MRU before the third tag evicts.
   // Repeated same-line hits also force lookup/write collisions.
   for(i=0;i<8;i=i+1)begin
     add(384,0,0,15);add(384+(1<<(LINE_BITS+2)),0,0,15);
     add(384,0,0,15);add(384,0,0,15);add(384,0,0,15);
     add(384+(2<<(LINE_BITS+2)),0,0,15);
     add(384+(1<<(LINE_BITS+2)),0,0,15);
   end
'''


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--out', type=Path, default=ROOT/'output/tangnano20k/cache-mru-regression')
    args = p.parse_args()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    source = (HERE/'pipeline_cache.v').read_text()
    fixture = (HERE/'pipeline_cache_tb.v').read_text()
    fixture = fixture.replace(' integer delay=0,', MONITOR+'\n integer delay=0,')
    fixture = fixture.replace('   repeat(4)@(negedge clk);reset=0;', TRACE+'\n   repeat(4)@(negedge clk);reset=0;')
    fixture = fixture.replace('       $display("PASS: %0d reads,', '''
       if(mru_checks==0 || mru_collisions==0)$fatal(1,"MRU coverage missing");
       $display("PASS: %0d MRU decisions, %0d lookup/write collisions",mru_checks,mru_collisions);
       $display("PASS: %0d reads,''')
    bypass = '(mru_write && mru_index==cpu_address[LINE_BITS+1:2]) ?\n     mru_value:mru[cpu_address[LINE_BITS+1:2]]'
    assert source.count(bypass) == 1, 'review the current MRU collision bypass'
    # Poison only the RAM output on collisions. Explicit write-through must
    # make the underlying memory's read-during-write result unobservable.
    poison = "((mru_write && mru_index==cpu_address[LINE_BITS+1:2]) ? 1'bx:mru[cpu_address[LINE_BITS+1:2]])"
    poisoned = source.replace('mru_value:mru[cpu_address[LINE_BITS+1:2]]', 'mru_value:'+poison)
    missing = source.replace(bypass, poison)
    report = dict(complete=False, source_sha256=hashlib.sha256(source.encode()).hexdigest(), cases=[])
    destination = out/'results.json'
    destination.write_text(json.dumps(report, indent=2)+'\n')
    for name, rtl, bits, policy, refusal in [
        ('small-update', source, 7, 1, False),
        ('full-update', source, 11, 1, False),
        ('full-invalidate', source, 11, 0, False),
        ('poisoned-read', poisoned, 11, 1, False),
        ('missing-bypass', missing, 11, 1, True),
    ]:
        rtl_path, tb_path, binary = out/(name+'.v'), out/(name+'-tb.v'), out/(name+'-sim')
        rtl = rtl.replace('parameter WRITE_UPDATE=1,', f'parameter WRITE_UPDATE={policy},')
        rtl_path.write_text(rtl)
        tb_path.write_text(fixture)
        subprocess.run(['iverilog', '-g2012', '-s', 'pipeline_cache_tb',
            '-Ppipeline_cache_tb.WAYS=2', f'-Ppipeline_cache_tb.LINE_BITS={bits}',
            '-o', str(binary), str(rtl_path), str(tb_path)], cwd=ROOT, check=True,
            capture_output=True, timeout=60)
        run = subprocess.run(['vvp', str(binary)], cwd=ROOT, capture_output=True, text=True, timeout=120)
        output = run.stdout+run.stderr
        (out/(name+'.log')).write_text(output)
        if refusal:
            assert run.returncode and 'MRU replacement differs from register-vector reference' in output, output
        else:
            assert run.returncode == 0 and 'lookup/write collisions' in output and 'ordered masked writes' in output, output
        report['cases'].append(dict(name=name, passed=True, expected_refusal=refusal, output=output))
        destination.write_text(json.dumps(report, indent=2)+'\n')
        print(f'{name}: PASS', flush=True)
    report['complete'] = True
    destination.write_text(json.dumps(report, indent=2)+'\n')


if __name__ == '__main__':
    main()
