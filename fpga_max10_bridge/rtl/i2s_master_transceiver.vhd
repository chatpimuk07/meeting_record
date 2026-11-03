-- =========================================================================
-- File        : i2s_master_transceiver.vhd
-- Description : Cycle-accurate 16.000 kHz I2S Master Receiver (for INMP441).
--               Uses a Bresenham fractional divider (128 half-edges per
--               3125 cycles of 50 MHz) so 64 BCLK cycles equal EXACTLY
--               3125 x 20 ns = 62.500 us (Fs = 16,000.000 Hz, 0 ppm drift).
-- =========================================================================
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity i2s_master_transceiver is
    port (
        clk_50m         : in  std_logic;
        rst_n           : in  std_logic;

        -- I2S Master Interface to INMP441 Digital Microphone
        mic_i2s_sck     : out std_logic;
        mic_i2s_ws      : out std_logic;
        mic_i2s_sd      : in  std_logic;

        -- Extracted 24-bit Signed Audio Sample (16 kHz strobe)
        rx_sample_24    : out signed(23 downto 0);
        rx_sample_valid : out std_logic;

        -- 8.000 kHz Square Wave Debug Pin (toggles every sample @ 16 kHz)
        timing_debug    : out std_logic
    );
end entity i2s_master_transceiver;

architecture rtl of i2s_master_transceiver is
    -- 50 MHz / 16 kHz = 3125 cycles per 64-bit I2S frame (128 BCLK edges)
    signal bclk_acc     : natural range 0 to 3252 := 0;
    signal bclk_reg     : std_logic := '0';
    signal ws_reg       : std_logic := '0';
    signal ws_pending   : std_logic := '0';
    signal ws_delay_cnt : natural range 0 to 3 := 0;
    signal bit_cnt      : unsigned(5 downto 0) := (others => '0');

    -- 3-stage Synchronizer + Majority Glitch Filter for MIC_I2S_SD
    signal sd_sync      : std_logic_vector(2 downto 0) := (others => '0');
    signal sd_filtered  : std_logic := '0';

    -- Receive shift register
    signal rx_shift     : signed(23 downto 0) := (others => '0');
    signal dbg_toggle   : std_logic := '0';
begin

    mic_i2s_sck  <= bclk_reg;
    mic_i2s_ws   <= ws_reg;
    timing_debug <= dbg_toggle;

    -- Majority vote across 3 consecutive 50 MHz samples (eliminates 20ns wire crosstalk spikes)
    sd_filtered <= (sd_sync(2) and sd_sync(1)) or
                   (sd_sync(1) and sd_sync(0)) or
                   (sd_sync(2) and sd_sync(0));

    process(clk_50m, rst_n)
        variable next_acc : natural range 0 to 3252;
    begin
        if rst_n = '0' then
            bclk_acc        <= 0;
            bclk_reg        <= '0';
            ws_reg          <= '0';
            ws_pending      <= '0';
            ws_delay_cnt    <= 0;
            bit_cnt         <= (others => '0');
            sd_sync         <= (others => '0');
            rx_shift        <= (others => '0');
            rx_sample_24    <= (others => '0');
            rx_sample_valid <= '0';
            dbg_toggle      <= '0';
        elsif rising_edge(clk_50m) then
            rx_sample_valid <= '0';
            sd_sync         <= sd_sync(1 downto 0) & mic_i2s_sd;

            -- Update WS 2 clock cycles (40 ns) after BCLK falling edge to guarantee
            -- INMP441 t_HWS hold time and prevent simultaneous switching bounce on jumper wires
            if ws_delay_cnt > 0 then
                if ws_delay_cnt = 1 then
                    ws_reg <= ws_pending;
                end if;
                ws_delay_cnt <= ws_delay_cnt - 1;
            end if;

            next_acc := bclk_acc + 128;
            if next_acc >= 3125 then
                bclk_acc <= next_acc - 3125;

                if bclk_reg = '0' then
                    -- Rising edge of BCLK: sample filtered MIC_I2S_SD
                    bclk_reg <= '1';

                    -- Standard I2S: Left channel bits 23..0 arrive at bit_cnt 1..24
                    if bit_cnt >= 1 and bit_cnt <= 24 then
                        rx_shift <= rx_shift(22 downto 0) & sd_filtered;
                    end if;

                    -- Latch completed 24-bit left-channel word at bit_cnt = 25
                    if bit_cnt = 25 then
                        rx_sample_24    <= rx_shift;
                        rx_sample_valid <= '1';
                        dbg_toggle      <= not dbg_toggle;
                    end if;

                else
                    -- Falling edge of BCLK: advance bit counter and schedule WS transition
                    bclk_reg <= '0';

                    if bit_cnt = 63 then
                        bit_cnt      <= (others => '0');
                        ws_pending   <= '0'; -- Left channel starts
                        ws_delay_cnt <= 2;   -- Update WS 40 ns after SCK falling edge
                    else
                        bit_cnt <= bit_cnt + 1;
                        if bit_cnt = 31 then
                            ws_pending   <= '1'; -- Right channel starts
                            ws_delay_cnt <= 2;   -- Update WS 40 ns after SCK falling edge
                        end if;
                    end if;
                end if;
            else
                bclk_acc <= next_acc;
            end if;
        end if;
    end process;

end architecture rtl;
