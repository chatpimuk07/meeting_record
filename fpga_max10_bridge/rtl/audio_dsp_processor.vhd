-- =========================================================================
-- File        : audio_dsp_processor.vhd
-- Description : Hardware Audio DSP Pipeline on MAX 10 FPGA:
--               1. 1st-Order IIR DC-Offset Blocker (High-Pass Filter)
--               2. Configurable Digital Gain (1x, 2x, 4x, 8x via SW[2:1])
--               3. Hardware Saturation / Clipping Protection (-32768..+32767)
--               4. Optional 1 kHz Exact Sine LUT Test Generator (via SW[0])
--               5. Hardware Voice Activity Detection (VAD) & 8-LED VU Meter
-- =========================================================================
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity audio_dsp_processor is
    port (
        clk_50m         : in  std_logic;
        rst_n           : in  std_logic;

        -- 24-bit Raw Sample Input from I2S Receiver
        in_sample_24    : in  signed(23 downto 0);
        in_sample_valid : in  std_logic;

        -- User Controls (DE10-Lite Slide Switches)
        sw_test_tone    : in  std_logic;                    -- SW[0]: 1 = 1 kHz Sine Test Tone, 0 = Mic
        sw_gain_sel     : in  std_logic_vector(1 downto 0); -- SW[2:1]: 00=1x, 01=2x, 10=4x, 11=8x
        sw_noise_gate   : in  std_logic;                    -- SW[3]: 1 = Enable soft noise gate

        -- 16-bit Processed PCM Output
        out_pcm_16      : out signed(15 downto 0);
        out_pcm_valid   : out std_logic;

        -- Status & Visual Indicators (DE10-Lite LEDs)
        vad_active      : out std_logic;
        clip_detected   : out std_logic;
        vu_leds         : out std_logic_vector(7 downto 0)
    );
end entity audio_dsp_processor;

architecture rtl of audio_dsp_processor is
    -- 16-point exact 1 kHz Sine Lookup Table at Fs = 16 kHz (amplitude = 12000)
    type sine_lut_t is array (0 to 15) of integer range -16384 to 16383;
    constant SINE_1KHZ_LUT : sine_lut_t := (
            0,  4592,  8485, 11087,
        12000, 11087,  8485,  4592,
            0, -4592, -8485,-11087,
       -12000,-11087, -8485, -4592
    );

    signal phase_idx    : unsigned(3 downto 0) := (others => '0');

    -- DC-Blocker state: tracks DC mean in 32-bit fixed-point (24.8 format)
    signal dc_acc       : signed(31 downto 0) := (others => '0');

    -- 3-Tap Median Filter & 4-Tap Moving Average LPF state for I2S glitch/noise rejection
    signal med_z1       : signed(23 downto 0) := (others => '0');
    signal med_z2       : signed(23 downto 0) := (others => '0');
    signal lpf_z1       : signed(15 downto 0) := (others => '0');
    signal lpf_z2       : signed(15 downto 0) := (others => '0');
    signal lpf_z3       : signed(15 downto 0) := (others => '0');

    -- Envelope detector for VAD & VU meter
    signal env_level    : unsigned(15 downto 0) := (others => '0');
    signal decay_cnt    : unsigned(8 downto 0) := (others => '0');
begin

    process(clk_50m, rst_n)
        variable s_clean     : signed(23 downto 0);
        variable a, b, c     : signed(23 downto 0);
        variable med_val     : signed(23 downto 0);
        variable dc_est      : signed(23 downto 0);
        variable diff_24     : signed(24 downto 0);
        variable dc_step     : signed(24 downto 0);
        variable scaled_val  : signed(24 downto 0);
        variable sat_16      : signed(15 downto 0);
        variable lpf_sum     : signed(17 downto 0);
        variable final_16    : signed(15 downto 0);
        variable abs_val     : unsigned(15 downto 0);
        variable is_clipped  : std_logic;
    begin
        if rst_n = '0' then
            phase_idx     <= (others => '0');
            dc_acc        <= (others => '0');
            med_z1        <= (others => '0');
            med_z2        <= (others => '0');
            lpf_z1        <= (others => '0');
            lpf_z2        <= (others => '0');
            lpf_z3        <= (others => '0');
            out_pcm_16    <= (others => '0');
            out_pcm_valid <= '0';
            env_level     <= (others => '0');
            decay_cnt     <= (others => '0');
            vad_active    <= '0';
            clip_detected <= '0';
        elsif rising_edge(clk_50m) then
            out_pcm_valid <= '0';

            if in_sample_valid = '1' then
                -- 1. Advance 1 kHz DDS phase counter
                phase_idx <= phase_idx + 1;

                if sw_test_tone = '1' then
                    -- Internal 1.000 kHz exact reference sine wave
                    final_16   := to_signed(SINE_1KHZ_LUT(to_integer(phase_idx)), 16);
                    is_clipped := '0';
                else
                    -- 2. Sign-extend from bit 18 (rejects MSB High-Z wakeup/bit-slip glitches)
                    --    and apply 3-tap Median Filter to strip single-sample I2S bit errors
                    s_clean := resize(in_sample_24(18 downto 0), 24);
                    a       := s_clean;
                    b       := med_z1;
                    c       := med_z2;
                    med_z2  <= med_z1;
                    med_z1  <= s_clean;

                    if (a >= b and a <= c) or (a >= c and a <= b) then
                        med_val := a;
                    elsif (b >= a and b <= c) or (b >= c and b <= a) then
                        med_val := b;
                    else
                        med_val := c;
                    end if;

                    -- 3. Slew-Rate-Clamped IIR DC-Offset Removal (prevents DC windup on spikes)
                    dc_est  := dc_acc(31 downto 8);
                    diff_24 := resize(med_val, 25) - resize(dc_est, 25);
                    if diff_24 > to_signed(1024, 25) then
                        dc_step := to_signed(1024, 25);
                    elsif diff_24 < to_signed(-1024, 25) then
                        dc_step := to_signed(-1024, 25);
                    else
                        dc_step := diff_24;
                    end if;
                    dc_acc <= dc_acc + resize(dc_step, 32);

                    -- 4. Selectable Digital Gain (shifting 24-bit AC signal to 16-bit target)
                    case sw_gain_sel is
                        when "00"   => scaled_val := shift_right(diff_24, 6); -- 1x (same as >>14 on 32b I2S)
                        when "01"   => scaled_val := shift_right(diff_24, 5); -- 2x
                        when "10"   => scaled_val := shift_right(diff_24, 4); -- 4x (recommended for speech)
                        when others => scaled_val := shift_right(diff_24, 3); -- 8x (high sensitivity)
                    end case;

                    -- 5. Hardware Saturation (Clipping Protection)
                    if scaled_val > to_signed(32767, 25) then
                        sat_16     := to_signed(32767, 16);
                        is_clipped := '1';
                    elsif scaled_val < to_signed(-32768, 25) then
                        sat_16     := to_signed(-32768, 16);
                        is_clipped := '1';
                    else
                        sat_16     := resize(scaled_val, 16);
                        is_clipped := '0';
                    end if;

                    -- 6. 4-Tap Moving-Average Low-Pass Filter (attenuates >3.5 kHz I2S/Sigma-Delta hiss)
                    lpf_sum  := resize(sat_16, 18) + resize(lpf_z1, 18) + resize(lpf_z2, 18) + resize(lpf_z3, 18);
                    lpf_z3   <= lpf_z2;
                    lpf_z2   <= lpf_z1;
                    lpf_z1   <= sat_16;
                    final_16 := resize(shift_right(lpf_sum, 2), 16);

                    -- 7. Optional Soft Noise Gate (attenuates low-level background hiss when SW[3]='1')
                    if sw_noise_gate = '1' then
                        if final_16 > -180 and final_16 < 180 then
                            final_16 := shift_right(final_16, 2);
                        end if;
                    end if;
                end if;

                out_pcm_16    <= final_16;
                out_pcm_valid <= '1';
                clip_detected <= is_clipped;

                -- 8. Envelope Follower for Hardware VAD & LED VU Meter
                if final_16 < 0 then
                    if final_16 = to_signed(-32768, 16) then
                        abs_val := to_unsigned(32767, 16);
                    else
                        abs_val := unsigned(-final_16);
                    end if;
                else
                    abs_val := unsigned(final_16);
                end if;

                if abs_val > env_level then
                    env_level <= abs_val;
                else
                    decay_cnt <= decay_cnt + 1;
                    if decay_cnt = 0 and env_level > 32 then
                        env_level <= env_level - shift_right(env_level, 4);
                    end if;
                end if;

                -- Hardware VAD threshold (~1200 out of 32768)
                if env_level > 1200 then
                    vad_active <= '1';
                else
                    vad_active <= '0';
                end if;
            end if;
        end if;
    end process;

    -- 8-Stage VU Meter for LEDR[9:2] (VHDL-1993 compatible concurrent assignments)
    vu_leds(0) <= '1' when env_level >   250 else '0';
    vu_leds(1) <= '1' when env_level >   600 else '0';
    vu_leds(2) <= '1' when env_level >  1200 else '0';
    vu_leds(3) <= '1' when env_level >  2500 else '0';
    vu_leds(4) <= '1' when env_level >  5000 else '0';
    vu_leds(5) <= '1' when env_level > 10000 else '0';
    vu_leds(6) <= '1' when env_level > 18000 else '0';
    vu_leds(7) <= '1' when env_level > 28000 else '0';

end architecture rtl;
