--------------------------------------------------------------------------------
-- tb_gps_time.vhd -- testbench for gps_time (1PPS-disciplined UTC)
--
-- Checks (scaled timing, plan section 21 -- pps_tick is a pulse, no long wait):
--   1. load 12:35:19 via NMEA strobe -> outputs commit, utc_valid rises
--   2. each pps_tick advances one second (no tick -> no advance)
--   3. rollover second 59 -> 0 increments the minute; minute 59 -> 0 wraps
--   4. even_minute flags even minutes at second 0 (and only then)
--   5. a later load (13:00:01) applies immediately and even_minute clears
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_gps_time is
end entity tb_gps_time;

architecture sim of tb_gps_time is

  signal clk  : std_logic := '0';
  signal rst  : std_logic := '1';
  signal pps  : std_logic := '0';
  signal strb : std_logic := '0';
  signal hi   : natural range 0 to 23 := 0;
  signal mi   : natural range 0 to 59 := 0;
  signal si   : natural range 0 to 59 := 0;
  signal warn : std_logic := '0';
  signal v    : std_logic;
  signal hh   : natural range 0 to 23;
  signal mm   : natural range 0 to 59;
  signal ss   : natural range 0 to 59;
  signal me   : std_logic;
  signal done : boolean := false;
  signal fails: integer := 0;

begin

  dut : entity work.gps_time
    port map (clk => clk, rst => rst, pps_tick => pps,
              time_strobe => strb, hour_in => hi, minute_in => mi,
              second_in => si, fix_warning => warn, utc_valid => v,
              hour => hh, minute => mm, second => ss, minute_even => me);

  clk <= not clk after 500 ns when not done else '0';

  main : process
    procedure tick is
    begin
      pps <= '1'; wait until rising_edge(clk); pps <= '0';
      wait until rising_edge(clk);
    end procedure;
    procedure load(hh_in, mm_in, ss_in : in natural) is
    begin
      hi <= hh_in; mi <= mm_in; si <= ss_in;
      strb <= '1'; wait until rising_edge(clk); strb <= '0';
      wait until rising_edge(clk);
    end procedure;
    procedure expect(vv : in std_logic; eh, emm, es : in natural; tag : in string) is
    begin
      if v /= vv or hh /= eh or mm /= emm or ss /= es then
        report "FAIL " & tag & ": valid=" & std_logic'image(v)
               & " time " & integer'image(hh) & ":" & integer'image(mm)
               & ":" & integer'image(ss) severity error;
        fails <= fails + 1;
      end if;
    end procedure;
  begin
    rst <= '1';
    wait for 2 us;
    wait until rising_edge(clk);
    rst <= '0';
    wait for 1 us;

    -- 1. NMEA load
    load(12, 35, 19);
    expect('1', 12, 35, 19, "load");
    if me /= '0' then
      report "FAIL: minute_even high in odd minute 35" severity error;
      fails <= fails + 1;
    end if;

    -- 2. no tick -> no advance
    wait for 2 us;
    expect('1', 12, 35, 19, "no-tick hold");

    -- 3. ticks advance; rollover 59 -> 0 bumps the minute
    for i in 1 to 40 loop tick; end loop;         -- 19+40 = 59
    expect('1', 12, 35, 59, "pre-rollover");
    tick;
    expect('1', 12, 36, 0, "minute rollover");

    -- 4. minute_even flag: high for the WHOLE even minute (36, 38 ...)
    --    now at 12:36:00 -> 12:38:00 is 2*60 = 120 ticks
    if me /= '1' then
      report "FAIL: minute_even /= 1 at 12:36:00" severity error;
      fails <= fails + 1;
    end if;
    for i in 1 to 120 loop tick; end loop;
    expect('1', 12, 38, 0, "even minute");
    if me /= '1' then
      report "FAIL: minute_even /= 1 at 12:38:00" severity error;
      fails <= fails + 1;
    end if;
    tick;
    if me /= '1' then
      report "FAIL: minute_even /= 1 at second 1 of even minute" severity error;
      fails <= fails + 1;
    end if;

    -- 5. later load applies immediately
    load(13, 0, 1);
    expect('1', 13, 0, 1, "reload");   -- minute 0 is even: me stays '1'

    -- 6. minute/hour rollover: 13:59:59 -> 14:00:00
    load(13, 59, 59);
    expect('1', 13, 59, 59, "pre-hour-rollover");
    if me /= '0' then
      report "FAIL: minute_even /= 0 in odd minute 59" severity error;
      fails <= fails + 1;
    end if;
    tick;
    expect('1', 14, 0, 0, "hour rollover");
    if me /= '1' then
      report "FAIL: minute_even /= 1 at 14:00:00" severity error;
      fails <= fails + 1;
    end if;

    -- 7. fix lost: fix_warning drops utc_valid (plan section 31)
    warn <= '1'; wait until rising_edge(clk); warn <= '0';
    wait until rising_edge(clk);
    if v /= '0' then
      report "FAIL: utc_valid /= 0 after fix_warning" severity error;
      fails <= fails + 1;
    end if;
    tick;
    if v /= '0' then
      report "FAIL: utc_valid re-rose without a load" severity error;
      fails <= fails + 1;
    end if;
    load(14, 0, 2);
    expect('1', 14, 0, 2, "reload after fix loss");

    if fails = 0 then
      report "tb_gps_time: PASS - load, tick, rollovers, even_minute, reload";
    else
      report "tb_gps_time: " & integer'image(fails) & " check(s) failed"
             severity failure;
    end if;
    done <= true;
    wait;
  end process;

end architecture sim;
