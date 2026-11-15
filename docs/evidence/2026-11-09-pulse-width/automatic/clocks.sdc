create_clock -name clk_27m -period 37.037037 [get_ports {clk_27m}]
report_high_fanout_nets -max_nets 20
