create_clock -name clk_27m -period 37.037037 [get_ports {clk_27m}]
create_generated_clock -name clk_core -source [get_ports {clk_27m}] -multiply_by 27 -divide_by 9 [get_pins {pll/cpu/pll/CLKOUT}]
create_generated_clock -name clk_memory -source [get_ports {clk_27m}] -multiply_by 16 -divide_by 9 [get_pins {pll/memory/pll/CLKOUT}]
create_generated_clock -name clk_sdram -source [get_ports {clk_27m}] -multiply_by 16 -divide_by 9 -phase 135 [get_pins {pll/memory/pll/CLKOUTP}]
# Only the first metastability stages (the FIFO's Gray pointers and the read
# response toggle) are asynchronous endpoints. Payload between the domains
# retains max-delay analysis under its proven two-cycle relation instead of
# the default closest-edge check: a request slot is written a full round trip
# before it can be reused (take advances only at mem_done, then crosses a
# two-flop synchronizer), and response words are stable from the mem edge
# that writes them until the next read completes while the CPU side waits two
# flops behind the response toggle (clock_bridge.v). The exception is scoped
# by clock pair because Gowin maps the slot and replay arrays to RAM, which
# cannot take pin-scoped constraints; the two domains touch only inside the
# bridge, and the synchronizer inputs above keep their false paths. No clock
# groups or blanket cross-domain false paths conceal routing delays.
set_false_path -to [get_regs {dual_clock.bridge/put_meta_0_s0 dual_clock.bridge/put_meta_1_s0 dual_clock.bridge/put_meta_2_s0}]
set_false_path -to [get_regs {dual_clock.bridge/take_meta_0_s0 dual_clock.bridge/take_meta_1_s0 dual_clock.bridge/take_meta_2_s0}]
set_false_path -to [get_regs {dual_clock.bridge/response_meta_s0}]
set_multicycle_path -setup 2 -from [get_clocks {clk_memory}] -to [get_clocks {clk_core}]
set_multicycle_path -hold 1 -from [get_clocks {clk_memory}] -to [get_clocks {clk_core}]
set_multicycle_path -setup 2 -from [get_clocks {clk_core}] -to [get_clocks {clk_memory}]
set_multicycle_path -hold 1 -from [get_clocks {clk_core}] -to [get_clocks {clk_memory}]
