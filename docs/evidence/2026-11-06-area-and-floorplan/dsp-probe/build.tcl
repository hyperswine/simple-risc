set_device -name GW2AR-18C GW2AR-LV18QN88C8/I7
set_option -top_module top
set_option -output_base_name probe
set_option -gen_posp 1
add_file probe.v
add_file probe.cst
add_file probe.sdc
run all
exit
