from pathlib import Path
import concurrent.futures,fcntl,hashlib,json,os,re,shutil,subprocess,threading,time
R=Path(__file__).resolve().parents[2];B=R/'output/btb-feedback-2026-11-08';OLD=R/'output/btb-ablation-2026-11-08';LOCK=threading.Lock()
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def prepare():
 frozen=B/'frozen';frozen.mkdir(exist_ok=True)
 oldprotocol=json.loads((OLD/'protocol.json').read_text())
 for name in ('impl/gwsynthesis/sdram_test.vg','layout.json','bootrom-sdram.hex','clocks.sdc','build.tcl','pins.cst'):
  src=OLD/'frozen'/name;dst=frozen/name;dst.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(src,dst)
 assert sha(frozen/'impl/gwsynthesis/sdram_test.vg')==oldprotocol['hashes']['frozen/impl/gwsynthesis/sdram_test.vg']
 for v in ('baseline','anchors'):shutil.copyfile(OLD/(v+'.cst'),B/(v+'.cst'))
 (B/'feedback.cst').write_text((B/'anchors.cst').read_text()+(B/'feedback-group.cst').read_text())
 d=B/'feedback-source';d.mkdir(exist_ok=True)
 if not (d/'impl').exists():(d/'impl').symlink_to(frozen/'impl',target_is_directory=True)
 (d/'pins.cst').write_text((OLD/'anchors-source/pins.cst').read_text()+(B/'feedback-group.cst').read_text())
 for name in ('build.tcl','clocks.sdc'):shutil.copyfile(frozen/name,d/name)
 imported=[]
 for v in ('baseline','anchors'):
  for place in range(5):
   src=OLD/f'{v}-p{place}';dst=B/f'{v}-p{place}'
   if not dst.exists():dst.symlink_to(src.resolve(),target_is_directory=True)
   row=dict(json.loads((OLD/f'{v}-p{place}.json').read_text()),imported=True,origin=str(src.resolve().relative_to(R)))
   (B/f'{v}-p{place}.json').write_text(json.dumps(row,indent=2)+'\n')
   imported.append({'variant':v,'placement':place,'origin':row['origin'],'hashes':{n:sha(src/n) for n in ('pins.cst','clocks.sdc','build.tcl','pnr.log','impl/pnr/sdram_test.tr') if (src/n).exists()}})
 record={'baseline_commit':'dcd220d','cpu_mhz':81,'memory_mhz':48,'frequency_option_mhz':89,'placements':list(range(5)),'new_routes':5,'imported_controls':imported,'parallel_jobs':3,'route_timeout_seconds':1800,'order':[3,0,1,2,4],'hashes':{str(p.relative_to(B)):sha(p) for p in [frozen/'impl/gwsynthesis/sdram_test.vg',frozen/'bootrom-sdram.hex',frozen/'clocks.sdc',B/'baseline.cst',B/'anchors.cst',B/'feedback.cst',B/'feedback-group.cst',B/'feedback-region.json']}}
 (B/'protocol.json').write_text(json.dumps(record,indent=2)+'\n')
def run(place):
 name=f'feedback-p{place}';receipt=B/(name+'.json');out=B/name
 if receipt.exists():return json.loads(receipt.read_text())
 env=os.environ.copy();env.update(PNR_PLACE_OPTION=str(place),PNR_POSP='1',PNR_REPORT_PATHS='3000',PNR_TIMEOUT='1800')
 start=time.time()
 with LOCK:print('START',name,flush=True)
 with (B/(name+'.log')).open('w') as f:
  result=subprocess.run(['bash',str(R/'boards/tangnano20k/sdram/pnr_only.sh'),str(B/'feedback-source'),str(out)],cwd=R,env=env,stdout=f,stderr=subprocess.STDOUT)
 log=(B/(name+'.log')).read_text();pnr=(out/'pnr.log').read_text() if (out/'pnr.log').exists() else ''
 unrouted=re.search(r'total (\d+) unrouted nets',pnr)
 status='pass' if result.returncode==0 else 'timeout' if 'TIMEOUT:' in log else 'timing-fail' if 'FAIL: STA' in log else 'unrouted' if unrouted else 'tool-error'
 row=dict(variant='feedback',placement=place,status=status,returncode=result.returncode,elapsed_seconds=time.time()-start,imported=False)
 if unrouted:row['unrouted_nets']=int(unrouted[1])
 receipt.write_text(json.dumps(row,indent=2)+'\n')
 with LOCK:print('DONE',name,status,round(row['elapsed_seconds']),flush=True)
 return row
if __name__=='__main__':
 lock=(B/'sweep.lock').open('w');fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
 prepare()
 with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:list(pool.map(run,[3,0,1,2,4]))
 rows=[json.loads((B/f'{v}-p{p}.json').read_text()) for v in ('baseline','anchors','feedback') for p in range(5)]
 (B/'results.json').write_text(json.dumps(rows,indent=2)+'\n');print('COMPLETE',len(rows),'including 10 imported controls',flush=True)
