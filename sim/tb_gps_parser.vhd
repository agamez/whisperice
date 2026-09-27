--------------------------------------------------------------------------------
-- tb_gps_parser.vhd -- testbench for gps_parser (byte-level, plan section 21)
--
-- Reference sentence (checksum 6A verified independently in python):
--   $GPRMC,123519,A,4807.038,N,01131.000,E,022.4,084.4,230394,003.1,W*6A
--
-- Checks:
--   1. good sentence  -> time_strobe, 12:35:19, fix_valid='1'
--   2. corrupt checksum (6B) -> sentence_error, outputs RETAINED (plan 31)
--   3. status 'V' sentence (correct checksum 77) -> rejected, outputs retained
--   4. second good sentence (013030, checksum 66) -> commits 01:30:30
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_gps_parser is
end entity tb_gps_parser;

architecture sim of tb_gps_parser is

  signal clk   : std_logic := '0';
  signal rst   : std_logic := '1';
  signal data  : std_logic_vector(7 downto 0) := (others => '0');
  signal dv    : std_logic := '0';
  signal strobe: std_logic;
  signal h     : natural range 0 to 23;
  signal m     : natural range 0 to 59;
  signal s     : natural range 0 to 59;
  signal fv    : std_logic;
  signal serr  : std_logic;
  signal warn  : std_logic;
  signal done  : boolean := false;
  signal fails : integer := 0;
  signal strobes : integer := 0;
  signal errs    : integer := 0;
  signal warns   : integer := 0;

begin

  dut : entity work.gps_parser
    port map (clk => clk, rst => rst, data => data, data_valid => dv,
              time_strobe => strobe, hour => h, minute => m, second => s,
              fix_valid => fv, sentence_error => serr, fix_warning => warn);

  clk <= not clk after 500 ns when not done else '0';

  count : process (clk)
  begin
    if rising_edge(clk) then
      if strobe = '1' then strobes <= strobes + 1; end if;
      if serr = '1' then errs <= errs + 1; end if;
      if warn = '1' then warns <= warns + 1; end if;
    end if;
  end process;

  main : process
    procedure send(ch : in character) is
    begin
      data <= std_logic_vector(to_unsigned(character'pos(ch), 8));
      wait until rising_edge(clk);
      dv <= '1';
      wait until rising_edge(clk);
      dv <= '0';
      wait until rising_edge(clk);
    end procedure;
    procedure send_str(str : in string) is
    begin
      for i in str'range loop
        send(str(i));
      end loop;
    end procedure;
    procedure check_time(eh, em, es : in natural; tag : in string) is
    begin
      if h /= eh or m /= em or s /= es then
        report "FAIL " & tag & ": time " & integer'image(h) & ":"
               & integer'image(m) & ":" & integer'image(s)
               & " expected " & integer'image(eh) & ":" & integer'image(em)
               & ":" & integer'image(es) severity error;
        fails <= fails + 1;
      end if;
    end procedure;
  begin
    rst <= '1';
    wait for 2 us;
    wait until rising_edge(clk);
    rst <= '0';
    wait for 1 us;

    -- 1. good sentence
    send_str("$GPRMC,123519,A,4807.038,N,01131.000,E,022.4,084.4,230394,003.1,W*6A");
    send(CR); send(LF);
    wait for 3 us;
    if strobes /= 1 then
      report "FAIL: strobe count " & integer'image(strobes) & " /= 1 after good"
             severity error;
      fails <= fails + 1;
    end if;
    check_time(12, 35, 19, "good sentence");
    if fv /= '1' then
      report "FAIL: fix_valid /= 1 after good sentence" severity error;
      fails <= fails + 1;
    end if;

    -- 2. corrupt checksum -> rejected, retained
    send_str("$GPRMC,123519,A,4807.038,N,01131.000,E,022.4,084.4,230394,003.1,W*6B");
    send(CR); send(LF);
    wait for 3 us;
    if errs /= 1 then
      report "FAIL: sentence_error count " & integer'image(errs)
             & " /= 1 after corrupt" severity error;
      fails <= fails + 1;
    end if;
    if strobes /= 1 then
      report "FAIL: corrupt sentence committed (strobe count "
             & integer'image(strobes) & ")" severity error;
      fails <= fails + 1;
    end if;
    check_time(12, 35, 19, "corrupt retained");
    if fv /= '1' then
      report "FAIL: fix_valid lost after corrupt sentence" severity error;
      fails <= fails + 1;
    end if;

    -- 3. status V (valid checksum 77) -> NOT committed as valid time, but
    --    fix_warning pulses (the fix is lost -- plan section 31)
    send_str("$GPRMC,123520,V,4807.038,N,01131.000,E,022.4,084.4,230394,003.1,W*77");
    send(CR); send(LF);
    wait for 3 us;
    if strobes /= 1 then
      report "FAIL: V-status committed (strobe count "
             & integer'image(strobes) & ")" severity error;
      fails <= fails + 1;
    end if;
    if warns /= 1 then
      report "FAIL: fix_warning count " & integer'image(warns)
             & " /= 1 after V sentence" severity error;
      fails <= fails + 1;
    end if;
    check_time(12, 35, 19, "V-status retained");

    -- 4. second good sentence -> commits 01:30:30
    send_str("$GPRMC,013030,A,4807.038,N,01131.000,E,022.4,084.4,230394,003.1,W*66");
    send(CR); send(LF);
    wait for 3 us;
    if strobes /= 2 then
      report "FAIL: strobe count " & integer'image(strobes)
             & " /= 2 after second good" severity error;
      fails <= fails + 1;
    end if;
    check_time(1, 30, 30, "second good sentence");
    if fv /= '1' then
      report "FAIL: fix_valid /= 1 after second good sentence" severity error;
      fails <= fails + 1;
    end if;

    if fails = 0 then
      report "tb_gps_parser: PASS - good commit, corrupt retained, V rejected,"
             & " second commit";
    else
      report "tb_gps_parser: " & integer'image(fails) & " check(s) failed"
             severity failure;
    end if;
    done <= true;
    wait;
  end process;

end architecture sim;
