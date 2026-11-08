from pathlib import Path
import concurrent.futures,fcntl,hashlib,json,os,re,subprocess,threading,time
R=Path.cwd();B=R/'output/a-to-f-2026-11-08';OLD=R/'output/btb-ablation-2026-11-08';C=B/'candidate-physical';lock=threading.Lock()
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def prepare():
 assert json.loads((B/'host-receipt.json').read_text())['passed']
 assert json.loads((B/'rtl-validation.json').read_text())['passed']
 assert (C/'floorplan.cst').exists()
 imported=[]
 for p in range(5):
  src=(OLD/f'baseline-p{p}').resolve();dst=B/f'baseline-p{p}'
  if not dst.exists():dst.symlink_to(src,target_is_directory=True)
  row=dict(json.loads((OLD/f'baseline-p{p}.json').read_text()),imported=True,origin=str(src.relative_to(R)))
  (B/f'baseline-p{p}.json').write_text(json.dumps(row,indent=2)+'\n')
  imported.append({'placement':p,'origin':row['origin'],'hashes':{str(f.relative_to(src)):sha(f) for f in [src/'build.tcl',src/'pins.cst',src/'clocks.sdc',src/'pnr.log',src/'impl/pnr/sdram_test.tr'] if f.exists()}})
 record={'variants':['baseline','candidate'],'baseline_commit':'dcd220d','new_routes':5,'imported_controls':imported,'cpu_mhz':81,'memory_mhz':48,'frequency_option_mhz':89,'map_option':3,'route_option':1,'route_maxfan':8,'placements':list(range(5)),'order':[3,0,1,2,4],'parallel_jobs':3,'route_timeout_seconds':1800,'candidate_hashes':{str(p.relative_to(B)):sha(p) for p in [C/'impl/gwsynthesis/sdram_test.vg',C/'pins.cst',C/'clocks.sdc',C/'bootrom-sdram.hex',C/'layout.json',C/'floorplan.cst',B/'candidate.patch',B/'candidate-generated/SdramPipeline.topEntity/sdram_pipeline_risc.v']}}
 (B/'protocol.json').write_text(json.dumps(record,indent=2)+'\n')
def run(place):
 name=f'candidate-p{place}';receipt=B/(name+'.json');out=B/name
 if receipt.exists():return json.loads(receipt.read_text())
 env=dict(os.environ,PNR_PLACE_OPTION=str(place),PNR_POSP='1',PNR_REPORT_PATHS='3000',PNR_TIMEOUT='1800');start=time.time()
 with lock:print('START',name,flush=True)
 with (B/(name+'.log')).open('w') as f:r=subprocess.run(['bash',str(R/'boards/tangnano20k/sdram/pnr_only.sh'),str(C),str(out)],cwd=R,env=env,stdout=f,stderr=subprocess.STDOUT)
 log=(B/(name+'.log')).read_text();pnr=(out/'pnr.log').read_text() if (out/'pnr.log').exists() else '';u=re.search(r'total (\d+) unrouted nets',pnr)
 status='pass' if r.returncode==0 else 'timeout' if 'TIMEOUT:' in log else 'timing-fail' if 'FAIL: STA' in log else 'unrouted' if u else 'tool-error'
 row=dict(variant='candidate',placement=place,status=status,returncode=r.returncode,elapsed_seconds=time.time()-start,imported=False)
 if u:row['unrouted_nets']=int(u[1])
 receipt.write_text(json.dumps(row,indent=2)+'\n')
 with lock:print('DONE',name,status,round(row['elapsed_seconds']),flush=True)
 return row
if __name__=='__main__':
 f=(B/'sweep.lock').open('w');fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB);prepare()
 with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:list(pool.map(run,[3,0,1,2,4]))
 rows=[json.loads((B/f'{v}-p{p}.json').read_text()) for v in ('baseline','candidate') for p in range(5)]
 (B/'results.json').write_text(json.dumps(rows,indent=2)+'\n');print('COMPLETE 10 comparisons, including 5 imported controls',flush=True)
