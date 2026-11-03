#!/usr/bin/env bash
set -e
cd "$(dirname "$0")"

nvc --std=1993 -a \
  ../rtl/i2s_master_transceiver.vhd \
  ../rtl/audio_dsp_processor.vhd \
  ../rtl/uart_frame_tx.vhd \
  ../rtl/fpga_mic_bridge_top.vhd \
  tb_fpga_mic_bridge.vhd \
  -e tb_fpga_mic_bridge \
  -r
