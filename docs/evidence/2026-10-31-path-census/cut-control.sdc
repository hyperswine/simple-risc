# What-if: the two control-signal fan-outs fixed (cpuInRom into the hold
# enable, and the cpuFast pipeline/multi-cycle select).
set_false_path -from [get_regs {core/machine_0_2076_s*}]
set_false_path -from [get_regs {core/machine_0_11015_s*}]
