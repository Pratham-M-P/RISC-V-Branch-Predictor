# -----------------------------------------------------------------------------
# build.tcl : batch Vivado flow  (synthesis -> implementation -> bitstream + reports)
#
#   vivado -mode batch -source fpga/build.tcl -tclargs [PREDICTOR_TYPE] [PROGRAM_HEX]
#
#   PREDICTOR_TYPE  0 none | 1 bimodal | 2 gshare | 3 tournament   (default 3)
#   PROGRAM_HEX     instruction image                              (default fpga/program.hex)
# Results: build/vivado/<run>/ (project), build/fpga/<tag>/ (bitstream + reports)
# Exit status is non-zero when synthesis/implementation fails or timing is not met.
# -----------------------------------------------------------------------------
set root   [file normalize [file join [file dirname [info script]] ..]]
set ptype  [expr {[llength $argv] > 0 ? [lindex $argv 0] : 3}]
set hexf   [file normalize [expr {[llength $argv] > 1 ? [lindex $argv 1] : "$root/fpga/program.hex"}]]
set part   xc7a100tcsg324-1
set tag    "p${ptype}"
set outdir [file join $root build fpga $tag]
file mkdir $outdir

if {![file exists $hexf]} { puts "ERROR: $hexf missing (run: make fpga-hex)"; exit 2 }

create_project -force bp_fpga_$tag [file join $root build vivado $tag] -part $part

# RTL, in compile order, from the shared file list
set files {}
set fh [open [file join $root rtl filelist.f] r]
while {[gets $fh line] >= 0} {
    regsub {//.*$} $line {} line
    set line [string trim $line]
    if {$line ne ""} { lappend files [file join $root $line] }
}
close $fh
add_files -norecurse $files
add_files -norecurse [file join $root fpga top_nexys_a7.sv]
set_property file_type SystemVerilog [get_files *.sv]
add_files -fileset constrs_1 -norecurse [file join $root fpga nexys_a7.xdc]
set_property top top_nexys_a7 [current_fileset]
set_property generic [list IMEM_INIT=\"$hexf\" PREDICTOR_TYPE=$ptype] [current_fileset]

set_property -name {STEPS.SYNTH_DESIGN.ARGS.MORE_OPTIONS} -value {-verbose} -objects [get_runs synth_1]

launch_runs synth_1 -jobs 4
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} { puts "ERROR: synthesis failed"; exit 1 }
open_run synth_1
report_utilization -file [file join $outdir utilization_synth.rpt]

launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} { puts "ERROR: implementation failed"; exit 1 }
open_run impl_1

report_utilization      -file [file join $outdir utilization_impl.rpt]
report_timing_summary   -file [file join $outdir timing_summary.rpt] -delay_type min_max -max_paths 10
report_power            -file [file join $outdir power.rpt]
report_clock_utilization -file [file join $outdir clocks.rpt]
file copy -force [file join $root build vivado $tag bp_fpga_$tag.runs impl_1 top_nexys_a7.bit] [file join $outdir top_nexys_a7_$tag.bit]

set wns [get_property SLACK [get_timing_paths -max_paths 1 -setup]]
set whs [get_property SLACK [get_timing_paths -max_paths 1 -hold]]
puts "=============================================================="
puts " predictor type $ptype : WNS = $wns ns, WHS = $whs ns"
puts " bitstream: [file join $outdir top_nexys_a7_$tag.bit]"
puts "=============================================================="
if {$wns < 0 || $whs < 0} { puts "ERROR: timing not met"; exit 3 }
exit 0
