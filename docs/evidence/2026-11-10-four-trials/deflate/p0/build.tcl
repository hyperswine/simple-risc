set_device -name GW2AR-18C GW2AR-LV18QN88C8/I7
set_option -top_module top
set_option -output_base_name deflate_test
set_option -opt_goal timing
set_option -looplimit 40000
set_option -place_option 0
set_option -frequency 92
set_option -global_freq 92
set_option -map_option 3
set_option -route_option 1
set_option -route_maxfan 8
set_option -num_critical_paths 100
set_option -gen_verilog_sim_netlist 1
add_file "/Users/jasonqin/Documents/GitHub/simple-risc/output/tangnano20k/four-trials-20261110/deflate/p0/deflate_top.v"
add_file "/Users/jasonqin/Documents/GitHub/simple-risc/output/tangnano20k/deflate-generated/Deflate.topEntity/deflate_inflate.v"
add_file "/Users/jasonqin/Documents/GitHub/simple-risc/output/tangnano20k/four-trials-20261110/deflate/p0/vector_rom.v"
add_file "/Users/jasonqin/Documents/GitHub/simple-risc/output/tangnano20k/four-trials-20261110/deflate/p0/pll.v"
add_file "/Users/jasonqin/Documents/GitHub/simple-risc/output/tangnano20k/four-trials-20261110/deflate/p0/pins.cst"
add_file "/Users/jasonqin/Documents/GitHub/simple-risc/output/tangnano20k/four-trials-20261110/deflate/p0/clocks.sdc"
file delete -force "/Users/jasonqin/Documents/GitHub/simple-risc/output/tangnano20k/four-trials-20261110/deflate/p0/impl/pnr/deflate_test.tr"
run all
exit
