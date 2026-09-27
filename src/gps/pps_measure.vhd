--------------------------------------------------------------------------------
-- pps_measure.vhd -- 1PPS input conditioning and FPGA-clock measurement
--
-- Phase 2 (orchestrator plan section 6): 1PPS input.
--
-- WHAT THIS BLOCK DOES
-- --------------------
-- The PmodGPS 1PPS output is an asynchronous, slow (roughly 100 ms wide)
-- pulse, one per GPS second (docs/spec.md section 10; plan section 3.2).
-- This block:
--
--   1. synchronises pps_in into the FPGA clock domain with a two-flip-flop
--      synchroniser (plan section 6.4: "avoid metastability"),
--   2. detects a RISING edge and emits a single-clock-cycle pulse pps_tick
--      (plan section 6.2-6.3),
--   3. counts FPGA clock cycles between consecutive pps_tick pulses and
--      latches the count into measured_cycles_per_second on every PPS
--      (plan section 6: "measure the number of clock cycles between
--      consecutive PPS pulses"), and
--   4. reports measurement_valid, which clears if no PPS edge arrives within
--      TIMEOUT_CYCLES (plan section 31: "PPS disappears -> invalidate
--      calibration").
--
-- IMPORTANT -- WHAT IS BEING MEASURED (plan section 6)
-- ----------------------------------------------------
-- The counter measures the FPGA's *real* clock frequency against the GPS
-- second: the GPS 1PPS defines the one-second interval, and we count how many
-- FPGA clock cycles fit into it.  It does NOT measure the GPS against the
-- FPGA.  The latched count is therefore "FPGA clock cycles per GPS second",
-- i.e. the effective FPGA clock frequency in Hz.
--
-- LONG PULSE, NOT A NARROW EDGE
-- -----------------------------
-- The PmodGPS pulse is HIGH for ~100 ms, which at 12 MHz is ~1.2 million
-- cycles -- far too long to treat as an edge.  Only the 0->1 transition
-- produces pps_tick; the long high level produces nothing further, and the
-- falling edge is ignored.  The two-flop synchroniser handles the slow level
-- without trouble.
--
-- COUNTER WIDTH
-- -------------
-- COUNT_WIDTH defaults to 25 bits.  A 25-bit unsigned value holds
-- 2**25 - 1 = 33,554,431, which safely exceeds the expected 12,000,000
-- cycles/s (docs/spec.md section 8).  With margin > 2x the nominal value, a
-- badly-detuned or faster replacement oscillator still cannot wrap the
-- counter within one GPS second.
--
-- VHDL-93 ONLY (IEEE Std 1076-1993): explicit sensitivity lists, no
-- process(all), no VHDL-2008 constructs.  Analyse with --std=93.
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity pps_measure is
  generic (
    -- Width of the cycle counter and of measured_cycles_per_second.
    -- 25 bits -> max 33,554,431 > NOMINAL_CLOCK_HZ = 12,000,000 (spec 8).
    COUNT_WIDTH : positive := 25;

    -- Number of FPGA clock cycles without a PPS rising edge after which the
    -- measurement is declared invalid (plan section 31).  Default is two GPS
    -- seconds at the nominal clock: 2 * 12,000,000 = 24,000,000 cycles.
    -- Testbenches scale this down; the functional logic is unchanged
    -- (plan section 21).
    TIMEOUT_CYCLES : positive := 24_000_000
  );
  port (
    clk : in std_logic;   -- FPGA clock (12 MHz onboard oscillator)
    rst : in std_logic;   -- synchronous reset, active high

    pps_in : in std_logic;   -- raw asynchronous 1PPS from the PmodGPS

    -- One-clock-cycle pulse on each rising edge of the synchronised PPS.
    pps_tick : out std_logic;

    -- FPGA clock cycles counted in the interval that ended at the last PPS.
    -- Latched on every PPS after the first (the first edge only arms the
    -- measurement).  Unsigned, COUNT_WIDTH bits.
    measured_cycles_per_second : out std_logic_vector(COUNT_WIDTH - 1 downto 0);

    -- '1' while the last completed interval is trustworthy; cleared when PPS
    -- has been absent for TIMEOUT_CYCLES, and after reset.
    measurement_valid : out std_logic
  );
end entity pps_measure;

architecture rtl of pps_measure is

  ----------------------------------------------------------------------------
  -- Named constants (no hidden magic numbers -- plan section 6, AGENTS.md 7)
  ----------------------------------------------------------------------------

  -- Nominal FPGA clock.  Frozen: docs/spec.md section 8
  -- ("NOMINAL_CLOCK_HZ = 12000000 (12 MHz)"; plan section 6).
  -- Provenance: iCEBreaker onboard 12 MHz oscillator shared with the FT2232H
  -- (plan section 3.1, AGENTS.md section 2.7).
  constant NOMINAL_CLOCK_HZ : positive := 12_000_000;

  -- Value the interval counter is re-armed to.  See the counter comment below:
  -- it starts at 1 so that the value latched on a pps_tick is exactly the
  -- number of clock cycles in the completed interval (not one less).
  constant INTERVAL_ARM : positive := 1;

  ----------------------------------------------------------------------------
  -- Synchroniser / edge-detector pipeline
  ----------------------------------------------------------------------------
  signal pps_meta   : std_logic := '0';  -- first flip-flop (metastable window)
  signal pps_sync   : std_logic := '0';  -- second flip-flop (clean level)
  signal pps_sync_d : std_logic := '0';  -- previous clean level
  signal pps_tick_r : std_logic := '0';  -- registered rising-edge pulse

  ----------------------------------------------------------------------------
  -- Measurement state
  ----------------------------------------------------------------------------
  signal interval_cnt : unsigned(COUNT_WIDTH - 1 downto 0) :=
    to_unsigned(INTERVAL_ARM, COUNT_WIDTH);

  signal measured_r : unsigned(COUNT_WIDTH - 1 downto 0) := (others => '0');

  signal first_edge_r : std_logic := '0';  -- '1' once a reference edge is seen
  signal valid_r      : std_logic := '0';

  -- Timeout bookkeeping.  timeout_cnt counts clocks since the last pps_tick
  -- and saturates at TIMEOUT_CYCLES.
  signal timeout_cnt  : integer range 0 to TIMEOUT_CYCLES := 0;
  signal timeout_flag : std_logic := '0';

begin

  ----------------------------------------------------------------------------
  -- Outputs driven from registered internal signals (an `out` port cannot be
  -- read back in VHDL-93, so the state lives in signals).
  ----------------------------------------------------------------------------
  pps_tick                   <= pps_tick_r;
  measured_cycles_per_second <= std_logic_vector(measured_r);
  measurement_valid          <= valid_r;

  ----------------------------------------------------------------------------
  -- Two-flip-flop synchroniser (plan section 6.4).
  --
  -- pps_in is asynchronous.  The first flip-flop may go metastable; the second
  -- samples it one clock later, giving a clean, clk-domain level.  The ~100 ms
  -- high level is sampled as a steady '1' and causes no further action.
  ----------------------------------------------------------------------------
  p_synchroniser : process (clk) is
  begin
    if rising_edge(clk) then
      if rst = '1' then
        pps_meta <= '0';
        pps_sync <= '0';
      else
        pps_meta <= pps_in;
        pps_sync <= pps_meta;
      end if;
    end if;
  end process p_synchroniser;

  ----------------------------------------------------------------------------
  -- Rising-edge detector.
  --
  -- pps_sync_d holds the previous clean level; `pps_sync and not pps_sync_d` is
  -- true for exactly one clock because it is registered.  Only the 0->1
  -- transition triggers: a long high level yields a single pulse, and the
  -- falling edge yields none.
  ----------------------------------------------------------------------------
  p_edge_detect : process (clk) is
  begin
    if rising_edge(clk) then
      if rst = '1' then
        pps_sync_d <= '0';
        pps_tick_r <= '0';
      else
        pps_sync_d <= pps_sync;
        pps_tick_r <= pps_sync and (not pps_sync_d);
      end if;
    end if;
  end process p_edge_detect;

  ----------------------------------------------------------------------------
  -- Interval counter: counts FPGA clock cycles since the previous pps_tick.
  --
  -- It is re-armed to 1 (the current cycle counts) on every pps_tick and
  -- whenever the timeout is active.  Starting at 1 means the value present on
  -- the next pps_tick is exactly the number of clock cycles between the two
  -- pps_tick pulses, with no off-by-one:
  --
  --   re-armed to 1 during cycle t+1
  --   value during cycle t+m equals m
  --   next tick during cycle t+N latches N   (interval = N cycles)
  ----------------------------------------------------------------------------
  p_interval_counter : process (clk) is
  begin
    if rising_edge(clk) then
      if rst = '1' then
        interval_cnt <= to_unsigned(INTERVAL_ARM, COUNT_WIDTH);
      elsif pps_tick_r = '1' then
        interval_cnt <= to_unsigned(INTERVAL_ARM, COUNT_WIDTH);
      elsif timeout_flag = '1' then
        interval_cnt <= to_unsigned(INTERVAL_ARM, COUNT_WIDTH);
      else
        interval_cnt <= interval_cnt + 1;
      end if;
    end if;
  end process p_interval_counter;

  ----------------------------------------------------------------------------
  -- Timeout counter: resets on every pps_tick, saturates at TIMEOUT_CYCLES.
  -- timeout_flag then stays high until the next pps_tick, which is what
  -- invalidates the measurement (plan section 31).
  ----------------------------------------------------------------------------
  p_timeout_counter : process (clk) is
  begin
    if rising_edge(clk) then
      if rst = '1' then
        timeout_cnt <= 0;
      elsif pps_tick_r = '1' then
        timeout_cnt <= 0;
      elsif timeout_cnt < TIMEOUT_CYCLES then
        timeout_cnt <= timeout_cnt + 1;
      end if;
    end if;
  end process p_timeout_counter;

  timeout_flag <= '1' when timeout_cnt = TIMEOUT_CYCLES else '0';

  ----------------------------------------------------------------------------
  -- Validity / first-edge state machine.
  --
  --   * the first pps_tick after reset only arms the measurement
  --     (first_edge_r <= '1'); no full interval has been observed yet, so the
  --     measurement stays invalid;
  --   * each later pps_tick marks the just-completed interval valid;
  --   * a timeout clears both the validity and the reference, so after PPS
  --     returns the block waits for two fresh edges again.
  -- A pps_tick takes priority over a simultaneous timeout.
  ----------------------------------------------------------------------------
  p_validity : process (clk) is
  begin
    if rising_edge(clk) then
      if rst = '1' then
        first_edge_r <= '0';
        valid_r      <= '0';
      elsif pps_tick_r = '1' then
        if first_edge_r = '0' then
          first_edge_r <= '1';   -- reference edge; interval not yet complete
          valid_r      <= '0';
        else
          valid_r      <= '1';   -- a full GPS-second interval just completed
        end if;
      elsif timeout_flag = '1' then
        first_edge_r <= '0';     -- lost the reference; re-arm on next edges
        valid_r      <= '0';
      end if;
    end if;
  end process p_validity;

  ----------------------------------------------------------------------------
  -- Measurement latch.
  --
  -- On a pps_tick that closes a full interval, store the cycle count.  The
  -- interval counter and this process both read the pre-update value of
  -- interval_cnt at the same clock edge, so the count is preserved here before
  -- the counter is re-armed.
  ----------------------------------------------------------------------------
  p_latch : process (clk) is
  begin
    if rising_edge(clk) then
      if rst = '1' then
        measured_r <= (others => '0');
      elsif (pps_tick_r = '1') and (first_edge_r = '1') then
        measured_r <= interval_cnt;
      end if;
    end if;
  end process p_latch;

end architecture rtl;
