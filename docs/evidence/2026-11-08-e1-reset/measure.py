import os, subprocess, pathlib, shutil, json, hashlib, sys, time
root=pathlib.Path.cwd(); base=root/'output/refactor-e1-2026-11-08'
ide=pathlib.Path('/Applications/GowinIDE.app/Contents/Resources/Gowin_EDA/IDE')
for name in (sys.argv[1:] or ['candidate']):
    out=base/(name+'-physical'); rtl=base/(name+'-generated')/'SdramPipeline.topEntity/sdram_pipeline_risc.v'
    env=os.environ.copy()
    for key in list(env):
        if key.startswith('SDRAM_'): del env[key]
    env.update(SDRAM_FREQ_MHZ='48',SDRAM_CPU_FREQ_MHZ='81',SDRAM_RVC='1',SDRAM_CACHE='1',SDRAM_CACHE_WAYS='2',SDRAM_CACHE_LINE_BITS='11',SDRAM_PHASE_DEGREES='135',SDRAM_PLACE_OPTION='3',SDRAM_TARGET_MHZ='89',SDRAM_MAP_OPTION='3',SDRAM_ROUTE_OPTION='1',SDRAM_ROUTE_MAXFAN='8',SDRAM_CRITICAL_PATHS='3000',SDRAM_GENERATE_ONLY='1',SDRAM_OUT=str(out),SDRAM_RTL_FILE=str(rtl))
    with (base/(name+'-prepare.log')).open('w') as log:
        subprocess.run(['bash','boards/tangnano20k/sdram/build.sh','pipeline'],env=env,stdout=log,stderr=subprocess.STDOUT,check=True)
    # Identical stamped ROM: experiment identity kept outside synthesized data.
    shutil.copyfile(root/'output/tangnano20k/fprisc-81/bootrom-sdram.hex',out/'bootrom-sdram.hex')
    layout=root/'dist-newstyle/build/aarch64-osx/ghc-9.8.2/simple-risc-0.1.0.0/x/pipeline-layout/build/pipeline-layout/pipeline-layout'
    with (out/'layout.json').open('w') as f: subprocess.run([str(layout)],stdout=f,check=True)
    tcl=(out/'build.tcl').read_text().replace('run all','run syn')
    (out/'synthesis.tcl').write_text(tcl)
    record={'baseline_commit':'dcd220d','variant':name,'rtl_sha256':hashlib.sha256(rtl.read_bytes()).hexdigest(),'rom_sha256':hashlib.sha256((out/'bootrom-sdram.hex').read_bytes()).hexdigest(),'environment':{k:v for k,v in env.items() if k.startswith('SDRAM_')}}
    (out/'experiment.json').write_text(json.dumps(record,indent=2))
    env.update(DYLD_LIBRARY_PATH=str(ide/'lib'),DYLD_FRAMEWORK_PATH=str(ide/'lib'))
    for attempt in range(5):
        with (out/'synthesis.log').open('w') as log:
            result=subprocess.run([str(ide/'bin/gw_sh'),'synthesis.tcl'],cwd=out,env=env,stdout=log,stderr=subprocess.STDOUT)
        if result.returncode == 0: break
        if 'License verification failed' not in (out/'synthesis.log').read_text(): result.check_returncode()
        shutil.copyfile(out/'synthesis.log',out/f'license-attempt-{attempt}.log')
        time.sleep(10)
    result.check_returncode()
    subprocess.run(['python3','boards/tangnano20k/sdram/floorplan_cst.py','boards/tangnano20k/sdram/fprisc-81.plan',str(out/'impl/gwsynthesis/sdram_test.vg'),'--layout',str(out/'layout.json'),'-o',str(out/'floorplan.cst')],check=True)
    with (out/'pins.cst').open('a') as f: f.write('\n'+(out/'floorplan.cst').read_text())
    with (out/'area.txt').open('w') as f:
        subprocess.run(['python3','boards/tangnano20k/sdram/area_census.py',str(out/'impl/gwsynthesis/sdram_test.vg'),'--layout',str(out/'layout.json'),'--json',str(out/'area.json')],stdout=f,check=True)
    print(name+' synthesis complete',flush=True)
