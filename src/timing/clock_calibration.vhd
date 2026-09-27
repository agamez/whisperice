--------------------------------------------------------------------------------
-- clock_calibration.vhd -- calibrate the FPGA clock against the GPS second
--
-- Phase 3 (orchestrator plan section 7).
--
-- PURPOSE
-- -------
-- A single one-second measurement from pps_measure is noisy and quantised to
-- +/- 1 clock cycle.  Before every WSPR transmission we instead average the
-- measured cycle count over CALIBRATION_SECONDS consecutive GPS seconds and
-- publish the result as calibrated_clock_hz (the effective FPGA clock
-- frequency in Hz), then FREEZE it for the duration of the transmission
-- (plan section 1.4, 7, 24: no dynamic retune during TX).
--
-- Calibration can be re-triggered at any time with a `start` pulse, because it
-- must run again before every transmission (plan section 7: "Calibration must
-- be performed before every WSPR transmission").
--
-- AVERAGING MATH (why average?)
-- ----------------------------
-- Each per-second measurement C_i is an integer count of FPGA clock cycles and
-- carries a quantisation error of at most +/- 1 cycle (the true frequency lies
-- between C_i - 1 and C_i + 1).  Averaging N independent intervals:
--
--     C_avg = (1/N) * sum(i=1..N) C_i
--
-- reduces the standard error of the mean by about sqrt(N) for independent,
-- dithered intervals (edge jitter, GPS/PPS jitter).  The WORST-CASE
-- quantisation bias is not reduced by averaging -- it stays below 1 cycle/s
-- (review finding S1: a bounded per-sample error does not shrink with N).
-- With the default N = 8 the mean is good to well under 1 cycle/s -- far
-- below the tone spacing the NCO must resolve (docs/spec.md sections 6/8).
--
-- The sum is formed in integer arithmetic and divided once at the end, with
-- round-half-up:
--
--     calibrated = (sum + N/2) / N
--
-- We round to nearest rather than truncate because the true oscillator
-- frequency is generally not an integer number of cycles per second;
-- truncation would bias the estimate low by up to 1 Hz on every calibration.
-- (N/2 is exact for the even N values used, e.g. 8 and 4.)
--
-- BOUNDS CHECK (plan section 31)
-- ------------------------------
-- If the averaged frequency lies outside a plausible band around the nominal
-- clock, something is wrong (wrong crystal, PPS glitch, miscount).  The block
-- then raises calibration_error and refuses to publish a valid calibration:
-- "Measured frequency out of bounds -> enter error state, do not transmit".
-- The band defaults are +/- 1000 ppm around NOMINAL_CLOCK_HZ (documented
-- DEFAULT-CONFIGURABLE; spec section 8 does not freeze a tolerance), i.e.
--
--     CAL_MIN_HZ = 12,000,000 * (1 - 1000e-6) = 11,988,000 Hz
--     CAL_MAX_HZ = 12,000,000 * (1 + 1000e-6) = 12,012,000 Hz
--
-- PPS LOSS (plan section 31)
-- --------------------------
-- If measurement_valid falls while samples have already been collected, the
-- window is abandoned and calibration is invalidated (valid and frozen clear).
-- A fresh `start` pulse is required once PPS is back.
--
-- VHDL-93 ONLY (IEEE Std 1076-1993): explicit sensitivity lists, no
-- process(all), no VHDL-2008 constructs.  Analyse with --std=93.
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity clock_calibration is
  generic (
    -- Width of the measured/calibrated frequency words; must match
    -- pps_measure.COUNT_WIDTH (default 25 bits).
    COUNT_WIDTH : positive := 25;

    -- Number of consecutive PPS intervals to average.  Frozen default
    -- CALIBRATION_SECONDS = 8 (docs/spec.md section 8; plan section 7),
    -- configurable (8 or 16 typical).  Testbenches scale this to 4.
    CALIBRATION_SECONDS : positive := 8;

    -- Plausible-band limits, in Hz, around NOMINAL_CLOCK_HZ.  Defaults are
    -- NOMINAL +/- 1000 ppm (see the header).  Override both to test the
    -- out-of-bounds path with scaled frequencies.
    CAL_MIN_HZ : natural := 11_988_000;
    CAL_MAX_HZ : natural := 12_012_000
  );
  port (
    clk : in std_logic;   -- FPGA clock
    rst : in std_logic;   -- synchronous reset, active high

    -- Rising edge begins a fresh calibration window.
    start : in std_logic;

    -- Timing/measurement interface from pps_measure.
    pps_tick                   : in std_logic;
    measured_cycles_per_second : in std_logic_vector(COUNT_WIDTH - 1 downto 0);
    measurement_valid          : in std_logic;

    -- Averaged effective FPGA clock frequency (Hz), unsigned.
    calibrated_clock_hz : out std_logic_vector(COUNT_WIDTH - 1 downto 0);

    -- '1' when calibrated_clock_hz is a finished, in-bounds result.
    calibration_valid : out std_logic;

    -- '1' once a window has completed: the published value is held stable
    -- (frozen) until the next start pulse.
    calibration_frozen : out std_logic;

    -- '1' when the averaged result was outside [CAL_MIN_HZ, CAL_MAX_HZ].
    -- Do NOT transmit while this is asserted (plan section 31).
    calibration_error : out std_logic
  );
end entity clock_calibration;

architecture rtl of clock_calibration is

  ----------------------------------------------------------------------------
  -- Named constants (no hidden magic numbers -- plan section 6, AGENTS.md 7)
  ----------------------------------------------------------------------------

  -- Nominal FPGA clock.  Frozen: docs/spec.md section 8.
  constant NOMINAL_CLOCK_HZ : positive := 12_000_000;

  -- Safe default published before the first successful calibration.  It is
  -- only meaningful once calibration_valid = '1'; consumers must gate on the
  -- valid output.
  constant DEFAULT_CALIBRATED : positive := NOMINAL_CLOCK_HZ;

  ----------------------------------------------------------------------------
  -- Start-edge detection: `start` is treated as a request pulse; a rising edge
  -- begins a new window, so a level held high does not retrigger every cycle.
  ----------------------------------------------------------------------------
  signal start_d    : std_logic := '0';
  signal start_rise : std_logic := '0';

  ----------------------------------------------------------------------------
  -- Calibration state
  ----------------------------------------------------------------------------
  signal busy_r         : std_logic := '0';  -- window in progress
  signal sample_count_r : integer range 0 to CALIBRATION_SECONDS := 0;
  signal sum_r          : natural := 0;      -- running sum of the counts

  signal calibrated_r : unsigned(COUNT_WIDTH - 1 downto 0) :=
    to_unsigned(DEFAULT_CALIBRATED, COUNT_WIDTH);
  signal valid_r  : std_logic := '0';
  signal frozen_r : std_logic := '0';
  signal error_r  : std_logic := '0';

begin

  ----------------------------------------------------------------------------
  -- Outputs driven from registered internal signals (VHDL-93 `out` ports
  -- cannot be read back).
  ----------------------------------------------------------------------------
  calibrated_clock_hz <= std_logic_vector(calibrated_r);
  calibration_valid   <= valid_r;
  calibration_frozen  <= frozen_r;
  calibration_error   <= error_r;

  ----------------------------------------------------------------------------
  -- Synchronise the start request and produce a single-cycle rising-edge
  -- pulse (start is expected in the clk domain, but registering it makes the
  -- retrigger edge deterministic and glitch-free).
  ----------------------------------------------------------------------------
  p_start_edge : process (clk) is
  begin
    if rising_edge(clk) then
      if rst = '1' then
        start_d    <= '0';
        start_rise <= '0';
      else
        start_d    <= start;
        start_rise <= start and (not start_d);
      end if;
    end if;
  end process p_start_edge;

  ----------------------------------------------------------------------------
  -- Averaging state machine.
  ----------------------------------------------------------------------------
  p_calibrate : process (clk) is
    variable total : natural;   -- sum including the sample being processed
    variable avg   : natural;   -- rounded average
  begin
    if rising_edge(clk) then
      if rst = '1' then
        busy_r         <= '0';
        sample_count_r <= 0;
        sum_r          <= 0;
        calibrated_r   <= to_unsigned(DEFAULT_CALIBRATED, COUNT_WIDTH);
        valid_r        <= '0';
        frozen_r       <= '0';
        error_r        <= '0';

      elsif start_rise = '1' then
        -- Begin (or restart) a fresh window.  Any previous frozen result is
        -- discarded while the new one is measured.
        busy_r         <= '1';
        sample_count_r <= 0;
        sum_r          <= 0;
        valid_r        <= '0';
        frozen_r       <= '0';
        error_r        <= '0';

      elsif busy_r = '1' then
        if measurement_valid = '0' then
          if sample_count_r > 0 then
            -- We had a reference and lost it: abandon and invalidate
            -- (plan section 31: "PPS disappears -> invalidate calibration").
            busy_r         <= '0';
            sample_count_r <= 0;
            sum_r          <= 0;
            valid_r        <= '0';
            frozen_r       <= '0';
            error_r        <= '0';
          end if;
          -- If no sample has been collected yet we simply keep waiting for
          -- the first valid measurement (e.g. PPS still locking).

        elsif pps_tick = '1' then
          if sample_count_r = CALIBRATION_SECONDS - 1 then
            -- Last sample of the window: average and freeze.
            total := sum_r +
                     to_integer(unsigned(measured_cycles_per_second));
            avg   := (total + (CALIBRATION_SECONDS / 2)) / CALIBRATION_SECONDS;

            calibrated_r <= to_unsigned(avg, COUNT_WIDTH);
            busy_r       <= '0';
            frozen_r     <= '1';

            if (avg < CAL_MIN_HZ) or (avg > CAL_MAX_HZ) then
              -- Out of bounds: refuse to publish a valid calibration.
              valid_r <= '0';
              error_r <= '1';
            else
              valid_r <= '1';
              error_r <= '0';
            end if;

          else
            -- Accumulate this sample and keep the window open.
            sum_r          <= sum_r +
                              to_integer(unsigned(measured_cycles_per_second));
            sample_count_r <= sample_count_r + 1;
          end if;
        end if;
      end if;
    end if;
  end process p_calibrate;

end architecture rtl;
