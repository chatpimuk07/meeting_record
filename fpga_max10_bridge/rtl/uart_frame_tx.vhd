-- =========================================================================
-- File        : uart_frame_tx.vhd
-- Description : 1,000,000 Baud (1 Mbps, 8N1) Framed Audio Transmitter.
--               50 MHz / 1,000,000 = 50 clock cycles per bit (exact 0% error).
--               Every 512 samples, prepends the 4-byte Sync Header:
--                 [0xAA, 0x55, 0xAA, 0x55] + 512 x int16_t (Little-Endian)
--               Worst-case burst (4B header + 2B sample = 60 bits) takes
--               60 us < 62.5 us (16 kHz sample period), so it never overflows!
-- =========================================================================
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity uart_frame_tx is
    generic (
        CLK_FREQ_HZ  : positive := 50000000;
        BAUD_RATE    : positive := 1000000;
        FRAME_SAMPLES: positive := 512
    );
    port (
        clk_50m      : in  std_logic;
        rst_n        : in  std_logic;
        pcm_in       : in  signed(15 downto 0);
        pcm_valid    : in  std_logic;
        uart_tx      : out std_logic;
        tx_busy      : out std_logic
    );
end entity uart_frame_tx;

architecture rtl of uart_frame_tx is
    constant CLKS_PER_BIT : positive := CLK_FREQ_HZ / BAUD_RATE; -- 50 cycles

    type tx_buf_t is array (0 to 5) of std_logic_vector(7 downto 0);
    signal tx_queue       : tx_buf_t := (others => (others => '0'));
    signal bytes_to_send  : natural range 0 to 6 := 0;
    signal byte_idx       : natural range 0 to 5 := 0;

    signal sample_cnt     : natural range 0 to FRAME_SAMPLES - 1 := 0;
    signal bit_timer      : natural range 0 to CLKS_PER_BIT - 1 := 0;
    signal bit_pos        : natural range 0 to 9 := 0;
    signal shift_frame    : std_logic_vector(9 downto 0) := (others => '1');
    signal active         : std_logic := '0';
begin

    tx_busy <= active;

    process(clk_50m, rst_n)
    begin
        if rst_n = '0' then
            tx_queue      <= (others => (others => '0'));
            bytes_to_send <= 0;
            byte_idx      <= 0;
            sample_cnt    <= 0;
            bit_timer     <= 0;
            bit_pos       <= 0;
            shift_frame   <= (others => '1');
            active        <= '0';
            uart_tx       <= '1';
        elsif rising_edge(clk_50m) then
            if pcm_valid = '1' and active = '0' then
                if sample_cnt = 0 then
                    -- Start of 512-sample frame: send [0xAA, 0x55, 0xAA, 0x55, LSB, MSB]
                    tx_queue(0)   <= x"AA";
                    tx_queue(1)   <= x"55";
                    tx_queue(2)   <= x"AA";
                    tx_queue(3)   <= x"55";
                    tx_queue(4)   <= std_logic_vector(pcm_in(7 downto 0));
                    tx_queue(5)   <= std_logic_vector(pcm_in(15 downto 8));
                    bytes_to_send <= 6;
                    shift_frame   <= '1' & x"AA" & '0'; -- Stop(1), Data(8), Start(0)
                else
                    -- Subsequent sample: send [LSB, MSB]
                    tx_queue(0)   <= std_logic_vector(pcm_in(7 downto 0));
                    tx_queue(1)   <= std_logic_vector(pcm_in(15 downto 8));
                    bytes_to_send <= 2;
                    shift_frame   <= '1' & std_logic_vector(pcm_in(7 downto 0)) & '0';
                end if;

                if sample_cnt = FRAME_SAMPLES - 1 then
                    sample_cnt <= 0;
                else
                    sample_cnt <= sample_cnt + 1;
                end if;

                byte_idx  <= 0;
                bit_pos   <= 0;
                bit_timer <= 0;
                active    <= '1';
                uart_tx   <= '0'; -- Start bit immediately

            elsif active = '1' then
                if bit_timer < CLKS_PER_BIT - 1 then
                    bit_timer <= bit_timer + 1;
                else
                    bit_timer <= 0;
                    if bit_pos < 9 then
                        bit_pos <= bit_pos + 1;
                        uart_tx <= shift_frame(bit_pos + 1);
                    else
                        bit_pos <= 0;
                        if byte_idx + 1 < bytes_to_send then
                            byte_idx    <= byte_idx + 1;
                            shift_frame <= '1' & tx_queue(byte_idx + 1) & '0';
                            uart_tx     <= '0'; -- Next start bit
                        else
                            active  <= '0';
                            uart_tx <= '1';     -- Return to idle high
                        end if;
                    end if;
                end if;
            else
                uart_tx <= '1';
            end if;
        end if;
    end process;

end architecture rtl;
