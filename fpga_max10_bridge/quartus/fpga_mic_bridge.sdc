# =========================================================================
# Synopsys Design Constraints (SDC) for MAX 10 (10M50DAF484C7G)
# 50.000 MHz System Clock (20.000 ns period)
# =========================================================================
create_clock -name {MAX10_CLK1_50} -period 20.000 -waveform { 0.000 10.000 } [get_ports {MAX10_CLK1_50}]
derive_clock_uncertainty

set_false_path -from [get_ports {KEY[*] SW[*] MIC_I2S_SD}]
set_false_path -to   [get_ports {LEDR[*] MIC_I2S_WS MIC_I2S_SCK FPGA_UART_TX TIMING_DEBUG_PIN}]
