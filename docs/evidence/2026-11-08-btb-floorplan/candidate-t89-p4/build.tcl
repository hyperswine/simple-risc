set_device -name GW2AR-18C GW2AR-LV18QN88C8/I7
set_option -output_base_name sdram_test
set_option -opt_goal timing
set_option -frequency 89
set_option -global_freq 89
set_option -map_option 3
set_option -route_option 1
set_option -route_maxfan 8
set_option -place_option 4
set_option -gen_posp 1
set_option -num_critical_paths 3000
add_file -type netlist "/Users/jasonqin/Documents/GitHub/simple-risc/output/btb-floorplan-2026-11-08/candidate-t89-source/impl/gwsynthesis/sdram_test.vg"
add_file "/Users/jasonqin/Documents/GitHub/simple-risc/output/btb-floorplan-2026-11-08/candidate-t89-p4/pins.cst"
add_file "/Users/jasonqin/Documents/GitHub/simple-risc/output/btb-floorplan-2026-11-08/candidate-t89-p4/clocks.sdc"
run pnr
exit
