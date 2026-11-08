set_device -name GW2AR-18C GW2AR-LV18QN88C8/I7
set_option -top_module top
set_option -output_base_name sdram_test
set_option -opt_goal timing
set_option -place_option 3
set_option -frequency 89
set_option -global_freq 89
set_option -num_critical_paths 3000
set_option -gen_verilog_sim_netlist 1
set_option -map_option 3
set_option -route_option 1
set_option -route_maxfan 8
add_file "/Users/jasonqin/Documents/GitHub/simple-risc/output/a-to-f-2026-11-08/candidate-physical/inputs/pipeline_top.v"
add_file "/Users/jasonqin/Documents/GitHub/simple-risc/output/a-to-f-2026-11-08/candidate-physical/inputs/memory.v"
add_file "/Users/jasonqin/Documents/GitHub/simple-risc/output/a-to-f-2026-11-08/candidate-physical/inputs/cache.v"
add_file "/Users/jasonqin/Documents/GitHub/simple-risc/output/a-to-f-2026-11-08/candidate-physical/inputs/pipeline_cache.v"
add_file "/Users/jasonqin/Documents/GitHub/simple-risc/output/a-to-f-2026-11-08/candidate-physical/inputs/burst_memory.v"
add_file "/Users/jasonqin/Documents/GitHub/simple-risc/output/a-to-f-2026-11-08/candidate-physical/inputs/clock_bridge.v"
add_file "/Users/jasonqin/Documents/GitHub/simple-risc/output/a-to-f-2026-11-08/candidate-physical/inputs/sdram.v"
add_file "/Users/jasonqin/Documents/GitHub/simple-risc/output/a-to-f-2026-11-08/candidate-physical/inputs/pll.v"
add_file "/Users/jasonqin/Documents/GitHub/simple-risc/output/a-to-f-2026-11-08/candidate-physical/inputs/dual_pll.v"
add_file "/Users/jasonqin/Documents/GitHub/simple-risc/output/a-to-f-2026-11-08/candidate-physical/pins.cst"
add_file "/Users/jasonqin/Documents/GitHub/simple-risc/output/a-to-f-2026-11-08/candidate-physical/clocks.sdc"
add_file "/Users/jasonqin/Documents/GitHub/simple-risc/output/a-to-f-2026-11-08/candidate-physical/inputs/sdram_pipeline_risc.v"
run syn
exit
