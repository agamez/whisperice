--------------------------------------------------------------------------------
-- tb_top.vhd -- wspr-icebreaker Phase 1 testbench
--
-- Functional test for src/top.vhd (plan section 29 Rule 3: a block is not
-- finished because it synthesizes; a functional test must exist).
--
-- What it checks
-- --------------
-- The DUT is instantiated with SCALED-DOWN clock/rate generics so the whole
-- test runs in a few microseconds of simulation (plan section 21: change test
-- parameters, never the functional logic).  The testbench then counts clock
-- cycles between successive led1/led2 transitions and asserts that each
-- half-period (toggle interval) equals the expected divider depth computed
-- independently from the same generics:
--
--     DIV = CLK_HZ / (2 * BLINK_HZ) = CLK_HZ / ((2 * BLINK_MHZ) / MHZ_PER_HZ)
--
-- A mismatch is reported with severity failure, which makes `ghdl -r
-- --assert-level=error` exit non-zero.  On success the test reports a note and
-- the clock process ends, so GHDL terminates on its own (no --stop-time
-- required).
--
-- VHDL-93 ONLY (IEEE Std 1076-1993): explicit sensitivity lists, no
-- process(all), no std.env (VHDL-2008).  Analyze with --std=93.
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;

entity tb_top is
  generic (
    -- Simulation clock period.  Kept symbolic: the DUT counts clock cycles,
    -- so the absolute period is irrelevant to the logic; only the cycle
    -- counts matter.
    CLK_PERIOD : time     := 10 ns;

    -- Scaled-down DUT clock frequency (nominal is 12_000_000).  Scaling this
    -- keeps the divider depths small while testing the identical logic.
    CLK_HZ     : positive := 1000;

    -- Same blink-rate generics as the DUT (scaled clock -> small divisors).
    BLINK1_MHZ : positive := 1000;   -- 1.0 Hz -> DIV1 = 500 cycles
    BLINK2_MHZ : positive := 500;    -- 0.5 Hz -> DIV2 = 1000 cycles

    -- Simulation length in rising clock edges.
    NUM_CYCLES : positive := 6000
  );
end entity tb_top;

architecture sim of tb_top is

  -- Recompute the expected divider depths exactly as the DUT does, but
  -- independently (from the generics, not from DUT internals).
  constant MHZ_PER_HZ : positive := 1000;
  constant DIV1 : positive := CLK_HZ / ((2 * BLINK1_MHZ) / MHZ_PER_HZ);
  constant DIV2 : positive := CLK_HZ / ((2 * BLINK2_MHZ) / MHZ_PER_HZ);

  signal clk  : std_logic := '0';
  signal led1 : std_logic;
  signal led2 : std_logic;

begin

  ----------------------------------------------------------------------------
  -- DUT
  ----------------------------------------------------------------------------
  dut : entity work.top
    generic map (
      CLK_HZ     => CLK_HZ,
      BLINK1_MHZ => BLINK1_MHZ,
      BLINK2_MHZ => BLINK2_MHZ
    )
    port map (
      clk  => clk,
      led1 => led1,
      led2 => led2
    );

  ----------------------------------------------------------------------------
  -- Clock generator.  Runs for NUM_CYCLES rising edges and then the process
  -- ends; with no further clock events GHDL finishes the simulation.
  ----------------------------------------------------------------------------
  p_clk : process is
  begin
    clk <= '0';
    for i in 0 to NUM_CYCLES - 1 loop
      wait for CLK_PERIOD / 2;
      clk <= '1';
      wait for CLK_PERIOD / 2;
      clk <= '0';
    end loop;
    wait;
  end process p_clk;

  ----------------------------------------------------------------------------
  -- Checker: measure the interval between consecutive LED transitions and
  -- compare against DIV1 / DIV2.
  ----------------------------------------------------------------------------
  p_check : process is
    variable edges     : natural := 0;   -- rising edges seen so far
    variable prev1     : std_logic := '1';  -- DUT powers up with ledn_r = '1'
    variable prev2     : std_logic := '1';
    variable toggle1   : natural := 0;   -- transitions observed on led1
    variable toggle2   : natural := 0;
    variable last1     : integer := 0;   -- edge index of previous led1 edge
    variable last2     : integer := 0;
  begin
    wait until rising_edge(clk);
    loop
      edges := edges + 1;

      -- led1 transition?
      if led1 /= prev1 then
        if toggle1 > 0 then
          assert (edges - last1) = DIV1
            report "tb_top: led1 half-period = " & integer'image(edges - last1) &
                   " cycles, expected DIV1 = " & integer'image(DIV1)
            severity failure;
        end if;
        last1   := edges;
        prev1   := led1;
        toggle1 := toggle1 + 1;
      end if;

      -- led2 transition?
      if led2 /= prev2 then
        if toggle2 > 0 then
          assert (edges - last2) = DIV2
            report "tb_top: led2 half-period = " & integer'image(edges - last2) &
                   " cycles, expected DIV2 = " & integer'image(DIV2)
            severity failure;
        end if;
        last2   := edges;
        prev2   := led2;
        toggle2 := toggle2 + 1;
      end if;

      exit when edges >= NUM_CYCLES;
      wait until rising_edge(clk);
    end loop;

    -- Make sure the run was long enough to observe several periods.
    assert toggle1 >= 3
      report "tb_top: too few led1 transitions observed (" &
             integer'image(toggle1) & ")"
      severity failure;
    assert toggle2 >= 2
      report "tb_top: too few led2 transitions observed (" &
             integer'image(toggle2) & ")"
      severity failure;

    report "tb_top: PASS - led1 toggled every " & integer'image(DIV1) &
           " cycles (" & integer'image(toggle1) & " transitions), led2 every " &
           integer'image(DIV2) & " cycles (" & integer'image(toggle2) &
           " transitions)" severity note;

    wait;
  end process p_check;

end architecture sim;
