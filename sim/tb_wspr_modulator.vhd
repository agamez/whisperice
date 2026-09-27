--------------------------------------------------------------------------------
-- tb_wspr_modulator.vhd -- testbench for the continuous-phase 4-FSK modulator
--
-- Monitor semantics (IMPORTANT, derived from the RTL's registered outputs):
-- at delta-0 of clock edge E, a signal reflects the value assigned at edge
-- E-1.  symbol_tick is therefore observed high at edge B+1 for a boundary at
-- edge B, and the rf sample seen at edge B+1 already belongs to the NEXT
-- symbol.  The monitors below treat every rising edge as exactly one rf
-- SAMPLE: a symbol's length equals its sample count (samples from the edge
-- after the previous boundary through the boundary edge), and a transition
-- between two samples is counted for a symbol only when both samples belong
-- to it (pairs crossing a tick edge are excluded).
--
-- Runs (plan section 21: identical functional logic, only test parameters
-- scaled; plan section 10: exact timing; section 17: phase continuity):
--
--   Run A (CLOCK_HZ = 12,000 = exactly 1/1000 of 12 MHz, so one symbol
--          (8192/12000 s) is EXACTLY 8192 cycles; 40-bit accumulator, real
--          spec-section-9 increments):
--     (a1) all 162 symbols last exactly 8192 cycles;
--     (b)  exactly 162 symbol_tick pulses, then tx_active/rf_out go '0';
--     (c1) constant symbol index -> per-symbol rf transition count stable
--          within +-1 (the 40-bit MSB pattern is quasi-periodic).
--
--   Run B (CLOCK_HZ = 12,001 -- scaled model of a calibrated 12,000,100 Hz
--          clock; fractional symbol-time accumulator exercised):
--     (d)  cumulative length of the 162-symbol run within < 1 cycle of the
--          ideal 162*CLOCK_HZ*8192/12000; every symbol length in {8192,8193}.
--
--   Run C (ACCUMULATOR_BITS scaled to 10 with bench increments so the tone
--          step is visible at the pin within one symbol -- the real 40-bit
--          tone step is ~0.001 carrier cycles per symbol; DUT logic
--          identical):
--     (c2) index 0 (inc 256): exactly 2048 rising transitions per symbol;
--          index 3 (inc 448): exactly 3584 per symbol (both derived from the
--          sample sequences, periods 4 and 16 dividing 8192);
--     (e)  a mid-symbol change of symbol_index leaves the symbol in progress
--          unperturbed and applies the new index exactly at the next tick.
--
-- Provenance: increments from tools/calculate_nco.py (frozen constants via
-- docs/spec.md sections 6/9).  No golden RTL outputs: every expectation is
-- re-derived from the generics/sample arithmetic.
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_wspr_modulator is
end entity tb_wspr_modulator;

architecture sim of tb_wspr_modulator is

  constant NUM_SYMS   : positive := 162;
  constant SYMBOL_NUM : positive := 8192;   -- spec section 6
  constant SYMBOL_DEN : positive := 12000;

  -- Run A/B generics (40-bit, real increments from tools/calculate_nco.py)
  constant CARRIER_INC : std_logic_vector(39 downto 0) := x"D8530323E9";
  constant HALF_TONE_INC : natural := 67109;

  -- Run C (centered grid: inc(k) = 256 + (2k-3)*64):
  --        index 0 -> inc 64   (alpha 0.0625, pattern period 16, 1 rising
  --                             edge per period -> 512 transitions/symbol)
  --        index 3 -> inc 448  (alpha 0.4375, period 16, 7 per 16 -> 3584)
  constant CARRIER_INC_C : std_logic_vector(39 downto 0) :=
    std_logic_vector(to_unsigned(256, 40));
  constant HALF_TONE_INC_C : natural := 64;
  constant EXPECT_C_IDX0 : integer := 512;   -- rising transitions / symbol
  constant EXPECT_C_IDX3 : integer := 3584;

  constant C_HOLD_LEN : integer := (8192 - 3000) + 2*8192 + 100;

  type int_vec_t is array (0 to NUM_SYMS-1) of integer;

  signal a_clk : std_logic := '0';
  signal a_rst, a_start, a_rf, a_act, a_tick : std_logic;
  signal a_idx  : std_logic_vector(1 downto 0) := "00";
  signal a_done : boolean := false;
  signal a_fail : integer := 0;

  signal b_clk : std_logic := '0';
  signal b_rst, b_start, b_rf, b_act, b_tick : std_logic;
  signal b_idx  : std_logic_vector(1 downto 0) := "00";
  signal b_done : boolean := false;
  signal b_fail : integer := 0;

  signal c_clk : std_logic := '0';
  signal c_rst, c_start, c_rf, c_act, c_tick : std_logic;
  signal c_idx  : std_logic_vector(1 downto 0) := "00";
  signal c_done : boolean := false;
  signal c_fail : integer := 0;

begin

  ---------------------------------------------------------------------------
  -- Run A
  ---------------------------------------------------------------------------
  dut_a : entity work.wspr_modulator
    generic map (CLOCK_HZ => 12000, CARRIER_INCREMENT => CARRIER_INC,
                 HALF_TONE_INCREMENT => HALF_TONE_INC,
                 SYMBOLS_PER_TX => NUM_SYMS,
                 ACCUMULATOR_BITS => 40)
    port map (clk => a_clk, rst => a_rst, tx_start => a_start,
              symbol_index => a_idx, rf_out => a_rf, tx_active => a_act,
              symbol_tick => a_tick);

  a_clk <= not a_clk after 50 ns when not a_done else '0';

  stim_a : process
  begin
    a_rst <= '1'; a_start <= '0';
    wait until rising_edge(a_clk); wait until rising_edge(a_clk);
    a_rst <= '0';
    wait until rising_edge(a_clk);
    a_start <= '1'; wait until rising_edge(a_clk);
    a_start <= '0';
    wait;
  end process;

  -- Sample-counting monitor (see header): one sample per rising edge.
  mon_a : process
    variable len    : int_vec_t := (others => 0);
    variable edges  : int_vec_t := (others => 0);
    variable count  : integer := 0;      -- samples accumulated in current symbol
    variable trans  : integer := 0;      -- rising transitions in current symbol
    variable prev   : std_logic := '0';
    variable haveprev : boolean := false;
    variable k, maxe : integer := 0;
  begin
    wait until a_rst = '0';
    wait until a_act = '1';
    while k < NUM_SYMS loop
      wait until rising_edge(a_clk);
      if a_tick = '1' then
        -- boundary was the previous edge; THIS edge's sample opens the next
        -- symbol: finalize current, then seed the next with this sample
        len(k)   := count;
        edges(k) := trans;
        k        := k + 1;
        count    := 1;
        trans    := 0;
        prev     := a_rf;
        haveprev := true;
      else
        if haveprev and prev = '0' and a_rf = '1' then
          trans := trans + 1;
        end if;
        prev := a_rf;
        haveprev := true;
        count := count + 1;
      end if;
    end loop;
    -- (a1) exact symbol lengths
    for i in 0 to NUM_SYMS-1 loop
      if len(i) /= 8192 then
        report "FAIL A: symbol " & integer'image(i) & " length "
               & integer'image(len(i)) & " /= 8192" severity error;
        a_fail <= a_fail + 1;
      end if;
    end loop;
    -- (c1) stable transition count per symbol (quasi-periodic MSB: +-1)
    maxe := 0;
    for i in 0 to NUM_SYMS-1 loop
      if edges(i) > maxe then maxe := edges(i); end if;
    end loop;
    for i in 0 to NUM_SYMS-1 loop
      if maxe - edges(i) > 1 then
        report "FAIL A: symbol " & integer'image(i) & " transitions "
               & integer'image(edges(i)) & " deviate >1 from max "
               & integer'image(maxe) severity error;
        a_fail <= a_fail + 1;
      end if;
    end loop;
    -- (b) clean stop
    wait until rising_edge(a_clk);
    if a_act /= '0' then
      report "FAIL A: tx_active high after last tick" severity error;
      a_fail <= a_fail + 1;
    end if;
    for i in 1 to 100 loop
      wait until rising_edge(a_clk);
      if a_rf /= '0' then
        report "FAIL A: rf_out not off after TX" severity error;
        a_fail <= a_fail + 1; exit;
      end if;
    end loop;
    if a_fail = 0 then
      report "tb_wspr_modulator A: PASS - 162 x 8192 cycles exact, transitions "
             & "stable (" & integer'image(edges(0)) & ".." & integer'image(maxe)
             & "), clean stop";
    end if;
    a_done <= true;
    wait;
  end process;

  ---------------------------------------------------------------------------
  -- Run B
  ---------------------------------------------------------------------------
  dut_b : entity work.wspr_modulator
    generic map (CLOCK_HZ => 12001, CARRIER_INCREMENT => CARRIER_INC,
                 HALF_TONE_INCREMENT => HALF_TONE_INC,
                 SYMBOLS_PER_TX => NUM_SYMS,
                 ACCUMULATOR_BITS => 40)
    port map (clk => b_clk, rst => b_rst, tx_start => b_start,
              symbol_index => b_idx, rf_out => b_rf, tx_active => b_act,
              symbol_tick => b_tick);

  b_clk <= not b_clk after 50 ns when not b_done else '0';

  stim_b : process
  begin
    b_rst <= '1'; b_start <= '0';
    wait until rising_edge(b_clk); wait until rising_edge(b_clk);
    b_rst <= '0';
    wait until rising_edge(b_clk);
    b_start <= '1'; wait until rising_edge(b_clk);
    b_start <= '0';
    wait;
  end process;

  mon_b : process
    variable len    : int_vec_t := (others => 0);
    variable count  : integer := 0;
    variable total  : integer := 0;
    variable k      : integer := 0;
    variable expected : real;
    constant CLOCKHZ  : integer := 12001;
  begin
    wait until b_rst = '0';
    wait until b_act = '1';
    while k < NUM_SYMS loop
      wait until rising_edge(b_clk);
      if b_tick = '1' then
        len(k)  := count;                -- boundary was the previous edge
        total   := total + count;
        k       := k + 1;
        count   := 1;                    -- this edge's sample opens next symbol
      else
        count := count + 1;
      end if;
    end loop;
    -- (d) cumulative exactness: floor distribution == ideal within < 1 cycle
    expected := real(NUM_SYMS) * real(CLOCKHZ) * real(SYMBOL_NUM)
              / real(SYMBOL_DEN);
    if abs(real(total) - expected) >= 1.0 then
      report "FAIL B: total cycles " & integer'image(total) & " vs ideal "
             & real'image(expected) severity error;
      b_fail <= b_fail + 1;
    end if;
    for i in 0 to NUM_SYMS-1 loop
      if len(i) /= 8192 and len(i) /= 8193 then
        report "FAIL B: symbol " & integer'image(i) & " length "
               & integer'image(len(i)) & " not in {8192,8193}" severity error;
        b_fail <= b_fail + 1;
      end if;
    end loop;
    if b_fail = 0 then
      report "tb_wspr_modulator B: PASS - total " & integer'image(total)
             & " cycles vs ideal " & real'image(expected)
             & " (<1 cycle); lengths in {8192,8193}";
    end if;
    b_done <= true;
    wait;
  end process;

  ---------------------------------------------------------------------------
  -- Run C
  ---------------------------------------------------------------------------
  dut_c : entity work.wspr_modulator
    generic map (CLOCK_HZ => 12000, CARRIER_INCREMENT => CARRIER_INC_C,
                 HALF_TONE_INCREMENT => HALF_TONE_INC_C, SYMBOLS_PER_TX => NUM_SYMS,
                 ACCUMULATOR_BITS => 10)
    port map (clk => c_clk, rst => c_rst, tx_start => c_start,
              symbol_index => c_idx, rf_out => c_rf, tx_active => c_act,
              symbol_tick => c_tick);

  c_clk <= not c_clk after 50 ns when not c_done else '0';

  -- Script: symbols 0..4 index "00"; "11" driven at sample 3000 of symbol 5
  -- (applied at the boundary ending symbol 5 -> symbols 6..8 are tone 3;
  -- held 100 samples into symbol 8 before switching back -> symbol 9 returns
  -- to tone 0).
  stim_c : process
  begin
    c_rst <= '1'; c_start <= '0'; c_idx <= "00";
    wait until rising_edge(c_clk); wait until rising_edge(c_clk);
    c_rst <= '0';
    wait until rising_edge(c_clk);
    c_start <= '1'; wait until rising_edge(c_clk);
    c_start <= '0';
    wait until rising_edge(c_clk);
    for k in 0 to 4 loop                    -- symbols 0..4
      for i in 1 to 8192 loop wait until rising_edge(c_clk); end loop;
    end loop;
    for i in 1 to 3000 loop wait until rising_edge(c_clk); end loop;
    c_idx <= "11";                          -- mid-symbol change (symbol 5)
    for i in 1 to C_HOLD_LEN loop
      wait until rising_edge(c_clk);
    end loop;
    c_idx <= "00";                          -- applies at next boundary (symbol 9)
    wait until c_done;
    wait;
  end process;

  mon_c : process
    variable edges  : int_vec_t := (others => 0);
    variable len    : int_vec_t := (others => 0);
    variable count  : integer := 0;
    variable trans  : integer := 0;
    variable prev   : std_logic := '0';
    variable haveprev : boolean := false;
    variable k      : integer := 0;
  begin
    wait until c_rst = '0';
    wait until c_act = '1';
    while k < NUM_SYMS loop
      wait until rising_edge(c_clk);
      if c_tick = '1' then
        len(k)   := count;
        edges(k) := trans;
        k        := k + 1;
        count    := 1;
        trans    := 0;
        prev     := c_rf;
        haveprev := true;
      else
        if haveprev and prev = '0' and c_rf = '1' then
          trans := trans + 1;
        end if;
        prev := c_rf;
        haveprev := true;
        count := count + 1;
      end if;
    end loop;
    -- (c2) symbols 0..4: index-0 transition count.  Tolerance +-1: each
    -- symbol's internal pairs exclude the boundary-crossing pair, whose
    -- rising/falling phase depends on the accumulator offset (the cyclic
    -- per-symbol count is exactly EXPECT_C_IDX0; the monitor sees it minus
    -- 0 or 1).  The tone classes are thousands apart, so +-1 cannot mask a
    -- missing or double-applied tone increment.
    for i in 0 to 4 loop
      if abs(edges(i) - EXPECT_C_IDX0) > 1 then
        report "FAIL C: symbol " & integer'image(i) & " transitions "
               & integer'image(edges(i)) & " not within +-1 of "
               & integer'image(EXPECT_C_IDX0) severity error;
        c_fail <= c_fail + 1;
      end if;
    end loop;
    -- (e) symbol 5 in progress at the mid-symbol change: unperturbed
    if len(5) /= 8192 then
      report "FAIL C: symbol 5 length perturbed: " & integer'image(len(5))
             severity error;
      c_fail <= c_fail + 1;
    end if;
    if abs(edges(5) - EXPECT_C_IDX0) > 1 then
      report "FAIL C: symbol 5 transitions perturbed: "
             & integer'image(edges(5)) severity error;
      c_fail <= c_fail + 1;
    end if;
    -- symbols 6,7,8 = index 3; symbols 9..12 back to index 0
    for i in 6 to 8 loop
      if abs(edges(i) - EXPECT_C_IDX3) > 1 then
        report "FAIL C: symbol " & integer'image(i) & " transitions "
               & integer'image(edges(i)) & " /= " & integer'image(EXPECT_C_IDX3)
               severity error;
        c_fail <= c_fail + 1;
      end if;
    end loop;
    for i in 9 to 12 loop
      if abs(edges(i) - EXPECT_C_IDX0) > 1 then
        report "FAIL C: symbol " & integer'image(i) & " transitions "
               & integer'image(edges(i)) & " /= " & integer'image(EXPECT_C_IDX0)
               severity error;
        c_fail <= c_fail + 1;
      end if;
    end loop;
    if c_fail = 0 then
      report "tb_wspr_modulator C: PASS - E0=" & integer'image(EXPECT_C_IDX0)
             & " exact, E3=" & integer'image(EXPECT_C_IDX3)
             & " exact, mid-symbol change applied only at the next boundary";
    end if;
    c_done <= true;
    wait;
  end process;

  ---------------------------------------------------------------------------
  -- Overall verdict
  ---------------------------------------------------------------------------
  verdict : process
  begin
    wait until a_done and b_done and c_done;
    if a_fail + b_fail + c_fail = 0 then
      report "tb_wspr_modulator: ALL RUNS PASS (A timing/stop, B fractional "
             & "exactness, C tone application + boundary semantics)";
    else
      report "tb_wspr_modulator: " & integer'image(a_fail + b_fail + c_fail)
             & " check(s) FAILED" severity failure;
    end if;
    wait;
  end process;

end architecture sim;
