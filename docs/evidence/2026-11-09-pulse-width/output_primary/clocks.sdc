create_clock -name clk_27m -period 37.037037 [get_ports {clk_27m}]
create_clock -name clk_core -period 4.62962963 [get_pins {pll/pll_s2/CLKOUT}]
set_clock_groups -asynchronous -group [get_clocks {clk_27m}] -group [get_clocks {clk_core}]
report_timing -setup -from_clock [get_clocks {clk_core}] -to_clock [get_clocks {clk_core}] -max_paths 100 -max_common_paths 1
report_high_fanout_nets -max_nets 20
