--------------------------------------------------------------------------------
-- top.vhd -- wspr-icebreaker top level
--
-- Phase 1 (orchestrator plan section 5): minimal, reproducible iCEBreaker
-- bring-up.  Demonstrates that the 12 MHz onboard oscillator is alive by
-- dividing it down with counter-based dividers to two visible LED blink
-- rates (plan section 5: "12 MHz -> divider -> LED").
--
-- VHDL-93 ONLY (IEEE Std 1076-1993).  No process(all), no VHDL-2000/2008
-- constructs; every process has an explicit sensitivity list.  Analyze with
--     ghdl -a --std=93 src/top.vhd
-- and synthesize with the Yosys GHDL plugin at --std=93.
--
-- Target: Lattice iCE40UP5K, package SG48 (iCEBreaker).
--
-- Pin provenance (docs/spec.md section 11): the ports below are assigned in
-- constraints/icebreaker.pcf from the official iCEBreaker example PCF,
--   icebreaker-fpga/icebreaker-examples @ commit
--   cb9e674cbf0facb84684b02567eb55df3018726b (file icebreaker/icebreaker.pcf)
--     clk  -> pin 35  (CLK,   12 MHz onboard oscillator)
--     led1 -> pin 11  (LEDR_N, on-board red   LED, active-low)
--     led2 -> pin 37  (LEDG_N, on-board green LED, active-low)
-- GPS (PMOD 1A) and RF (PMOD 1B) pins are intentionally NOT assigned yet;
-- they belong to later phases and must not be invented here.
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;

entity top is
  generic (
    -- Nominal onboard oscillator frequency in Hz.  Frozen value
    -- NOMINAL_CLOCK_HZ = 12000000 (docs/spec.md section 8).
    CLK_HZ     : positive := 12_000_000;

    -- LED blink rates, expressed in millihertz so both 1 Hz and 0.5 Hz can be
    -- represented without a real-valued generic (which would not synthesize).
    --   1000 mHz = 1.000 Hz;  500 mHz = 0.500 Hz.
    BLINK1_MHZ : positive := 1000;   -- led1: 1.0 Hz
    BLINK2_MHZ : positive := 500     -- led2: 0.5 Hz
  );
  port (
    clk  : in  std_logic;   -- 12 MHz (pin 35)
    led1 : out std_logic;   -- active-low: '0' = LED on  (pin 11, LEDR_N)
    led2 : out std_logic    -- active-low: '0' = LED on  (pin 37, LEDG_N)
  );
end entity top;

architecture rtl of top is

  -- Millihertz per hertz; keeps the frequency generics integer-valued.
  constant MHZ_PER_HZ : positive := 1000;

  -- Divider depth = clock cycles per LED half-period (i.e. per toggle):
  --     DIV = CLK_HZ / (2 * BLINK_HZ)
  --         = CLK_HZ / (2 * BLINK_MHZ / MHZ_PER_HZ)
  -- With the defaults this is CLK_HZ / BLINK_HZ / 2:
  --     DIV1 = 12000000 / 1.0 / 2 = 6_000_000 cycles -> 1.0 Hz blink rate
  --     DIV2 = 12000000 / 0.5 / 2 = 12_000_000 cycles -> 0.5 Hz blink rate
  -- The naive form CLK_HZ * BLINK_MHZ would overflow a 32-bit integer
  -- (12e6 * 1000 = 12e9 > 2^31-1), so the small (2 * BLINK_MHZ) term is
  -- divided by MHZ_PER_HZ first; exact for the integer rates used here.
  constant DIV1 : positive := CLK_HZ / ((2 * BLINK1_MHZ) / MHZ_PER_HZ);
  constant DIV2 : positive := CLK_HZ / ((2 * BLINK2_MHZ) / MHZ_PER_HZ);

  -- Counters count from 0 to DIVn-1 and wrap; on wrap the LED toggles, so the
  -- full blink period is 2*DIVn clock cycles (one on + one off).
  signal cnt1 : integer range 0 to DIV1 - 1 := 0;
  signal cnt2 : integer range 0 to DIV2 - 1 := 0;

  -- Registered LED drives, initialised high so both LEDs are off after
  -- power-up/configuration (active-low drive).
  signal led1_r : std_logic := '1';
  signal led2_r : std_logic := '1';

begin

  led1 <= led1_r;
  led2 <= led2_r;

  ----------------------------------------------------------------------------
  -- led1 divider: toggle every DIV1 clock cycles (~1 Hz by default).
  ----------------------------------------------------------------------------
  p_div1 : process (clk) is
  begin
    if rising_edge(clk) then
      if cnt1 = DIV1 - 1 then
        cnt1   <= 0;
        led1_r <= not led1_r;
      else
        cnt1 <= cnt1 + 1;
      end if;
    end if;
  end process p_div1;

  ----------------------------------------------------------------------------
  -- led2 divider: toggle every DIV2 clock cycles (~0.5 Hz by default).
  ----------------------------------------------------------------------------
  p_div2 : process (clk) is
  begin
    if rising_edge(clk) then
      if cnt2 = DIV2 - 1 then
        cnt2   <= 0;
        led2_r <= not led2_r;
      else
        cnt2 <= cnt2 + 1;
      end if;
    end if;
  end process p_div2;

end architecture rtl;
