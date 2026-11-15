set_device -name GW2AR-18C GW2AR-LV18QN88C8/I7
set_option -output_base_name probe
set_option -opt_goal timing
set_option -map_option 3
set_option -route_option 1
set_option -route_maxfan 8
set_option -frequency 240
set_option -global_freq 240
set_option -num_critical_paths 100
set_option -looplimit 40000
set_option -place_option 3
add_file -type netlist "/Users/jasonqin/Documents/GitHub/simple-risc/output/tangnano20k/four-trials-20261110/continuous-v2-216/lfsr/p0/impl/gwsynthesis/probe.vg"
add_file "/Users/jasonqin/Documents/GitHub/simple-risc/output/tangnano20k/four-trials-20261110/continuous-v2-216/lfsr/p3/pins.cst"
add_file "/Users/jasonqin/Documents/GitHub/simple-risc/output/tangnano20k/four-trials-20261110/continuous-v2-216/lfsr/p3/clocks.sdc"
run pnr
exit
