--------------------------------------------------------------------------------
-- tb_pps_measure.vhd -- functional test for src/gps/pps_measure.vhd
--
-- Phase 2 testbench (plan section 29 Rule 3: a functional test must exist;
-- plan section 21: scale the test parameters, never the logic).
--
-- WHAT IT CHECKS
-- --------------
-- The DUT is driven with PPS edges every PPS_PERIOD_CYCLES clock cycles, with
-- a deliberately LONG high level (PULSE_WIDTH_CYCLES, and one even longer
-- LONG_PULSE_WIDTH_CYCLES -- the real PmodGPS pulse is ~100 ms wide, plan
-- section 3.2).  It asserts that:
--
--   1. pps_tick is a single-clock-cycle pulse for every rising edge, and that
--      the long high level / falling edge produce no extra pulse;
--   2. the measured interval equals PPS_PERIOD_CYCLES exactly for every PPS
--      after the first reference edge;
--   3. measurement_valid is '0' until the first full interval completes and
--      '1' afterwards;
--   4. after PPS stops, measurement_valid clears within the timeout window
--      (plan section 31: "PPS disappears -> invalidate calibration").
--
-- The timebase is scaled: the real clock is 12 MHz and the real interval is
-- 12,000,000 cycles; here the interval is PPS_PERIOD_CYCLES and the timeout is
-- TIMEOUT_CYCLES.  The RTL logic is identical.
--
-- VHDL-93 ONLY (IEEE Std 1076-1993): explicit sensitivity lists, no
-- process(all), no std.env.  Analyse with --std=93.
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_pps_measure is
  generic (
    CLK_PERIOD              : time     := 10 ns;
    PPS_PERIOD_CYCLES       : positive := 1000;  -- scaled GPS second
    PULSE_WIDTH_CYCLES      : positive := 100;   -- scaled ~100 ms (10 % duty)
    LONG_PULSE_WIDTH_CYCLES : positive := 500;   -- 50 % duty: still one edge
    NUM_PPS_PULSES          : positive := 4;
    TIMEOUT_CYCLES          : positive := 5000;  -- scaled PPS-loss timeout
    TOTAL_CYCLES            : positive := 11000
  );
end entity tb_pps_measure;

architecture sim of tb_pps_measure is

  constant COUNT_WIDTH : positive := 25;

  signal clk       : std_logic := '0';
  signal rst       : std_logic := '1';
  signal pps_in    : std_logic := '0';
  signal pps_tick  : std_logic;
  signal measured  : std_logic_vector(COUNT_WIDTH - 1 downto 0);
  signal mvalid    : std_logic;

begin

  ----------------------------------------------------------------------------
  -- DUT
  ----------------------------------------------------------------------------
  dut : entity work.pps_measure
    generic map (
      COUNT_WIDTH    => COUNT_WIDTH,
      TIMEOUT_CYCLES => TIMEOUT_CYCLES
    )
    port map (
      clk                        => clk,
      rst                        => rst,
      pps_in                     => pps_in,
      pps_tick                   => pps_tick,
      measured_cycles_per_second => measured,
      measurement_valid          => mvalid
    );

  ----------------------------------------------------------------------------
  -- Clock.  Finite so the simulation ends on its own.
  ----------------------------------------------------------------------------
  p_clk : process is
  begin
    clk <= '0';
    for i in 0 to TOTAL_CYCLES + 50 loop
      wait for CLK_PERIOD / 2;
      clk <= '1';
      wait for CLK_PERIOD / 2;
      clk <= '0';
    end loop;
    wait;
  end process p_clk;

  ----------------------------------------------------------------------------
  -- Stimulus: reset, then NUM_PPS_PULSES PPS periods, then silence.
  --
  -- Every PPS rise is aligned to a rising clock edge, and every period is
  -- exactly PPS_PERIOD_CYCLES long, so the true edge-to-edge interval is
  -- exactly PPS_PERIOD_CYCLES clock cycles.
  ----------------------------------------------------------------------------
  p_stimulus : process is
  begin
    rst    <= '1';
    pps_in <= '0';

    for i in 1 to 5 loop
      wait until rising_edge(clk);
    end loop;
    rst <= '0';

    -- Two representative 10 %-duty pulses (a scaled ~100 ms PPS).
    for i in 0 to 1 loop
      pps_in <= '1';
      for j in 1 to PULSE_WIDTH_CYCLES loop
        wait until rising_edge(clk);
      end loop;
      pps_in <= '0';
      for j in 1 to (PPS_PERIOD_CYCLES - PULSE_WIDTH_CYCLES) loop
        wait until rising_edge(clk);
      end loop;
    end loop;

    -- One deliberately long pulse (50 % duty): must still be a single edge.
    pps_in <= '1';
    for j in 1 to LONG_PULSE_WIDTH_CYCLES loop
      wait until rising_edge(clk);
    end loop;
    pps_in <= '0';
    for j in 1 to (PPS_PERIOD_CYCLES - LONG_PULSE_WIDTH_CYCLES) loop
      wait until rising_edge(clk);
    end loop;

    -- One final representative pulse.
    pps_in <= '1';
    for j in 1 to PULSE_WIDTH_CYCLES loop
      wait until rising_edge(clk);
    end loop;
    pps_in <= '0';
    for j in 1 to (PPS_PERIOD_CYCLES - PULSE_WIDTH_CYCLES) loop
      wait until rising_edge(clk);
    end loop;

    -- PPS disappears.  Sit quiet long enough for the timeout to fire.
    for j in 1 to TIMEOUT_CYCLES + 50 loop
      wait until rising_edge(clk);
    end loop;
    wait;
  end process p_stimulus;

  ----------------------------------------------------------------------------
  -- Checker.
  ----------------------------------------------------------------------------
  p_check : process is
    variable prev_tick        : std_logic := '0';
    variable prev_valid       : std_logic := '0';
    variable cycle_since_tick : natural := 0;
    variable tick_count       : natural := 0;
    variable high_run         : natural := 0;   -- consecutive pps_tick cycles
    variable check_pending    : boolean := false;
    variable check_tick_num   : natural := 0;
    variable timeout_seen     : boolean := false;
    variable valid_rose       : boolean := false;
  begin
    wait until rising_edge(clk);

    for i in 1 to TOTAL_CYCLES loop

      cycle_since_tick := cycle_since_tick + 1;

      -- (1) pps_tick must never be high for more than one clock cycle.
      if pps_tick = '1' then
        high_run := high_run + 1;
      else
        if high_run > 0 then
          assert high_run = 1
            report "tb_pps_measure: pps_tick was high for " &
                   integer'image(high_run) & " consecutive cycles (expected 1)"
            severity failure;
        end if;
        high_run := 0;
      end if;

      -- (2) Handle the check for a tick seen on the previous edge: the
      --     DUT's registered outputs (measured, valid) are updated by now.
      if check_pending then
        if check_tick_num >= 2 then
          assert to_integer(unsigned(measured)) = PPS_PERIOD_CYCLES
            report "tb_pps_measure: tick " & integer'image(check_tick_num) &
                   ": measured = " & integer'image(to_integer(unsigned(measured))) &
                   ", expected " & integer'image(PPS_PERIOD_CYCLES)
            severity failure;
          assert mvalid = '1'
            report "tb_pps_measure: tick " & integer'image(check_tick_num) &
                   ": measurement_valid not asserted after a full interval"
            severity failure;
          valid_rose := true;
        else
          assert mvalid = '0'
            report "tb_pps_measure: measurement_valid asserted before a full " &
                   "interval was measured"
            severity failure;
        end if;
        check_pending := false;
      end if;

      -- (3) Detect a new pps_tick and check the interval it closes.
      if (pps_tick = '1') and (prev_tick = '0') then
        tick_count := tick_count + 1;
        if tick_count > 1 then
          assert cycle_since_tick = PPS_PERIOD_CYCLES
            report "tb_pps_measure: interval between ticks " &
                   integer'image(tick_count - 1) & " and " &
                   integer'image(tick_count) & " = " &
                   integer'image(cycle_since_tick) & " cycles, expected " &
                   integer'image(PPS_PERIOD_CYCLES)
            severity failure;
        end if;
        check_tick_num := tick_count;
        check_pending  := true;
        cycle_since_tick := 0;
      end if;

      -- (4) Validity must clear within the timeout after PPS stops.
      if (mvalid = '0') and (prev_valid = '1') then
        assert (cycle_since_tick >= TIMEOUT_CYCLES) and
               (cycle_since_tick <= TIMEOUT_CYCLES + 4)
          report "tb_pps_measure: measurement_valid cleared " &
                 integer'image(cycle_since_tick) &
                 " cycles after the last tick, expected ~" &
                 integer'image(TIMEOUT_CYCLES)
          severity failure;
        timeout_seen := true;
      end if;

      prev_tick  := pps_tick;
      prev_valid := mvalid;

      wait until rising_edge(clk);
    end loop;

    assert tick_count = NUM_PPS_PULSES
      report "tb_pps_measure: observed " & integer'image(tick_count) &
             " PPS ticks, expected " & integer'image(NUM_PPS_PULSES)
      severity failure;
    assert valid_rose
      report "tb_pps_measure: measurement_valid never became '1'"
      severity failure;
    assert timeout_seen
      report "tb_pps_measure: measurement_valid never cleared after PPS stopped"
      severity failure;

    report "tb_pps_measure: PASS - " & integer'image(tick_count) &
           " single-cycle ticks, interval " &
           integer'image(PPS_PERIOD_CYCLES) &
           " cycles measured exactly, validity cleared after timeout"
      severity note;

    wait;
  end process p_check;

end architecture sim;
