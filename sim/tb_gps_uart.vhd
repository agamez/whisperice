--------------------------------------------------------------------------------
-- tb_gps_uart.vhd -- testbench for gps_uart (scaled CLOCK_HZ, plan section 21)
--
-- Drives a serialized byte stream at a scaled clock (1 MHz, 9600 baud ->
-- 104 cycles/bit) and checks: received bytes, LSB-first order, framing-error
-- detection (low stop bit), and idle-high behavior between frames.
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_gps_uart is
end entity tb_gps_uart;

architecture sim of tb_gps_uart is

  constant CLOCK_HZ  : positive := 1000000;
  constant BAUD      : positive := 9600;
  constant BIT_NS    : real := 1.0e9 / real(BAUD);  -- ~104166 ns -- use integer us below
  constant BIT_PERIOD : time := 104 us;   -- 1 MHz clock: 104 cycles per bit

  signal clk   : std_logic := '0';
  signal rst   : std_logic := '1';
  signal rx    : std_logic := '1';
  signal data  : std_logic_vector(7 downto 0);
  signal dv    : std_logic;
  signal ferr  : std_logic;
  signal ovrr  : std_logic;
  signal done  : boolean := false;
  signal fails : integer := 0;        -- checker-side failures
  signal m_fails : integer := 0;      -- main-side failures
  signal dv_count : integer := 0;

  -- sends one byte LSB first, 8N1
  procedure send_byte(byte : in std_logic_vector(7 downto 0);
                      signal rx_line : out std_logic) is
  begin
    rx_line <= '0';                          -- start bit
    wait for BIT_PERIOD;
    for i in 0 to 7 loop
      rx_line <= byte(i);
      wait for BIT_PERIOD;
    end loop;
    rx_line <= '1';                          -- stop bit
    wait for BIT_PERIOD;
  end procedure;

begin

  dut : entity work.gps_uart
    generic map (CLOCK_HZ => CLOCK_HZ, BAUD_RATE => BAUD)
    port map (clk => clk, rst => rst, rx => rx, data => data,
              data_valid => dv, framing_error => ferr, overrun => ovrr);

  clk <= not clk after 500 ns when not done else '0';

  -- count every data_valid pulse: exactly 3 must occur ('A','b','Z'); the
  -- framing-error byte must be discarded without a data_valid.
  dv_counter : process (clk)
  begin
    if rising_edge(clk) then
      if dv = '1' then
        dv_count <= dv_count + 1;
      end if;
    end if;
  end process;

  -- byte checker: on each data_valid, compare with the expected queue
  checker : process
    variable expect : integer := 0;
  begin
    wait until rst = '0';
    -- expected: "A" (16#41#), "b" (16#62#), then framing-error byte is
    -- discarded (no valid), then "Z" (16#5A#)
    for step in 0 to 2 loop
      wait until dv = '1';
      case step is
        when 0 =>
          if data /= x"41" then
            report "FAIL: byte 0 " & integer'image(to_integer(unsigned(data)))
                   & " /= 65" severity error;
            fails <= fails + 1;
          end if;
        when 1 =>
          if data /= x"62" then
            report "FAIL: byte 1 " & integer'image(to_integer(unsigned(data)))
                   & " /= 98" severity error;
            fails <= fails + 1;
          end if;
        when 2 =>
          if data /= x"5A" then
            report "FAIL: byte 2 " & integer'image(to_integer(unsigned(data)))
                   & " /= 90" severity error;
            fails <= fails + 1;
          end if;
        when others => null;
      end case;
      expect := expect + 1;
    end loop;
    if fails = 0 then
      report "tb_gps_uart: bytes received correctly (3/3)";
    else
      report "tb_gps_uart: " & integer'image(fails) & " byte check(s) failed"
             severity error;
    end if;
    wait;                                  -- done is driven by main only
  end process;

  main : process
  begin
    rst <= '1';
    wait for 4 us;
    wait until rising_edge(clk);
    rst <= '0';
    wait for 2 us;

    -- byte 'A' = 0x41 = 01000001
    send_byte(x"41", rx);
    wait for 200 us;

    -- byte 'b' = 0x62 = 01100010
    send_byte(x"62", rx);
    wait for 200 us;

    -- framing error: start + 8 low-ish bits + LOW stop bit
    rx <= '0'; wait for BIT_PERIOD;          -- start
    rx <= '1'; wait for BIT_PERIOD;          -- b0
    rx <= '0'; wait for BIT_PERIOD;          -- b1
    rx <= '1'; wait for BIT_PERIOD;          -- b2
    rx <= '0'; wait for BIT_PERIOD;          -- b3
    rx <= '1'; wait for BIT_PERIOD;          -- b4
    rx <= '0'; wait for BIT_PERIOD;          -- b5
    rx <= '1'; wait for BIT_PERIOD;          -- b6
    rx <= '0'; wait for BIT_PERIOD;          -- b7
    rx <= '0'; wait for BIT_PERIOD;          -- STOP LOW -> framing error
    rx <= '1';                               -- line returns to idle high
    wait for 200 us;

    -- byte 'Z' = 0x5A = 01011010
    send_byte(x"5A", rx);
    wait for 200 us;

    wait for 200 us;
    -- framing check: exactly 3 data_valid pulses total
    if dv_count /= 3 then
      report "FAIL: data_valid count " & integer'image(dv_count)
             & " /= 3 (framing-error byte not discarded?)" severity error;
      m_fails <= m_fails + 1;
    end if;
    if fails + m_fails = 0 then
      report "tb_gps_uart: PASS - bytes + framing discard verified";
    else
      report "tb_gps_uart: " & integer'image(fails + m_fails)
             & " check(s) failed" severity failure;
    end if;
    done <= true;
    wait;
  end process;

end architecture sim;
