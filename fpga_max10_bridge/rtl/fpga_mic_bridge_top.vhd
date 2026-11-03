-- =========================================================================
-- File        : fpga_mic_bridge_top.vhd
-- Board       : Terasic DE10-Lite (Intel MAX 10 - 10M50DAF484C7G)
-- Description : Top-level FPGA Audio DSP Bridge (UART Mode Only)
--
--   [INMP441 Mic] --(I2S)--> [MAX 10 FPGA: DC-Block + Gain + Clip + VAD]
--                                 └──> UART 1Mbps (FPGA_UART_TX) --> ESP32 RX2
-- =========================================================================
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity fpga_mic_bridge_top is
    port (
        -- 50 MHz System Clock (PIN_P11)
        MAX10_CLK1_50    : in  std_logic;

        -- Push Buttons (Active Low: KEY[0] = Reset)
        KEY              : in  std_logic_vector(1 downto 0);

        -- Slide Switches (SW[0]=TestTone, SW[2:1]=Gain, SW[3]=NoiseGate)
        SW               : in  std_logic_vector(9 downto 0);

        -- 10 Red Onboard LEDs (LEDR[0]=VAD, LEDR[1]=Clip, LEDR[9:2]=VU Meter)
        LEDR             : out std_logic_vector(9 downto 0);

        -- 1. I2S Master Interface to INMP441 Microphone (ARDUINO_IO[0..2])
        MIC_I2S_WS       : out std_logic;
        MIC_I2S_SCK      : out std_logic;
        MIC_I2S_SD       : in  std_logic;

        -- 2. Framed 1 Mbps UART Output to ESP32 (ARDUINO_IO[7] / PIN_AA12)
        FPGA_UART_TX     : out std_logic;

        -- 3. Oscilloscope 8.000 kHz Timing Probe (ARDUINO_IO[8] / PIN_AB17)
        TIMING_DEBUG_PIN : out std_logic
    );
end entity fpga_mic_bridge_top;

architecture rtl of fpga_mic_bridge_top is
    signal rst_n           : std_logic;
    signal rx_sample_24    : signed(23 downto 0);
    signal rx_sample_valid : std_logic;

    signal dsp_pcm_16      : signed(15 downto 0);
    signal dsp_pcm_valid   : std_logic;

    signal vad_flag        : std_logic;
    signal clip_flag       : std_logic;
    signal vu_bar          : std_logic_vector(7 downto 0);
    signal uart_busy_flag  : std_logic;
begin

    rst_n <= KEY(0);

    -- =====================================================================
    -- Stage 1: Cycle-Accurate 16 kHz I2S Master Receiver (INMP441)
    -- =====================================================================
    u_i2s_rx : entity work.i2s_master_transceiver
        port map (
            clk_50m         => MAX10_CLK1_50,
            rst_n           => rst_n,
            mic_i2s_sck     => MIC_I2S_SCK,
            mic_i2s_ws      => MIC_I2S_WS,
            mic_i2s_sd      => MIC_I2S_SD,
            rx_sample_24    => rx_sample_24,
            rx_sample_valid => rx_sample_valid,
            timing_debug    => TIMING_DEBUG_PIN
        );

    -- =====================================================================
    -- Stage 2: Hardware Audio DSP Processor (DC-Blocker + Gain + VAD + VU)
    -- =====================================================================
    u_audio_dsp : entity work.audio_dsp_processor
        port map (
            clk_50m         => MAX10_CLK1_50,
            rst_n           => rst_n,
            in_sample_24    => rx_sample_24,
            in_sample_valid => rx_sample_valid,
            sw_test_tone    => SW(0),
            sw_gain_sel     => SW(2 downto 1),
            sw_noise_gate   => SW(3),
            out_pcm_16      => dsp_pcm_16,
            out_pcm_valid   => dsp_pcm_valid,
            vad_active      => vad_flag,
            clip_detected   => clip_flag,
            vu_leds         => vu_bar
        );

    -- =====================================================================
    -- Stage 3: 1 Mbps UART Packet Transmitter ([0xAA,0x55,0xAA,0x55] + 512x16b)
    -- =====================================================================
    u_uart_tx : entity work.uart_frame_tx
        generic map (
            CLK_FREQ_HZ   => 50000000,
            BAUD_RATE     => 1000000,
            FRAME_SAMPLES => 512
        )
        port map (
            clk_50m   => MAX10_CLK1_50,
            rst_n     => rst_n,
            pcm_in    => dsp_pcm_16,
            pcm_valid => dsp_pcm_valid,
            uart_tx   => FPGA_UART_TX,
            tx_busy   => uart_busy_flag
        );

    -- Onboard LEDs
    LEDR(0)          <= vad_flag;
    LEDR(1)          <= clip_flag;
    LEDR(9 downto 2) <= vu_bar;

end architecture rtl;
