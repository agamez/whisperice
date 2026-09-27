--------------------------------------------------------------------------------
-- tb_clock_calibration.vhd -- functional test for src/timing/clock_calibration.vhd
--
-- Phase 3 testbench (plan section 29 Rule 3; plan section 21: scale the test
-- parameters, never the logic).
--
-- WHAT IT CHECKS
-- --------------
-- CALIBRATION_SECONDS is scaled to 4; synthetic per-second counts are supplied
-- on measured_cycles_per_second together with a pps_tick pulse and
-- measurement_valid, and the test asserts that:
--
--   1. the in-bounds window (counts 1000, 1001, 999, 1000 -> sum 4000) yields
--      calibrated = (4000 + 4/2) / 4 = 1000 (round-half-up), valid = '1',
--      frozen = '1', error = '0';
--   2. the result stays frozen (output stable) until a new start pulse;
--   3. an out-of-bounds window (4 x 1002 -> 1002 > CAL_MAX_HZ = 1001) sets
--      error = '1' and refuses to publish a valid calibration (valid = '0');
--   4. if measurement_valid drops after samples have been collected (PPS
--      disappears), the window is abandoned and invalidated: valid = '0',
--      frozen = '0', error = '0' (plan section 31).
--
-- The "frequencies" here are scaled (band 999..1001 Hz around a nominal 1000)
-- so a 4-sample average runs instantly; the RTL arithmetic is identical to the
-- 12 MHz case, only the numbers are small.
--
-- VHDL-93 ONLY (IEEE Std 1076-1993): explicit sensitivity lists, no
-- process(all), no std.env.  Analyse with --std=93.
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_clock_calibration is
  generic (
    CLK_PERIOD          : time     := 10 ns;
    CALIBRATION_SECONDS : positive := 4;    -- scaled from the default 8
    CAL_MIN_HZ          : natural  := 999;  -- +/- 1000 ppm around nominal 1000
    CAL_MAX_HZ          : natural  := 1001;
    NUM_CYCLES          : positive := 500
  );
end entity tb_clock_calibration;

architecture sim of tb_clock_calibration is

  constant COUNT_WIDTH : positive := 25;

  signal clk         : std_logic := '0';
  signal rst         : std_logic := '1';
  signal start       : std_logic := '0';
  signal pps_tick    : std_logic := '0';
  signal measured    : std_logic_vector(COUNT_WIDTH - 1 downto 0) := (others => '0');
  signal mvalid      : std_logic := '0';

  signal calibrated  : std_logic_vector(COUNT_WIDTH - 1 downto 0);
  signal cal_valid   : std_logic;
  signal cal_frozen  : std_logic;
  signal cal_error   : std_logic;

  ----------------------------------------------------------------------------
  -- Stimulus procedures.  In VHDL-93 a subprogram may only drive signals that
  -- are passed as formal parameters (it cannot create a driver for an
  -- architecture signal implicitly), so the relevant signals are formals.
  ----------------------------------------------------------------------------

  -- One-cycle start request (the DUT detects its rising edge).
  procedure pulse_start (signal clk_s   : in  std_logic;
                         signal start_s : out std_logic) is
  begin
    wait until rising_edge(clk_s);
    start_s <= '1';
    wait until rising_edge(clk_s);
    start_s <= '0';
    wait until rising_edge(clk_s);
  end procedure pulse_start;

  -- Present one synthetic per-second measurement: a single-cycle pps_tick with
  -- measurement_valid high and the count on measured_cycles_per_second.
  procedure send_sample (signal   clk_s      : in  std_logic;
                         signal   pps_tick_s : out std_logic;
                         signal   mvalid_s   : out std_logic;
                         signal   measured_s : out std_logic_vector(COUNT_WIDTH - 1 downto 0);
                         constant value      : in  integer) is
  begin
    wait until rising_edge(clk_s);
    measured_s <= std_logic_vector(to_unsigned(value, COUNT_WIDTH));
    pps_tick_s <= '1';
    mvalid_s   <= '1';
    wait until rising_edge(clk_s);
    pps_tick_s <= '0';
    wait until rising_edge(clk_s);
  end procedure send_sample;

begin

  ----------------------------------------------------------------------------
  -- DUT
  ----------------------------------------------------------------------------
  dut : entity work.clock_calibration
    generic map (
      COUNT_WIDTH         => COUNT_WIDTH,
      CALIBRATION_SECONDS => CALIBRATION_SECONDS,
      CAL_MIN_HZ          => CAL_MIN_HZ,
      CAL_MAX_HZ          => CAL_MAX_HZ
    )
    port map (
      clk                        => clk,
      rst                        => rst,
      start                      => start,
      pps_tick                   => pps_tick,
      measured_cycles_per_second => measured,
      measurement_valid          => mvalid,
      calibrated_clock_hz        => calibrated,
      calibration_valid          => cal_valid,
      calibration_frozen         => cal_frozen,
      calibration_error          => cal_error
    );

  ----------------------------------------------------------------------------
  -- Clock.  Finite so the simulation ends on its own.
  ----------------------------------------------------------------------------
  p_clk : process is
  begin
    clk <= '0';
    for i in 0 to NUM_CYCLES loop
      wait for CLK_PERIOD / 2;
      clk <= '1';
      wait for CLK_PERIOD / 2;
      clk <= '0';
    end loop;
    wait;
  end process p_clk;

  ----------------------------------------------------------------------------
  -- Test sequence.
  ----------------------------------------------------------------------------
  p_test : process is
  begin
    rst    <= '1';
    start  <= '0';
    mvalid <= '0';

    for i in 1 to 5 loop
      wait until rising_edge(clk);
    end loop;
    rst <= '0';
    wait until rising_edge(clk);

    --------------------------------------------------------------------------
    -- Scenario A: in-bounds average, freeze, and hold.
    --------------------------------------------------------------------------
    -- No calibration before a start request.
    assert (cal_valid = '0') and (cal_frozen = '0')
      report "tb_clock_calibration: calibration valid/frozen before start"
      severity failure;

    pulse_start(clk, start);
    mvalid <= '1';
    send_sample(clk, pps_tick, mvalid, measured, 1000);
    send_sample(clk, pps_tick, mvalid, measured, 1001);
    send_sample(clk, pps_tick, mvalid, measured, 999);
    send_sample(clk, pps_tick, mvalid, measured, 1000);  -- sum 4000, avg 1000

    for i in 1 to 3 loop
      wait until rising_edge(clk);
    end loop;

    assert to_integer(unsigned(calibrated)) = 1000
      report "tb_clock_calibration: calibrated = " &
             integer'image(to_integer(unsigned(calibrated))) &
             ", expected 1000 (rounded average)"
      severity failure;
    assert cal_valid = '1'
      report "tb_clock_calibration: in-bounds average did not assert valid"
      severity failure;
    assert cal_frozen = '1'
      report "tb_clock_calibration: completed window did not assert frozen"
      severity failure;
    assert cal_error = '0'
      report "tb_clock_calibration: in-bounds average wrongly raised error"
      severity failure;

    --------------------------------------------------------------------------
    -- Scenario B: the result must stay frozen until a new start pulse.
    --------------------------------------------------------------------------
    for i in 1 to 20 loop
      wait until rising_edge(clk);
    end loop;
    assert (to_integer(unsigned(calibrated)) = 1000) and (cal_valid = '1') and
           (cal_frozen = '1') and (cal_error = '0')
      report "tb_clock_calibration: frozen result changed without a start pulse"
      severity failure;

    --------------------------------------------------------------------------
    -- Scenario C: out-of-bounds average -> error, no valid calibration.
    --------------------------------------------------------------------------
    pulse_start(clk, start);
    mvalid <= '1';
    send_sample(clk, pps_tick, mvalid, measured, 1002);
    send_sample(clk, pps_tick, mvalid, measured, 1002);
    send_sample(clk, pps_tick, mvalid, measured, 1002);
    send_sample(clk, pps_tick, mvalid, measured, 1002);  -- avg 1002 > max

    for i in 1 to 3 loop
      wait until rising_edge(clk);
    end loop;

    assert to_integer(unsigned(calibrated)) = 1002
      report "tb_clock_calibration: out-of-bounds calibrated = " &
             integer'image(to_integer(unsigned(calibrated))) & ", expected 1002"
      severity failure;
    assert cal_error = '1'
      report "tb_clock_calibration: out-of-bounds average did not raise error"
      severity failure;
    assert cal_valid = '0'
      report "tb_clock_calibration: out-of-bounds average published valid"
      severity failure;
    assert cal_frozen = '1'
      report "tb_clock_calibration: out-of-bounds result not frozen"
      severity failure;

    --------------------------------------------------------------------------
    -- Scenario D: PPS loss mid-window invalidates the calibration.
    --------------------------------------------------------------------------
    pulse_start(clk, start);
    mvalid <= '1';
    send_sample(clk, pps_tick, mvalid, measured, 1000);
    send_sample(clk, pps_tick, mvalid, measured, 1000);  -- window still open

    mvalid <= '0';       -- PPS disappears
    for i in 1 to 4 loop
      wait until rising_edge(clk);
    end loop;

    assert cal_valid = '0'
      report "tb_clock_calibration: valid not cleared on PPS loss"
      severity failure;
    assert cal_frozen = '0'
      report "tb_clock_calibration: frozen not cleared on PPS loss"
      severity failure;
    assert cal_error = '0'
      report "tb_clock_calibration: PPS loss wrongly flagged as out-of-bounds"
      severity failure;

    report "tb_clock_calibration: PASS - average/round 1000 in bounds, freeze " &
           "held, out-of-bounds error raised, PPS loss invalidated"
      severity note;

    wait;
  end process p_test;

end architecture sim;
