# Program the Nexys A7 over JTAG:  vivado -mode batch -source fpga/program.tcl -tclargs build/fpga/p3/top_nexys_a7_p3.bit
set bit [lindex $argv 0]
open_hw_manager
connect_hw_server
open_hw_target
set dev [lindex [get_hw_devices xc7a100t_0] 0]
current_hw_device $dev
set_property PROGRAM.FILE $bit $dev
program_hw_devices $dev
refresh_hw_device $dev
puts "programmed $bit"
close_hw_manager
