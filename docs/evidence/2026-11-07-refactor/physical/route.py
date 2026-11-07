import subprocess,os,pathlib,time,json
root=pathlib.Path.cwd();base=root/'output/refactor-2026-11-07'
results=[]
for variant in ('baseline','candidate'):
    out=base/(variant+'-p3');env=os.environ.copy()
    env.update(PNR_PLACE_OPTION='3',PNR_POSP='1',PNR_REPORT_PATHS='3000',PNR_TIMEOUT='1200')
    start=time.monotonic()
    with (base/(variant+'-route.log')).open('w') as log:
        result=subprocess.run(['bash','boards/tangnano20k/sdram/pnr_only.sh',str(base/(variant+'-physical')),str(out)],env=env,stdout=log,stderr=subprocess.STDOUT)
    results.append(dict(variant=variant,placement=3,returncode=result.returncode,elapsed_seconds=time.monotonic()-start))
    (base/'routing-results.json').write_text(json.dumps(results,indent=2))
    print(results[-1],flush=True)
