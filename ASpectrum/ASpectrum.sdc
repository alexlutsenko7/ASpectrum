# ASpectrum timing constraints

create_clock -name CLOCK_50 -period 20.000 [get_ports CLOCK_50]
derive_pll_clocks
derive_clock_uncertainty

set clk     u_pll|altpll_component|auto_generated|pll1|clk[0]
set clk_sd  u_pll|altpll_component|auto_generated|pll1|clk[1]
set clk25   u_vpll|altpll_component|auto_generated|pll1|clk[0]
set clk27   u_vpll|altpll_component|auto_generated|pll1|clk[1]

#------------------------------------------------------------------------------
# SDRAM (as DDR_TEST, which passed on hardware at 112 MHz)
#------------------------------------------------------------------------------
# SDRAM clock: inverted clk_sd forwarded through the DDIO output (u_sdclk)
create_generated_clock -name sdram_clk -source [get_pins $clk_sd] -invert [get_ports DRAM_CLK]

# W9825G6KH-6 @ CL2: tIS 1.5, tIH 0.8, tAC 6.0, tOH 3.0 (ns); ~0.5 ns board skew allowance
set sdram_out [get_ports {DRAM_ADDR[*] DRAM_BA[*] DRAM_CS_N DRAM_RAS_N DRAM_CAS_N DRAM_WE_N DRAM_LDQM DRAM_UDQM DRAM_DQ[*]}]
set_output_delay -clock sdram_clk -max  2.0 $sdram_out
set_output_delay -clock sdram_clk -min -1.3 $sdram_out
set_input_delay  -clock sdram_clk -max  6.5 [get_ports {DRAM_DQ[*]}]
set_input_delay  -clock sdram_clk -min  2.5 [get_ports {DRAM_DQ[*]}]

# Read data launched by SDRAM clock edge N is captured 1.5 clk periods later
set_multicycle_path -from [get_clocks sdram_clk] -to [get_clocks $clk] -setup -end 2
set_false_path -to [get_ports DRAM_CKE]

#------------------------------------------------------------------------------
# Clock domains
#------------------------------------------------------------------------------
# The two pixel clocks reach the video logic through the clock control block, one at a time
set_clock_groups -physically_exclusive -group [get_clocks $clk25] -group [get_clocks $clk27]

# 50 MHz control, 112 MHz system and pixel clocks are asynchronous to each other:
# every crossing is synchronised (border, screen select, vsync, video mode) or a
# dual-clock block RAM (screen shadows).
set_clock_groups -asynchronous \
    -group [get_clocks CLOCK_50] \
    -group [get_clocks [list $clk $clk_sd sdram_clk]] \
    -group [get_clocks [list $clk25 $clk27]]

#------------------------------------------------------------------------------
# CPU (docs/T80_CEN_ANALYSIS.md section 4)
#------------------------------------------------------------------------------
# Everything inside cpu_t80 changes only on cen, and cen pulses are at least 4
# clocks apart (zx_bus: since == 3).
set_multicycle_path -from [get_registers {*u_bus|cpu_t80:u_cpu|*}] -to [get_registers {*u_bus|cpu_t80:u_cpu|*}] -setup 4
set_multicycle_path -from [get_registers {*u_bus|cpu_t80:u_cpu|*}] -to [get_registers {*u_bus|cpu_t80:u_cpu|*}] -hold 3

# Cycle decode (IORQ/Write, combinational in the T80) and DO, sampled by zx_bus
# 2 clocks after a cen edge into the smp_* registers
set_multicycle_path -from [get_registers {*u_bus|cpu_t80:u_cpu|*}] -to [get_registers {*u_bus|smp_*}] -setup 2
set_multicycle_path -from [get_registers {*u_bus|cpu_t80:u_cpu|*}] -to [get_registers {*u_bus|smp_*}] -hold 1

#------------------------------------------------------------------------------
# Board I/O: asynchronous or not timing-critical
#------------------------------------------------------------------------------
set_false_path -from [get_ports {RESET_N KEY1 SW_50_60 TAPE_IN TURBO_N KBD_A KBD_B GND_TIE[*] JOY_*}]
set_false_path -to   [get_ports {VGA_R VGA_R_LOW VGA_G VGA_G_LOW VGA_B VGA_B_LOW VGA_HSYNC VGA_VSYNC AUDIO_AY AUDIO_BEEPER LEDR}]

# Configuration flash (ASMI block pins): SPI at clk / 8 = 14 MHz, MOSI changes in the low
# phase and MISO is sampled at the end of the high phase (4 clocks each), by design
set_false_path -from [get_keepers {*u_asmi~ALTERA_*}]
set_false_path -to   [get_keepers {*u_asmi~ALTERA_*}]
