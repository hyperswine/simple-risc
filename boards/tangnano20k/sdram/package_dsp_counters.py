#!/usr/bin/env python3
"""Wrap the DspCountersTop core in the three dsp_counter instances.

Clash generates `sdram_pipeline_core` (src/DspCountersTop.hs) with the
counters as ports. This writes `sdram_pipeline_risc.v`, the module name the
board top, the testbenches and build.sh expect: the core plus one dsp_counter
each for mcycle, mtime and minstret. The observed copy also carries the Gowin
simulation models of GSR and ALU54D, so Verilator and Icarus can run it; the
production copy has none, synthesis maps the primitive.

  package_dsp_counters.py GENERATED_DIR   (holds DspCountersTop.topEntity and .observedTop)
"""
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
MODEL = Path('/Applications/GowinIDE.app/Contents/Resources/Gowin_EDA/IDE/simlib/gw2a/prim_sim.v')

BASE_PORTS = '''input clk,reset,enable,uart_rx,input [31:0] memory_data,input memory_hold,sd_miso,
output uart_tx,output [21:0] memory_address,output memory_write,output [31:0] memory_wdata,
output [3:0] memory_mask,output sd_sck,sd_mosi,sd_cs'''
OBSERVED_PORTS = ''',output observe_commit,output [31:0] observe_word,observe_pc,observe_next_pc,
output observe_issue,output [31:0] observe_fetch_pc,output observe_empty,observe_redirect'''
BASE = ['clk', 'reset', 'enable', 'uart_rx', 'memory_data', 'memory_hold', 'sd_miso', 'uart_tx', 'memory_address',
        'memory_write', 'memory_wdata', 'memory_mask', 'sd_sck', 'sd_mosi', 'sd_cs']
OBSERVED = ['observe_commit', 'observe_word', 'observe_pc', 'observe_next_pc', 'observe_issue', 'observe_fetch_pc',
            'observe_empty', 'observe_redirect']
COUNTERS = [('cycle', "1'b1", 'enable'), ('time', "1'b1", 'enable'), ('instret', 'instret_increment', 'instret_enable')]


def wrapper(observed):
    text = 'module sdram_pipeline_risc\n(' + BASE_PORTS + (OBSERVED_PORTS if observed else '') + ');\n'
    if observed:
        text += '// synthesis translate_off\nGSR GSR(.GSRI(1\'b1));\n// synthesis translate_on\n'
    wires = []
    for name, _, _ in COUNTERS:
        wires += [f'{name}_lo', f'{name}_hi', f'{name}_write_value']
    text += 'wire [31:0] ' + ','.join(wires) + ';\n'
    flags = [f'{n}_{f}' for n, _, _ in COUNTERS for f in ('carry', 'write_valid', 'write_high')] + ['instret_increment', 'instret_enable']
    text += 'wire ' + ','.join(flags) + ';\n'
    for name, increment, enable in COUNTERS:
        text += (f'dsp_counter {name}_counter(clk,reset,{enable},{increment},{name}_write_valid,{name}_write_high,'
                 f'{name}_write_value,{name}_lo,{name}_hi,{name}_carry);\n')
    connections = BASE + (OBSERVED if observed else []) + wires + flags
    text += 'sdram_pipeline_core logic_core(' + ','.join(f'.{n}({n})' for n in connections) + ');\nendmodule\n'
    return text


def main():
    generated = Path(sys.argv[1]).resolve()
    counter = (HERE / 'dsp_counter.v').read_text()
    for entity, directory, observed in (('topEntity', 'SdramPipeline.topEntity', False),
                                        ('observedTop', 'SdramPipelineObserved.topEntity', True)):
        core = (generated / f'DspCountersTop.{entity}' / 'sdram_pipeline_core.v').read_text()
        parts = [wrapper(observed), counter, core]
        if observed:
            model = MODEL.read_text()
            parts += [re.search(r'^module ' + n + r'\b.*?^endmodule', model, re.S | re.M).group(0) for n in ('GSR', 'ALU54D')]
        out = generated / directory
        out.mkdir(parents=True, exist_ok=True)
        (out / 'sdram_pipeline_risc.v').write_text('\n'.join(parts) + '\n')
        print(out / 'sdram_pipeline_risc.v')


if __name__ == '__main__':
    main()
