#!/usr/bin/env python3
"""Small Clash/Verilog controls, each with a frozen-netlist placement sweep."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import time

HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[2]
GENERATED=ROOT/'output/tangnano20k/fast-probe-generated'
VARIANTS={
 'lfsr':('probe_lfsr','lfsrTop'), 'counter':('probe_counter','counterTop'),
 'bram':('probe_bram','bramTop'), 'bram_add':('probe_bram_add','bramAddTop'),
 'bram_pipe_norst':('probe_bram_pipe_norst','noreset'),
 'bram_pipe_add':('probe_bram_pipe_add','pipeline'),
 'rtl_lfsr':('reference_lfsr',None),'rtl_counter':('reference_counter',None),'rtl_bram':('reference_bram',None)}

def pll_config(freq):
    if not 0 < freq <= 625: raise ValueError('C8/I7 PLL output must be <=625 MHz')
    for divider in (9,6,3,2,1):
        multiplier=freq*divider/27
        if multiplier != int(multiplier) or not 1<=multiplier<=64: continue
        for output_divider in (2,4,8,16,32,64,128):
            if 500<=freq*output_divider<=1250:
                return int(multiplier),divider,output_divider
    raise ValueError(f'no legal C8/I7 PLL setting for {freq} MHz')

def measure(directory,freq):
    timing=(directory/'impl/pnr/probe.tr').read_text()
    usage=(directory/'impl/pnr/probe.rpt.txt').read_text()
    def get(pattern,text=timing):
        m=re.search(pattern,text,re.M|re.S)
        if not m: raise ValueError(f'missing report field {pattern} in {directory}')
        return m
    clock=get(r'^\s*\d+\s+clk_core\s+([\d.]+)\(MHz\)\s+([\d.]+)\(MHz\)')
    assert abs(float(clock[1])-freq)<.001, 'wrong clock constraint'
    setup=int(get(r'<Numbers of Setup Violated Endpoints>:(\d+)')[1])
    hold=int(get(r'<Numbers of Hold Violated Endpoints>:(\d+)')[1])
    table=get(r'3\.1\.1 Setup Paths Table\s*<Report Command>:(.*?)3\.1\.2 Hold Paths Table')[1]
    worst=get(r'^\s*1\s+(-?[\d.]+)\s+(\S+)\s+(\S+)\s',table)
    stats=get(r'Path Summary:.*?Logic Level:\s*(\d+).*?Arrival Data Path Delay: \(cell:\s*([\d.]+).*?route:\s*([\d.]+)')
    pulse=get(r'MPW Summary:\s*Slack:\s*(-?[\d.]+).*?Actual Width:\s*(-?[\d.]+).*?Required Width:\s*([\d.]+)')
    setup_hold_passes=setup==0 and hold==0 and float(worst[1])>=0
    resources={name.lower():int(get(r'^\s*'+name+r'\s*\|\s*([\d,]+)/',usage)[1].replace(',','')) for name in ('Logic','Register','CLS')}
    bram=re.search(r'^\s*BSRAM\s*\|\s*(\d+)/',usage,re.M)
    return dict(fmax_mhz=float(clock[2]),slack_ns=float(worst[1]),setup=setup,hold=hold,
                setup_hold_passes=setup_hold_passes,
                minimum_pulse_slack_ns=float(pulse[1]),minimum_pulse_actual_ns=float(pulse[2]),minimum_pulse_required_ns=float(pulse[3]),
                passes=setup_hold_passes and float(pulse[1])>=0,
                start=worst[2],end=worst[3],levels=int(stats[1]),cell_ns=float(stats[2]),route_ns=float(stats[3]),
                bsram=int(bram[1]) if bram else 0,**resources)

def run_tool(out,ide):
    env=dict(os.environ,DYLD_LIBRARY_PATH=str(ide/'lib'),DYLD_FRAMEWORK_PATH=str(ide/'lib'))
    for attempt in range(5):
        with (out/'tool.log').open('w') as log:
            run=subprocess.run([str(ide/'bin/gw_sh'),'build.tcl'],cwd=out,env=env,stdout=log,stderr=subprocess.STDOUT,timeout=600)
        if run.returncode==0: return
        if 'License verification failed' not in (out/'tool.log').read_text():
            raise RuntimeError(f'Gowin failed: {out}/tool.log')
        print(f"License server unavailable ({attempt+1}/5), retrying",flush=True)
        time.sleep(15)
    raise RuntimeError('Gowin license unavailable')

def prepare(out,module,rtl,freq,target,place,board=False,continuous=False):
    out.mkdir(parents=True,exist_ok=True)
    multiplier,divider,odiv=pll_config(freq)
    pll=(HERE.parent/'sdram/pll.v').read_text().replace('module sdram_pll #','module probe_pll #')
    pll=pll.replace('parameter FBDIV_SEL=17, ODIV_SEL=16','parameter FBDIV_SEL=17, IDIV_SEL=8, ODIV_SEL=16').replace('.IDIV_SEL(8)', '.IDIV_SEL(IDIV_SEL)')
    (out/'pll.v').write_text('`default_nettype wire\n'+pll)
    if board:
        wrapper=(HERE/('board_continuous.v' if continuous else 'board_top.v')).read_text().replace('PROBE_MODULE',module)
        encoded=int(freq) if freq==int(freq) else int(freq*2)
        assert freq*2==int(freq*2), 'telemetry supports half-MHz steps'
        wrapper=wrapper.replace('parameter integer FREQ_MHZ=216;',f'parameter integer FREQ_MHZ={encoded};')
        if freq!=int(freq): wrapper=wrapper.replace("32'h31485046","32'h32485046").replace("32'h31435046","32'h32435046")
    else:
        wrapper='''`default_nettype none
module top(input wire clk_27m, output wire uart_tx);
 wire clk_core,pll_lock;
 PLL_INSTANCE
 reg [1:0] reset_pipe=3;
 always @(posedge clk_core) reset_pipe<={reset_pipe[0],~pll_lock};
 wire [31:0] q;
 PROBE_MODULE probe(.clk(clk_core),.reset(reset_pipe[1]),.enable(1'b1),.q(q));
 reg [31:0] observed=0;
 always @(posedge clk_core) observed<=q;
 assign uart_tx=^observed;
endmodule
'''.replace('PROBE_MODULE',module)
    wrapper=wrapper.replace('PLL_INSTANCE',f'probe_pll #(.FBDIV_SEL({multiplier-1}),.IDIV_SEL({divider-1}),.ODIV_SEL({odiv})) pll(.clk_27m(clk_27m),.clk_core(clk_core),.clk_sdram(),.pll_lock(pll_lock));')
    (out/'top.v').write_text(wrapper)
    (out/'pins.cst').write_text('IO_LOC "clk_27m" 4;\nIO_PORT "clk_27m" IO_TYPE=LVCMOS33 PULL_MODE=UP;\nIO_LOC "uart_tx" 69;\nIO_PORT "uart_tx" IO_TYPE=LVCMOS33 PULL_MODE=UP DRIVE=8;\n')
    constraints=f'create_clock -name clk_27m -period 37.037037 [get_ports {{clk_27m}}]\ncreate_generated_clock -name clk_core -source [get_ports {{clk_27m}}] -multiply_by {multiplier} -divide_by {divider} [get_pins {{pll/pll_s2/CLKOUT}}]\n'
    if board:
        constraints+='set_clock_groups -asynchronous -group [get_clocks {clk_27m}] -group [get_clocks {clk_core}]\n'
    constraints+='report_timing -setup -from_clock [get_clocks {clk_core}] -to_clock [get_clocks {clk_core}] -max_paths 100 -max_common_paths 1\nreport_high_fanout_nets -max_nets 20\n'
    (out/'clocks.sdc').write_text(constraints)
    settings=f'''set_device -name GW2AR-18C GW2AR-LV18QN88C8/I7
set_option -output_base_name probe
set_option -opt_goal timing
set_option -map_option 3
set_option -route_option 1
set_option -route_maxfan 8
set_option -frequency {target}
set_option -global_freq {target}
set_option -num_critical_paths 100
set_option -looplimit 40000
'''
    files=[out/'top.v',out/'pll.v',rtl]
    (out/'build.tcl').write_text(settings+f'set_option -top_module top\nset_option -place_option {place}\n'+''.join(f'add_file "{p}"\n' for p in files+[out/'pins.cst',out/'clocks.sdc'])+'run all\nexit\n')
    return settings

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--out',type=Path,required=True)
    parser.add_argument('--freq',type=float,default=216)
    parser.add_argument('--target',type=int,default=240)
    parser.add_argument('--variants',default=','.join(VARIANTS))
    parser.add_argument('--placements',default='0,1,2,3,4')
    parser.add_argument('--board',action='store_true')
    parser.add_argument('--continuous',action='store_true',help='continuous probe with paired snapshots; implies --board')
    parser.add_argument('--prepare-only',action='store_true')
    args=parser.parse_args()
    args.board = args.board or args.continuous
    out=args.out.resolve(); out.mkdir(parents=True,exist_ok=True)
    ide=Path(os.environ.get('GOWIN_IDE','/Applications/GowinIDE.app/Contents/Resources/Gowin_EDA/IDE'))
    results={}
    places=[int(p) for p in args.placements.split(',')]
    assert places[0]==0 and all(0<=p<=4 for p in places)
    for variant in args.variants.split(','):
        module,entry=VARIANTS[variant]
        rtl=GENERATED/f'FastProbe.{entry}'/f'{module}.v' if entry else HERE/'reference.v'
        if entry=='pipeline': rtl=ROOT/'output/tangnano20k/fast-probe-extra/FastProbePipeline.topEntity/probe_bram_pipe_add.v'
        if entry=='noreset': rtl=ROOT/'output/tangnano20k/fast-probe-norst/FastProbeNoReset.topEntity/probe_bram_pipe_norst.v'
        if not rtl.is_file(): raise FileNotFoundError(rtl)
        base=out/variant/'p0'
        settings=prepare(base,module,rtl,args.freq,args.target,0,args.board,args.continuous)
        if args.prepare_only: continue
        run_tool(base,ide)
        netlist=base/'impl/gwsynthesis/probe.vg'
        digest=hashlib.sha256(netlist.read_bytes()).hexdigest()
        results[variant]={}
        for place in places:
            directory=out/variant/f'p{place}'
            if place:
                directory.mkdir(parents=True,exist_ok=True)
                for name in ('pins.cst','clocks.sdc'): (directory/name).write_bytes((base/name).read_bytes())
                (directory/'build.tcl').write_text(settings+f'set_option -place_option {place}\nadd_file -type netlist "{netlist}"\nadd_file "{directory}/pins.cst"\nadd_file "{directory}/clocks.sdc"\nrun pnr\nexit\n')
                run_tool(directory,ide)
            assert hashlib.sha256(netlist.read_bytes()).hexdigest()==digest
            result=measure(directory,args.freq)
            result['netlist_sha256']=digest
            results[variant][str(place)]=result
            print(f'{variant} p{place}: {result}',flush=True)
            (out/'results.json').write_text(json.dumps(dict(freq_mhz=args.freq,target_mhz=args.target,board=args.board,continuous=args.continuous,variants=results),indent=2)+'\n')

if __name__=='__main__': main()
