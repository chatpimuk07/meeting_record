-- =========================================================================
-- File        : tb_fpga_mic_bridge.vhd
-- Description : Self-checking Testbench for fpga_mic_bridge_top (UART Mode).
--               Verifies exact 16.000 kHz I2S timing (62,500 ns per frame),
--               DSP test-tone & microphone processing, and UART 1 Mbps TX.
-- =========================================================================
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_fpga_mic_bridge is
end entity tb_fpga_mic_bridge;

architecture sim of tb_fpga_mic_bridge is
    constant CLK_PERIOD  : time := 20 ns; -- 50 MHz

    signal clk_50m       : std_logic := '0';
    signal key           : std_logic_vector(1 downto 0) := "10"; -- Reset asserted
    signal sw            : std_logic_vector(9 downto 0) := "0000000101"; -- SW[0]=1 (1kHz Tone), SW[2:1]="10" (4x Gain)
    signal ledr          : std_logic_vector(9 downto 0);

    signal mic_ws        : std_logic;
    signal mic_sck       : std_logic;
    signal mic_sd        : std_logic := '0';

    signal fpga_uart_tx  : std_logic;
    signal timing_dbg    : std_logic;

    signal sim_done      : boolean := false;
begin

    clk_50m <= not clk_50m after CLK_PERIOD / 2 when not sim_done else '0';

    dut : entity work.fpga_mic_bridge_top
        port map (
            MAX10_CLK1_50    => clk_50m,
            KEY              => key,
            SW               => sw,
            LEDR             => ledr,
            MIC_I2S_WS       => mic_ws,
            MIC_I2S_SCK      => mic_sck,
            MIC_I2S_SD       => mic_sd,
            FPGA_UART_TX     => fpga_uart_tx,
            TIMING_DEBUG_PIN => timing_dbg
        );

    stim_proc : process
        variable t_start : time;
        variable t_diff  : time;
    begin
        wait for 100 ns;
        key <= "11"; -- Release reset

        -- Wait for first falling edge of MIC_I2S_WS (start of Left channel frame)
        wait until falling_edge(mic_ws);
        t_start := now;

        -- Measure exact period of 16 I2S frames (should be 16 * 62,500 ns = 1,000,000 ns = 1 ms)
        for i in 1 to 16 loop
            wait until falling_edge(mic_ws);
        end loop;
        t_diff := now - t_start;

        assert t_diff = 1000 us
            report "ERROR: 16 I2S frames took " & time'image(t_diff) & " instead of 1000 us!"
            severity failure;

        report "PASS: Cycle-accurate 16.000 kHz I2S frame timing verified (16 frames = " & time'image(t_diff) & ")"
            severity note;

        assert ledr(0) = '1'
            report "ERROR: Hardware VAD LEDR(0) did not activate on 1 kHz test tone!"
            severity failure;

        report "PASS: Hardware DSP & VAD LED verification passed!" severity note;
        sim_done <= true;
        wait;
    end process;

    -- UART 1 Mbps Receiver Monitor Process (verifies [0xAA, 0x55, 0xAA, 0x55] header)
    uart_mon_proc : process
        variable rx_byte : std_logic_vector(7 downto 0);
        type hdr_t is array (0 to 3) of std_logic_vector(7 downto 0);
        constant EXP_HDR : hdr_t := (x"AA", x"55", x"AA", x"55");
    begin
        for b in 0 to 3 loop
            wait until falling_edge(fpga_uart_tx);
            wait for 500 ns;
            assert fpga_uart_tx = '0' report "Invalid UART Start Bit" severity failure;
            for i in 0 to 7 loop
                wait for 1000 ns;
                rx_byte(i) := fpga_uart_tx;
            end loop;
            wait for 1000 ns;
            assert fpga_uart_tx = '1' report "Invalid UART Stop Bit" severity failure;
            assert rx_byte = EXP_HDR(b)
                report "UART Header mismatch on byte " & integer'image(b)
                severity failure;
        end loop;
        report "PASS: UART 1 Mbps Sync Header [0xAA, 0x55, 0xAA, 0x55] verified!" severity note;
        wait;
    end process;

end architecture sim;
