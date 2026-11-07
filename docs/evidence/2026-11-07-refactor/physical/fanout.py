import sys,pathlib,re,collections,json
sys.path.insert(0,'boards/tangnano20k/sdram')
import area_census as a
base=pathlib.Path('output/refactor-2026-11-07');results={}
for name in ('baseline','candidate'):
    text=(base/(name+'-physical')/'impl/gwsynthesis/sdram_test.vg').read_text()
    module=re.search(r'^module sdram_pipeline_risc \(.*?^endmodule',text,re.S|re.M).group(0)
    inputs=collections.Counter();controls=collections.defaultdict(collections.Counter);types=collections.Counter()
    for kind,cell,pins in a.INSTANCE.findall(module):
        types[kind]+=1
        for pin,expression in a.PIN.findall(pins):
            if pin not in a.OUTPUT_PINS and pin not in ('CLK','CLK0','CLK1'):
                inputs.update(a.nets(expression))
            if kind.startswith('DFF') and pin in ('CE','RESET','SET','CLEAR','PRESET'):
                controls[pin].update(a.nets(expression))
    results[name]={'scope':'synthesized core module, direct input pin loads; clocks/constants excluded; not post-route replicated fanout','highest_input_loads':inputs.most_common(10),'control_pin_loads':{p:c.most_common(10) for p,c in controls.items()},'flipflops':{k:v for k,v in types.items() if k.startswith('DFF')}}
(base/'fanout.json').write_text(json.dumps(results,indent=2))
print(json.dumps(results,indent=2))
