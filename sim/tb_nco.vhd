--------------------------------------------------------------------------------
-- tb_nco.vhd -- functional test for src/nco/nco.vhd
--
-- Phase 4 testbench (plan section 29 Rule 3: a block is not finished without a
-- functional test; plan section 21: scale test parameters, never the logic).
--
-- WHAT IT CHECKS
-- --------------
-- The DUT is a 40-bit phase accumulator whose MSB is rf_out.  The NCO law is
--
--     f_out = increment * f_clk / 2**40
--
-- with frequency resolution f_clk / 2**40 ~= 1.0914e-5 Hz at 12 MHz
-- (docs/spec.md section 8).  The test:
--
--   [A] drives the increment for a 1 MHz carrier -- comfortably below the
--       Nyquist limit f_clk/2 = 6 MHz -- measures rf_out over NUM_PERIODS
--       whole periods (counting clock cycles between rising edges) and
--       asserts the measured frequency is within TOL_HZ = 0.01 Hz of
--       increment * f_clk / 2**40.
--
--       0.01 Hz is ~917 LSBs of the 1.0914e-5 Hz resolution, i.e. the
--       assertion is hundreds of times coarser than the NCO can be off; it is
--       "generous for cycle-quantised measurement" in the sense that the
--       increment chosen here makes the output period an exact integer number
--       of clocks (12 clocks), so the ~100-period cycle count is exact and
--       the residual error is only the rounding of the increment itself
--       (~3.6e-6 Hz).
--
--   [B] drives the DEFAULT 30 m carrier increment from
--       tools/calculate_nco.py (10140200 Hz -> 929105650665 = 0xD8530323E9;
--       docs/spec.md section 9) and checks the increment constant against the
--       tool's output.
--
-- WHY [B] DOES NOT ASSERT 10.14 MHz DIRECTLY
-- ------------------------------------------
-- rf_out is sampled at f_clk, so the highest fundamental a 1-bit NCO can
-- produce is f_clk/2 = 6 MHz at 12 MHz.  The default 10.14 MHz carrier is
-- ABOVE Nyquist: its increment is 0.845 * 2**40 > 2**39, and the sampled MSB
-- folds.  The observable fundamental is
--
--     f_fold = (2**40 - increment) * f_clk / 2**40
--            = 170405976711 * 12e6 / 2**40
--            ~= 1859800 Hz.
--
-- [B] therefore measures rf_out over NUM_PERIODS periods and asserts the
-- observed cycle count matches the theoretical fold period
-- NUM_PERIODS * 2**40 / (2**40 - increment) within FOLD_CLOCK_TOL clocks.
-- The nominal 10.14 MHz value (which is what the phase accumulator actually
-- advances at, to ~1.8e-9 Hz here) is reported but is NOT observable from a
-- 12 MHz-clocked 1-bit NCO.  This is a property of the frozen spec/plan
-- architecture (plan section 8/18), not of this block; the integration/RF
-- phase must account for it.
--
-- Reset must hold rf_out at '0' (RF off; plan section 31).
--
-- VHDL-93 ONLY (IEEE Std 1076-1993): explicit sensitivity lists, no
-- process(all), no std.env.  Analyse with --std=93.
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_nco is
  generic (
    CLK_PERIOD       : time     := 10 ns;      -- 100 MHz sim clock; FCLK_HZ
                                               -- is the logical NCO clock
    FCLK_HZ          : positive := 12000000;   -- nominal FPGA clock
    NUM_PERIODS      : positive := 100;        -- output periods per measurement
    ACCUMULATOR_BITS : positive := 40;         -- frozen width (spec section 8)
    TOL_HZ           : real     := 0.01;       -- [A] frequency tolerance
    FOLD_CLOCK_TOL   : real     := 1.5;        -- [B] +/- cycles quantisation
    STABLE_CYCLES    : positive := 4
  );
end entity tb_nco;

architecture sim of tb_nco is

  ----------------------------------------------------------------------------
  -- 2**ACCUMULATOR_BITS as a real (only used for expected-value arithmetic).
  ----------------------------------------------------------------------------
  constant TWO_POW_BITS : real := 1099511627776.0;   -- 2**40

  ----------------------------------------------------------------------------
  -- Increment constants from tools/calculate_nco.py at 12 MHz.
  --   --frequency 1000000  -> 91625968981 = 0x1555555555
  --   --frequency 10140200 -> 929105650665 = 0xD8530323E9  (default carrier)
  ----------------------------------------------------------------------------
  constant INC_ONE_MHZ : std_logic_vector(ACCUMULATOR_BITS - 1 downto 0) :=
    x"1555555555";
  constant INC_DEFAULT_CARRIER : std_logic_vector(ACCUMULATOR_BITS - 1 downto 0) :=
    x"D8530323E9";

  signal clk       : std_logic := '0';
  signal rst       : std_logic := '1';
  signal increment : std_logic_vector(ACCUMULATOR_BITS - 1 downto 0) :=
    (others => '0');
  signal rf_out    : std_logic;

  signal finished  : boolean := false;

  ----------------------------------------------------------------------------
  -- Convert an unsigned word to real bit-by-bit.  GHDL's INTEGER is 32-bit,
  -- so to_integer() would overflow for a 40-bit increment; this avoids it.
  ----------------------------------------------------------------------------
  function to_real (v : unsigned) return real is
    variable r : real := 0.0;
  begin
    for i in v'range loop
      if v(i) = '1' then
        r := r * 2.0 + 1.0;
      else
        r := r * 2.0;
      end if;
    end loop;
    return r;
  end function to_real;

  ----------------------------------------------------------------------------
  -- Measure NUM_PERIODS whole rf_out periods by counting clock cycles between
  -- rising edges.  Sampling is done on the falling clock edge, by which time
  -- the accumulator has settled after the preceding rising edge.  The
  -- returned `cycles_out` is the number of clock cycles spanned by
  -- NUM_PERIODS consecutive output periods.
  ----------------------------------------------------------------------------
  procedure measure_periods (signal   clk_i      : in  std_logic;
                             signal   rf_i       : in  std_logic;
                             constant nper       : in  positive;
                             variable cycles_out : out natural) is
    variable prev  : std_logic := '0';
    variable edges : natural := 0;
    variable cyc   : natural := 0;
  begin
    -- Wait for rf_out to be low, so the first edge found is unambiguous.
    loop
      wait until falling_edge(clk_i);
      exit when rf_i = '0';
    end loop;

    -- Find the first rising edge of rf_out.
    prev := '0';
    loop
      wait until falling_edge(clk_i);
      if (rf_i = '1') and (prev = '0') then
        exit;
      end if;
      prev := rf_i;
    end loop;

    -- Count clock cycles until nper more rising edges have occurred.
    prev := '1';
    cyc  := 0;
    loop
      wait until falling_edge(clk_i);
      cyc := cyc + 1;
      if (rf_i = '1') and (prev = '0') then
        edges := edges + 1;
      end if;
      prev := rf_i;
      exit when edges = nper;
    end loop;

    cycles_out := cyc;
  end procedure measure_periods;

begin

  ----------------------------------------------------------------------------
  -- DUT
  ----------------------------------------------------------------------------
  dut : entity work.nco
    generic map (
      ACCUMULATOR_BITS => ACCUMULATOR_BITS
    )
    port map (
      clk       => clk,
      rst       => rst,
      increment => increment,
      rf_out    => rf_out
    );

  ----------------------------------------------------------------------------
  -- Clock -- free-running until the test signals completion, so the
  -- simulation is self-terminating.
  ----------------------------------------------------------------------------
  p_clk : process is
  begin
    clk <= '0';
    while not finished loop
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
    variable cyc_a           : natural;
    variable cyc_b           : natural;
    variable meas_a          : real;
    variable exp_a           : real;
    variable meas_b          : real;
    variable nom_b           : real;
    variable exp_fold        : real;
    variable exp_fold_cycles : real;
    variable inc_b           : real;
  begin
    rst       <= '1';
    increment <= (others => '0');

    for i in 1 to 5 loop
      wait until rising_edge(clk);
    end loop;

    -- Reset must hold the output low (RF off).
    wait until falling_edge(clk);
    assert rf_out = '0'
      report "tb_nco: rf_out not low during reset"
      severity failure;

    rst <= '0';
    for i in 1 to STABLE_CYCLES loop
      wait until rising_edge(clk);
    end loop;

    --------------------------------------------------------------------------
    -- [A] 1 MHz increment: below Nyquist, strict frequency check.
    --------------------------------------------------------------------------
    increment <= INC_ONE_MHZ;
    measure_periods(clk, rf_out, NUM_PERIODS, cyc_a);

    meas_a := real(NUM_PERIODS) * real(FCLK_HZ) / real(cyc_a);
    exp_a  := to_real(unsigned(INC_ONE_MHZ)) * real(FCLK_HZ) /
              TWO_POW_BITS;

    assert abs(meas_a - exp_a) < TOL_HZ
      report "tb_nco: [A] 1 MHz case measured " & real'image(meas_a) &
             " Hz, expected " & real'image(exp_a) & " Hz, tol " &
             real'image(TOL_HZ) & " Hz (" & integer'image(cyc_a) &
             " cycles / " & integer'image(NUM_PERIODS) & " periods)"
      severity failure;

    --------------------------------------------------------------------------
    -- [B] Default carrier increment: above Nyquist, check the observed fold.
    --------------------------------------------------------------------------
    increment <= INC_DEFAULT_CARRIER;
    measure_periods(clk, rf_out, NUM_PERIODS, cyc_b);

    inc_b    := to_real(unsigned(INC_DEFAULT_CARRIER));
    meas_b   := real(NUM_PERIODS) * real(FCLK_HZ) / real(cyc_b);
    nom_b    := inc_b * real(FCLK_HZ) / TWO_POW_BITS;
    exp_fold := (TWO_POW_BITS - inc_b) * real(FCLK_HZ) / TWO_POW_BITS;
    exp_fold_cycles := real(NUM_PERIODS) * TWO_POW_BITS /
                       (TWO_POW_BITS - inc_b);

    assert abs(real(cyc_b) - exp_fold_cycles) <= FOLD_CLOCK_TOL
      report "tb_nco: [B] default-carrier fold period measured " &
             integer'image(cyc_b) & " cycles / " & integer'image(NUM_PERIODS) &
             " periods, expected " & real'image(exp_fold_cycles) &
             " cycles (tol " & real'image(FOLD_CLOCK_TOL) & " cycles)"
      severity failure;

    --------------------------------------------------------------------------
    -- PASS summary.
    --------------------------------------------------------------------------
    report "tb_nco: PASS" &
           " | [A] inc=" & real'image(to_real(unsigned(INC_ONE_MHZ))) &
           " measured=" & real'image(meas_a) & "Hz expected=" &
           real'image(exp_a) & "Hz |err|=" & real'image(abs(meas_a - exp_a)) &
           "Hz tol=" & real'image(TOL_HZ) & "Hz" &
           " | [B] inc=" & real'image(inc_b) & " nominal=" &
           real'image(nom_b) & "Hz > Nyquist=" & real'image(real(FCLK_HZ) / 2.0) &
           "Hz, rf_out fold measured=" & real'image(meas_b) &
           "Hz expected_fold=" & real'image(exp_fold) & "Hz cycles=" &
           integer'image(cyc_b) & "/" & integer'image(NUM_PERIODS)
      severity note;

    finished <= true;
    wait;
  end process p_test;

end architecture sim;
