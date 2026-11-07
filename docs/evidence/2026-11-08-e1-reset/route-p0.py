import subprocess,os,pathlib,time,json
root=pathlib.Path.cwd();base=root/'output/refactor-e1-2026-11-08'
# Allow an early parallel start without repeating the queued placement-0 run.
try:
    fd=os.open(base/'p0.started',os.O_CREAT|os.O_EXCL|os.O_WRONLY)
    os.close(fd)
except FileExistsError:
    raise SystemExit(0)
results=[]
for variant in ('candidate',):
    out=base/(variant+'-p0');env=os.environ.copy()
    env.update(PNR_PLACE_OPTION='0',PNR_POSP='1',PNR_REPORT_PATHS='3000',PNR_TIMEOUT='1200')
    start=time.monotonic()
    with (base/(variant+'-p0-route.log')).open('w') as log:
        result=subprocess.run(['bash','boards/tangnano20k/sdram/pnr_only.sh',str(base/(variant+'-physical')),str(out)],env=env,stdout=log,stderr=subprocess.STDOUT)
    results.append(dict(variant=variant,placement=0,returncode=result.returncode,elapsed_seconds=time.monotonic()-start))
    (base/'routing-p0-results.json').write_text(json.dumps(results,indent=2))
    print(results[-1],flush=True)
