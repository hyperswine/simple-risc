#!/usr/bin/env python3
"""Copy compact, source-bound evidence out of ignored build directories."""
import argparse
import gzip
import hashlib
import json
from pathlib import Path
import re
import shutil
from summarize_envelope import summarize

def main():
    p=argparse.ArgumentParser();p.add_argument('source',type=Path);p.add_argument('destination',type=Path)
    a=p.parse_args();src=a.source.resolve();dst=a.destination.resolve()
    dst.mkdir(parents=True,exist_ok=True)
    def copy(path,relative):
        target=dst/relative;target.parent.mkdir(parents=True,exist_ok=True)
        shutil.copyfile(path,target)
    for filename in ('experiment.json','measurements.json','reference.json','tool-versions.json',
                     'build-concurrency-adjustment.json','generate.log'):
        copy(src/filename,filename)
    summary=summarize(src)
    rows=json.loads((src/'measurements.json').read_text())['cases']
    summary['distinct_cases']=len({r['label'] for r in rows})
    summary['passing_comparisons']=sum(
        r['reports'][-1]['comparisons'] if r['kind']=='standalone' else sum(p['comparisons'] for p in r['reports'])
        for r in rows if r['status']=='pass')
    netlists={}
    post_pnr_hashes={}
    for directory in ('hardware','guests'):
        for path in (src/directory).rglob('*'):
            if path.is_file():copy(path,path.relative_to(src))
    for directory in sorted(src.glob('recovery-*')):
        for path in directory.iterdir():
            if path.is_file():copy(path,path.relative_to(src))
    for build in sorted((src/'builds').iterdir()):
        receipt=build/'receipt.json'
        if not receipt.exists():continue
        copy(receipt,Path('builds')/build.name/'receipt.json')
        r=json.loads(receipt.read_text())
        if r['status']=='built':
            for path,expected in r['sha256'].items():
                actual=hashlib.sha256(Path(path).read_bytes()).hexdigest()
                if actual!=expected:raise ValueError(f'Changed build input: {path}')
            for relative in ('clocks.sdc','pll.v','build.tcl','sdram-io-model.json','impl/pnr/sdram_test.tr'):
                copy(build/relative,Path('builds')/build.name/relative)
            netlist=(build/'impl/pnr/sdram_test.vo').read_text()
            normalized=re.sub(r'^//Created Time:.*$', '//Created Time: omitted',netlist,flags=re.M)
            normalized,n=re.subn(r'\.PSDA_SEL="[01]{4}";', '.PSDA_SEL="PHASE";',normalized)
            if n!=1:raise ValueError(f'Expected one phase parameter in {build.name}')
            key=f'{r["kind"]}-{r["frequency_mhz"]}'
            netlists.setdefault(key,{})[build.name]=hashlib.sha256(normalized.encode()).hexdigest()
            post_pnr_hashes[build.name]=hashlib.sha256(netlist.encode()).hexdigest()
            sample=dst/'netlists'/f'{key}.vo.gz'
            if not sample.exists():
                sample.parent.mkdir(exist_ok=True)
                sample.write_bytes(gzip.compress(netlist.encode(),mtime=0))
        # Keep successful routes and failed/interrupted attempts together.
        for path in build.glob('*.log'):copy(path,Path('builds')/build.name/path.name)
        for path in build.glob('receipt-*json'):copy(path,Path('builds')/build.name/path.name)
    # Auxiliary routes used isolated directories to avoid concurrent writers.
    # Preserve their interrupted/unused attempts even if the primary won.
    for build in sorted((src/'aux54/builds').glob('*')):
        for path in list(build.glob('*.log'))+list(build.glob('receipt*.json')):
            copy(path,Path('auxiliary-attempts')/build.name/path.name)
    summary['phase_only_netlist_check']={k:dict(cases=len(v),identical=len(set(v.values()))==1,normalized_sha256=v)
                                         for k,v in netlists.items()}
    summary['post_pnr_netlist_sha256']=post_pnr_hashes
    (dst/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
    sources=Path(__file__).resolve().parent
    for filename in ('envelope_guest.c','run_operating_envelope.py','summarize_envelope.py',
                     'test_operating_envelope.py','collect_envelope.py','plot_envelope.py'):
        copy(sources/filename,Path('tools')/filename)
    manifest={str(path.relative_to(dst)):hashlib.sha256(path.read_bytes()).hexdigest()
              for path in sorted(dst.rglob('*')) if path.is_file() and path.name!='manifest.json'}
    (dst/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    print(f'{len(rows)} runs, {summary["distinct_cases"]} distinct cases, {len(manifest)} evidence files')

if __name__=='__main__':main()
