from pathlib import Path
import re
b=Path('output/refactor-four-2026-11-08');raw=b/'dsp-raw-generated';dest=b/'dsp-generated'
model=Path('/Applications/GowinIDE.app/Contents/Resources/Gowin_EDA/IDE/simlib/gw2a/prim_sim.v').read_text()
prims='\n'.join(re.search(r'^module '+n+r'\b.*?^endmodule',model,re.S|re.M).group(0) for n in ['GSR','ALU54D'])
counter=(b/'dsp/counter.v').read_text().replace(' wire [53:0] result;', ''' // synthesis translate_off
 GSR GSR(.GSRI(1'b1));
 // synthesis translate_on
 wire [53:0] result;''')
baseports='''input clk,reset,enable,uart_rx,input [31:0] memory_data,input memory_hold,sd_miso,
output uart_tx,output [21:0] memory_address,output memory_write,output [31:0] memory_wdata,
output [3:0] memory_mask,output sd_sck,sd_mosi,sd_cs'''
obsports=''',output observe_commit,output[31:0] observe_word,observe_pc,observe_next_pc,
output observe_issue,output[31:0] observe_fetch_pc,output observe_empty,observe_redirect'''
base=['clk','reset','enable','uart_rx','memory_data','memory_hold','sd_miso','uart_tx','memory_address','memory_write','memory_wdata','memory_mask','sd_sck','sd_mosi','sd_cs']
obs=['observe_commit','observe_word','observe_pc','observe_next_pc','observe_issue','observe_fetch_pc','observe_empty','observe_redirect']
for fun,outdir,observed in [('topEntity','SdramPipeline.topEntity',False),('observedTop','SdramPipelineObserved.topEntity',True)]:
    core=(raw/f'DspCycleTop.{fun}'/'sdram_pipeline_core.v').read_text()
    wrapper='module sdram_pipeline_risc\n('+baseports+(obsports if observed else '')+');\n'
    wrapper+='wire[31:0] cycle_lo,cycle_hi,cycle_write_value;wire cycle_carry,cycle_write_valid,cycle_write_high;\n'
    wrapper+="dsp_counter cycle_counter(clk,reset,enable,1'b1,cycle_write_valid,cycle_write_high,cycle_write_value,cycle_lo,cycle_hi,cycle_carry);\n"
    connections=base+(obs if observed else [])+['cycle_lo','cycle_hi','cycle_carry','cycle_write_valid','cycle_write_high','cycle_write_value']
    wrapper+='sdram_pipeline_core logic_core('+','.join('.'+n+'('+n+')' for n in connections)+');\nendmodule\n'
    d=dest/outdir;d.mkdir(parents=True,exist_ok=True)
    (d/'sdram_pipeline_risc.v').write_text(wrapper+counter+'\n'+core+('\n'+prims if observed else ''))
    # Only simulation globs read this file; synthesis uses the single bundle.
    (d/'gowin_counter_models.v').unlink(missing_ok=True)
