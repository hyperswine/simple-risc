#!/usr/bin/env python3
"""Build and measure a frozen standalone/integrated SDRAM phase matrix.

SRAM only; internal STA is mandatory, SDRAM electrical signoff remains false.
Builds run separately from the single-owner hardware loop. Every hardware
invocation restores and probes the hash-pinned recovery image in finally.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import select
import shutil
import struct
import subprocess
import sys
import time

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import rom_protocol as rp
from run_program import open_port

PHASES = [135, 112.5, 90, 157.5, 67.5, 180, 45, 202.5,
          22.5, 225, 0, 247.5, 270, 292.5, 315, 337.5]
PORT = '/dev/cu.usbserial-20250303171'
LOADER = '/Users/jasonqin/Documents/Libs/oss-cad-suite/bin/openFPGALoader'

def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()

def save(path, data):
    tmp = path.with_suffix('.tmp')
    tmp.write_text(json.dumps(data, indent=2, allow_nan=False)+'\n')
    tmp.replace(path)

def name(kind, freq, phase):
    return f'{kind}-{freq}-p{phase:g}'

def matrix():
    return [(kind, freq, p) for freq in (48,54,60)
            for p in PHASES for kind in ('standalone','integrated')]

def timing(out, source, freq):
    return subprocess.check_output([sys.executable,
        str(source/'boards/tangnano20k/check_gowin_timing.py'),
        str(out/'impl/pnr/sdram_test.tr'), '--freq-mhz', str(freq)], text=True).strip()

def build_one(base, case):
    kind, freq, phase = case
    label = name(*case); out=base/'builds'/label
    out.mkdir(parents=True, exist_ok=True)
    receipt=out/'receipt.json'
    if receipt.exists():
        old=json.loads(receipt.read_text())
        if old.get('status')=='built' and all(sha(f)==h for f,h in old['sha256'].items()):
            return old
        history=out/f'receipt-prior-{time.time_ns()}.json'
        shutil.copyfile(receipt,history)
    source=base/'source'
    env={k:v for k,v in os.environ.items() if not k.startswith('SDRAM_')}
    env.update(SDRAM_FREQ_MHZ=str(freq), SDRAM_CPU_FREQ_MHZ=str(freq),
        SDRAM_PHASE_DEGREES=f'{phase:g}', SDRAM_OUT=str(out), SDRAM_RVC='1',
        SDRAM_TARGET_MHZ=str({48:53,54:60,60:66}[freq]), SDRAM_PLACE_OPTION='0',
        SDRAM_ROUTE_OPTION='1', SDRAM_MAP_OPTION='3', SDRAM_ROUTE_MAXFAN='8',
        SDRAM_RTL_FILE=str(base/'generated/SdramPipeline.topEntity/sdram_pipeline_risc.v'))
    result=dict(kind=kind, frequency_mhz=freq, phase_degrees=phase, label=label,
                status='build_failed', electrical_signoff=False)
    # Record only build settings, not unrelated shell environment or credentials.
    result['environment']={k:v for k,v in env.items() if k.startswith('SDRAM_')}
    start=time.monotonic()
    prior_attempt=max([int(p.stem.split('-')[-1]) for p in out.glob('build-*.log')]+[0])
    for attempt in range(1,4):
        log=out/f'build-{prior_attempt+attempt}.log'
        with log.open('w') as f:
            proc=subprocess.run(['bash',str(source/'boards/tangnano20k/sdram/build.sh'),
                'burst-test' if kind=='standalone' else 'pipeline'],env=env,
                stdout=f,stderr=subprocess.STDOUT,timeout=1200)
        result['returncode']=proc.returncode
        if proc.returncode==0: break
        if 'License verification failed' not in log.read_text(): break
        time.sleep(3)
    if proc.returncode==0:
        result['timing']=timing(out,source,freq)
        files=[Path(p) for p in re.findall(r'^add_file "([^"]+)"', (out/'build.tcl').read_text(),re.M)]
        files += [out/'build.tcl',out/'sdram-io-model.json',out/'impl/pnr/sdram_test.fs',out/'impl/pnr/sdram_test.tr']
        if kind=='integrated': files += [out/'bootrom-sdram.hex']
        assert f'PSDA_SEL("{int(phase/22.5):04b}")' in (out/'pll.v').read_text()
        assert f'-phase {phase:g} ' in (out/'clocks.sdc').read_text()
        assert 'set_false_path' not in (out/'clocks.sdc').read_text()
        result.update(status='built',sha256={str(p):sha(p) for p in files})
    result['elapsed_seconds']=time.monotonic()-start
    save(receipt,result)
    print(label,result['status'],round(result['elapsed_seconds'],1),flush=True)
    return result

def build_guests(base):
    out=base/'guests';out.mkdir(exist_ok=True)
    src=base/'source/boards/tangnano20k'
    # Keep the added probe alongside the frozen tree's support sources.
    shutil.copyfile(HERE/'envelope_guest.c',src/'sdram/envelope_guest.c')
    for freq in (48,54,60):
        elf=out/f'envelope-{freq}.elf'
        subprocess.run(['riscv64-unknown-elf-gcc','-march=rv32im_zicsr','-mabi=ilp32',
            '-mcmodel=medany','-O2','-Wall','-Wextra','-Werror','-ffreestanding',
            '-fno-builtin','-nostdlib','-nostartfiles','-Wl,--no-warn-rwx-segments',
            f'-DCPU_MHZ={freq}','-T',str(src/'sdram/link.ld'),str(src/'c/crt0.S'),
            str(src/'c/uart.c'),str(src/'sdram/envelope_guest.c'),'-o',str(elf)],check=True)
        subprocess.run(['riscv64-unknown-elf-objcopy','-O','binary',str(elf),str(elf.with_suffix('.bin'))],check=True)

def pattern(i,p):
    h=(((i+0x80010000//4)*0x9e3779b1)^0xa5c35a69)&0xffffffff
    return 0 if p==0 else 0xffffffff if p==1 else (~h)&0xffffffff if p==3 else h

def reference_digests():
    count=(0x807f0000-0x80010000)//4
    result=[]
    for p in range(6):
        d=0
        for k in range(count):
            i=count-1-k if p==5 else k
            d=(((d<<5)|(d>>27))&0xffffffff)^pattern(i,p)
        result.append(d)
    return result

def standalone(fd, dest, timeout):
    start=time.monotonic(); raw=bytearray(); buf=b''; reports=[]
    result=dict(status='inconclusive',reports=reports)
    os.write(fd,b'S')
    try:
        while time.monotonic()-start<timeout:
            if select.select([fd],[],[],.1)[0]:
                chunk=os.read(fd,4096);raw.extend(chunk);buf+=chunk
            while len(buf)>=25:
                packet,buf=buf[:25],buf[25:]
                magic,p,errors,checks,address,expected,actual=struct.unpack('<4sB5I',packet)
                if magic!=b'SDR1': raise ValueError('invalid SDR1 packet')
                if p==255:
                    if reports or checks or errors: raise ValueError('invalid start')
                elif p!=len(reports)-1 or checks!=(p+1)*2097152 or errors>checks:
                    raise ValueError('invalid pattern order/coverage')
                reports.append(dict(pattern=p,errors=errors,comparisons=checks,
                    first_address=address,expected=expected,actual=actual))
                if p!=255 and (errors or p==5):
                    result['status']='memory_fail' if errors else 'pass'
                    return result
        raise TimeoutError('standalone report timeout')
    except Exception as exc:
        result['error']=f'{type(exc).__name__}: {exc}'
        return result
    finally:
        (dest/'uart.bin').write_bytes(raw)
        result['elapsed_seconds']=time.monotonic()-start

def parse_integrated(raw, expected):
    lines=raw.decode('ascii').splitlines()
    if not lines or lines[0]!='ENV1 START 80010000 807f0000 001f8000':
        raise ValueError('missing or incorrect test-range header')
    reports=[]
    for line in lines[1:]:
        if line.startswith('ENV1 RESULT '):
            parts=line.split()[2:]
            if len(parts)!=7 or any(not re.fullmatch('[0-9a-f]{8}',s) for s in parts):
                raise ValueError('malformed result')
            p,count,errors,addr,want,got,digest=map(lambda x:int(x,16),parts)
            if p!=len(reports) or count!=0x1f8000 or errors>count:
                raise ValueError('wrong coverage/order')
            reports.append(dict(pattern=p,comparisons=count,errors=errors,
                first_address=addr,expected=want,actual=got,digest=f'{digest:08x}'))
            if errors: return dict(status='memory_fail',reports=reports)
            if digest!=expected[p]:
                return dict(status='digest_fail',reports=reports)
        elif line not in ('ENV1 PASS','DONE'):
            raise ValueError('unexpected guest output')
    if len(reports)!=6 or lines[-2:]!=['ENV1 PASS','DONE']:
        raise ValueError('incomplete guest results')
    return dict(status='pass',reports=reports)

def integrated(fd,base,freq,dest,timeout,expected):
    transport=rp.FdTransport(fd);start=time.monotonic();raw=b''
    result=dict(status='inconclusive',receive_crc_verified=False)
    try:
        ident=rp.query_identity(transport,expected_mhz=freq,candidate_mhz=())
        rp.check_compatibility(ident,expected_cpu_mhz=freq,required_caps='UICG')
        if ident.mem_mhz!=freq: raise ValueError('memory identity mismatch')
        result['identity']=ident.raw
        # Exercise cold upload/readback before running a guest.
        image=(base/'guests'/f'envelope-{freq}.bin').read_bytes()
        result['guest_sha256']=hashlib.sha256(image).hexdigest()
        rp.upload_image_u(transport,image,verify_readback=False,retries=0,timeout=10)
        result['receive_crc_verified']=True
        transport.write(b'C')
        reply=transport.read_until(lambda b:b'\n' in b,10)
        import zlib
        result['readback_crc']=reply.decode('ascii','backslashreplace').strip()
        result['expected_crc']=f'{zlib.crc32(image+bytes(-len(image)%4)):08x}'
        if not re.fullmatch('[0-9a-f]{8}',result['readback_crc']):
            raise ValueError('malformed/absent memory CRC reply')
        if result['readback_crc']!=result['expected_crc']:
            result['readback_repeats']=[result['readback_crc']]
            for _ in range(2):
                transport.write(b'C')
                crc=transport.read_until(lambda b:b'\n' in b,5).decode('ascii','backslashreplace').strip()
                if not re.fullmatch('[0-9a-f]{8}',crc):raise ValueError('malformed repeated memory CRC')
                result['readback_repeats'].append(crc)
            result['status']='readback_fail'
            return result
        raw=rp.start_guarded(transport)
        deadline=time.monotonic()+timeout
        idle_deadline=time.monotonic()+40
        while not raw.endswith(b'DONE') and time.monotonic()<min(deadline,idle_deadline):
            if select.select([fd],[],[],.1)[0]:
                chunk=os.read(fd,4096)
                raw+=chunk
                if chunk:idle_deadline=time.monotonic()+40
        result.update(parse_integrated(raw,expected))
        return result
    except Exception as exc:
        result['error']=f'{type(exc).__name__}: {exc}'
        return result
    finally:
        transport.write(b'\x03');transport.drain(quiet_s=.2,max_s=1)
        (dest/'uart.bin').write_bytes(raw)
        result['elapsed_seconds']=time.monotonic()-start

def program(image,log):
    with log.open('w') as f:
        subprocess.run([LOADER,'-b','tangnano20k',str(image)],stdout=f,stderr=subprocess.STDOUT,timeout=60,check=True)
    time.sleep(.4)

def measure(base, cases, repeat):
    meta=json.loads((base/'experiment.json').read_text())
    if sha(base/'restore.fs')!=meta['restore_sha256']: raise ValueError('restore hash mismatch')
    expected=json.loads((base/'reference.json').read_text())
    journal=base/'measurements.json'
    state=json.loads(journal.read_text()) if journal.exists() else {'cases':[]}
    runid=datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    recovery=base/f'recovery-{runid}';recovery.mkdir()
    try:
        for case in cases:
            label=name(*case);out=base/'builds'/label
            receipt=json.loads((out/'receipt.json').read_text())
            if receipt['status']!='built':
                print(label,'SKIP build failure',flush=True);continue
            if any(sha(p)!=h for p,h in receipt['sha256'].items()): raise ValueError('build artifact changed')
            for rep in range(repeat):
                prior=[c for c in state['cases'] if c['label']==label]
                dest=base/'hardware'/label/f'run-{len(prior)+1}'
                dest.mkdir(parents=True,exist_ok=False)
                start=time.monotonic()
                started=datetime.datetime.now(datetime.timezone.utc).isoformat()
                image=out/'impl/pnr/sdram_test.fs'
                print('PROGRAM',label,'run',len(prior)+1,flush=True)
                program(image,dest/'program.log')
                fd=open_port(PORT,rp.baud_for_mhz(case[1]))
                try:
                    result=standalone(fd,dest,180) if case[0]=='standalone' else integrated(fd,base,case[1],dest,180,expected)
                    time.sleep(.15)
                finally: os.close(fd)
                result.update(label=label,kind=case[0],frequency_mhz=case[1],phase_degrees=case[2],
                    run=len(prior)+1,image_sha256=sha(image),receipt_sha256=sha(out/'receipt.json'),
                    runner_sha256=sha(__file__),
                    started_utc=started,
                    total_seconds=time.monotonic()-start)
                save(dest/'result.json',result);state['cases'].append(result);save(journal,state)
                print('RESULT',label,result['status'],round(result['total_seconds'],1),result.get('error',''),flush=True)
    finally:
        print('RESTORE',flush=True)
        if sha(base/'restore.fs')!=meta['restore_sha256']:raise ValueError('restore changed')
        program(base/'restore.fs',recovery/'program.log')
        fd=open_port(PORT,rp.baud_for_mhz(54))
        try:
            transport=rp.FdTransport(fd)
            ident=rp.query_identity(transport,expected_mhz=54,candidate_mhz=())
            if ident.raw!=meta['starting_identity']:raise ValueError('restored identity mismatch')
            from sdram.diagnose_output import probe_uploads
            probes=probe_uploads(transport,5)
            record=dict(identity=ident.raw,upload_probes=probes,passed=all(p['passed'] for p in probes),image_sha256=sha(base/'restore.fs'))
            save(recovery/'result.json',record)
            if not record['passed']:raise RuntimeError('restore upload probes failed')
            print('RESTORED: identity and 12 CRC probes pass',flush=True)
        finally:os.close(fd)

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('action',choices=['build','guests','measure','follow'])
    p.add_argument('--out',type=Path,required=True)
    p.add_argument('--jobs',type=int,default=2)
    p.add_argument('--only',nargs='*',help='exact case labels')
    p.add_argument('--repeat',type=int,default=1)
    p.add_argument('--kind',choices=['standalone','integrated'])
    p.add_argument('--frequency',type=int,choices=[48,54,60])
    p.add_argument('--unmeasured',action='store_true')
    a=p.parse_args();base=a.out.resolve()
    if a.jobs<1 or a.repeat<1:p.error('jobs and repeat must be positive')
    cases=[c for c in matrix() if (not a.only or name(*c) in a.only)
           and (not a.kind or c[0]==a.kind) and (not a.frequency or c[1]==a.frequency)]
    if a.only and set(a.only)!={name(*c) for c in cases}:p.error('unknown case')
    if a.unmeasured and (base/'measurements.json').exists():
        done={c['label'] for c in json.loads((base/'measurements.json').read_text())['cases']}
        cases=[c for c in cases if name(*c) not in done]
    if a.action=='guests':
        build_guests(base);save(base/'reference.json',reference_digests())
    elif a.action=='build':
        with ThreadPoolExecutor(max_workers=a.jobs) as pool:
            results=[f.result() for f in as_completed([pool.submit(build_one,base,c) for c in cases])]
        save(base/'build-results.json',results)
    else:
        with (base/'board.lock').open('w') as lock:
            fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
            if a.action=='measure':measure(base,cases,a.repeat)
            else:
                deadline=time.monotonic()+7200
                while time.monotonic()<deadline:
                    history=json.loads((base/'measurements.json').read_text())['cases'] if (base/'measurements.json').exists() else []
                    ready=[];pending=[]
                    for case in cases:
                        label=name(*case)
                        runs=[r for r in history if r['label']==label]
                        if sum(r['status']!='inconclusive' for r in runs)>=2 or len(runs)>=4:continue
                        pending.append(label)
                        receipt=base/'builds'/label/'receipt.json'
                        if receipt.exists() and json.loads(receipt.read_text()).get('status')=='built':ready.append(case)
                    if not pending:
                        print('All selected cases have repeated conclusive results or exhausted four attempts',flush=True)
                        return
                    if ready:measure(base,ready,1)
                    else:
                        print('Waiting for builds:',', '.join(pending),flush=True)
                        time.sleep(30)
                raise TimeoutError('follow deadline reached; inspect incomplete cases')

if __name__=='__main__': main()
