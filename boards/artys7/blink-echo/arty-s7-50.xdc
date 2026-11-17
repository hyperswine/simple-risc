# Arty S7-50 pins used by top.v, from Digilent's Arty-S7-50-Master.xdc.
set_property -dict { PACKAGE_PIN F14 IOSTANDARD LVCMOS33 } [get_ports { CLK12MHZ }]
create_clock -add -name sys_clk_pin -period 83.333 -waveform {0 41.667} [get_ports { CLK12MHZ }]
set_property -dict { PACKAGE_PIN E18 IOSTANDARD LVCMOS33 } [get_ports { led[0] }]
set_property -dict { PACKAGE_PIN F13 IOSTANDARD LVCMOS33 } [get_ports { led[1] }]
set_property -dict { PACKAGE_PIN E13 IOSTANDARD LVCMOS33 } [get_ports { led[2] }]
set_property -dict { PACKAGE_PIN H15 IOSTANDARD LVCMOS33 } [get_ports { led[3] }]
set_property -dict { PACKAGE_PIN R12 IOSTANDARD LVCMOS33 } [get_ports { uart_rxd_out }]
set_property -dict { PACKAGE_PIN V12 IOSTANDARD LVCMOS33 } [get_ports { uart_txd_in }]
