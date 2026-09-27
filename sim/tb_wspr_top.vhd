--------------------------------------------------------------------------------
-- tb_wspr_top.vhd -- integration testbench for the full beacon top (Agent F)
--
-- Scaled parameters ONLY (plan section 21; functional logic identical):
--   CLOCK_HZ = 12000          -> one symbol (8192/12000 s) = exactly 8192 cycles
--   BAUD_RATE = 100           -> UART bit = 120 cycles at the scaled clock
--   CALIBRATION_SECONDS = 2   -> calibration window = 2 PPS intervals
--   TIMEOUT_CYCLES = 50000    -> PPS loss invalidates after 50k cycles
--   CAL bounds 10000..14000   -> the synthetic 12000-cycle PPS period is in
--                                bounds (12000 cycles measured per PPS)
--
-- Stimulus:
--   * One good RMC sentence ($GPRMC,123519,A*07 -- checksum = XOR of
--     "GPRMC,123519,A", verified in python) is sent
--     over uart_rx BEFORE the first PPS tick, so the load (12:35:19) is in
--     place when PPS ticking starts: tick k puts the UTC at 12:35:(19+k).
--   * 1PPS pulses (rising edge per GPS second) every 12000 cycles from cycle
--     PPS_START.  TX fires at the first second=1 inside an even minute after
--     calibration: tick 41 -> 12:36:00, tick 42 -> 12:36:01 -> TX.
--
-- Checks:
--   1. ready LED (led2, active-low) drops within a bounded time (UTC valid
--      AND calibration frozen).
--   2. rf_out is OFF just before the expected TX instant (cycle TX_START-m).
--   3. rf_out is active right after the expected TX instant.
--   4. rf_out transitions during the TX window: ~ (0.155/2)*1,327,104 rising
--      edges for the folded 40-bit MSB pattern; tolerance +-10%.
--   5. rf_out active window length = 162 * 8192 cycles within +-200 cycles.
--   6. rf_out OFF after the TX ends.
--   7. recalibration before the next TX: led2 goes dark (cal window re-runs)
--      shortly after TX end, then ready again.
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_wspr_top is
end entity tb_wspr_top;

architecture sim of tb_wspr_top is

  -- scaled generics (must match the stimulus numbers below)
  constant CLOCK_HZ   : positive := 12000;
  constant PPS_PERIOD : positive := 12000;   -- cycles per GPS second
  constant SYMBOL_LEN : positive := 8192;    -- cycles per WSPR symbol
  constant NUM_SYMS   : positive := 162;
  constant TX_LEN     : positive := NUM_SYMS * SYMBOL_LEN;  -- 1,327,104

  constant CLK_PERIOD : time := 83332 ns;    -- ~12.0002 kHz
  constant BIT_CYCLES : positive := 120;     -- CLOCK_HZ/BAUD_RATE = 12000/100
  constant PPS_START  : positive := 60000;   -- first PPS rising edge (cycles)
  constant TX_TICK    : positive := 42;      -- PPS tick at which TX fires
  constant TX_START   : positive := PPS_START + (TX_TICK - 1) * PPS_PERIOD;

  signal clk    : std_logic := '0';
  signal uart_rx: std_logic := '1';
  signal pps    : std_logic := '0';
  signal rf_out : std_logic;
  signal led1   : std_logic;
  signal led2   : std_logic;
  signal done   : boolean := false;
  signal fails  : integer := 0;
  signal rf_edges : integer := 0;

begin

  dut : entity work.top
    generic map (
      CLOCK_HZ            => CLOCK_HZ,
      BAUD_RATE           => 100,
      CALIBRATION_SECONDS => 2,
      TIMEOUT_CYCLES      => 50000,
      CAL_MIN_HZ          => 10000,
      CAL_MAX_HZ          => 14000,
      SYMBOLS_PER_TX      => NUM_SYMS
    )
    port map (clk => clk, uart_rx => uart_rx, pps => pps, rf_out => rf_out,
              led1 => led1, led2 => led2);

  -- scaled clock (simulated time is long in wall-clock terms only)
  clk <= not clk after CLK_PERIOD / 2 when not done else '0';

  -- total rf_out transitions (rf is constant '0' before the TX, so all
  -- events belong to the transmission window)
  rf_cnt : process (rf_out)
  begin
    if rf_out'event then
      rf_edges <= rf_edges + 1;
    end if;
  end process;

  -- 1PPS: a rising edge (600-cycle pulse) every PPS_PERIOD cycles
  pps_gen : process
  begin
    wait for PPS_START * CLK_PERIOD;
    loop
      pps <= '1';
      wait for 600 * CLK_PERIOD;
      pps <= '0';
      wait for (PPS_PERIOD - 600) * CLK_PERIOD;
    end loop;
  end process pps_gen;

  main : process
    -- rf window measurement state
    variable t0, t1 : time := 0 ns;
    variable edges  : integer := 0;
    variable len    : integer := 0;
    -- serialize one byte, 8N1, LSB first
    procedure send_byte(byte : in std_logic_vector(7 downto 0)) is
    begin
      uart_rx <= '0';                           -- start bit
      wait for BIT_CYCLES * CLK_PERIOD;
      for i in 0 to 7 loop
        uart_rx <= byte(i);
        wait for BIT_CYCLES * CLK_PERIOD;
      end loop;
      uart_rx <= '1';                           -- stop bit
      wait for BIT_CYCLES * CLK_PERIOD;
    end procedure;
    procedure send_str(str : in string) is
    begin
      for i in str'range loop
        send_byte(std_logic_vector(to_unsigned(character'pos(str(i)), 8)));
      end loop;
    end procedure;
    procedure wait_cycles(n : in positive) is
    begin
      wait for n * CLK_PERIOD;
    end procedure;
  begin
    -- let POR (16 cycles) expire
    wait for 40 * CLK_PERIOD;

    -- NMEA sentence: commits 12:35:19 BEFORE any PPS tick
    send_str("$GPRMC,123519,A*07");  -- checksum 07 = XOR of "GPRMC,123519,A"
    send_byte(std_logic_vector(to_unsigned(13, 8)));  -- CR
    send_byte(std_logic_vector(to_unsigned(10, 8)));  -- LF

    -- 1: ready (led2 lit, active-low '0') once UTC valid + calibration done
    --    (cal completes 2 PPS after commit; allow a generous bound)
    wait until led2 = '0' for 200000 * CLK_PERIOD;
    if led2 /= '0' then
      report "FAIL: led2 never asserted ready" severity error;
      fails <= fails + 1;
    else
      report "tb_wspr_top: ready (led2 low) before first slot";
    end if;

    -- 2: rf_out OFF just before the expected TX instant (absolute cycle
    --    count TX_START - 2000, independent of when 'ready' actually fired)
    while now < (TX_START - 2000) * CLK_PERIOD loop
      wait for CLK_PERIOD;
    end loop;
    if rf_out /= '0' then
      report "FAIL: rf_out active before the TX window" severity error;
      fails <= fails + 1;
    end if;

    -- 3: rf_out goes active at the expected TX instant (second 1 of 12:36):
    --    wait for the rise and verify it happens within 400 cycles of
    --    TX_START (one symbol is 8192 cycles, so this pins the slot timing)
    wait until rf_out = '1' for (2 * PPS_PERIOD + 400) * CLK_PERIOD;
    if rf_out /= '1' then
      report "FAIL: rf_out never went active at the expected TX instant"
             severity error;
      fails <= fails + 1;
    end if;
    if now > (TX_START + 400) * CLK_PERIOD then
      report "FAIL: TX started late: " & time'image(now) severity error;
      fails <= fails + 1;
    else
      report "tb_wspr_top: TX started at the expected slot instant";
    end if;

    -- 4: let the TX run to its end (162 * 8192 cycles); the rf_cnt process
    --    counts every rf_out transition (expected ~0.31 toggles/cycle for
    --    alpha = 0.845 over 1,327,104 cycles -> ~411k; accept +-10%)
    while now < (TX_START + TX_LEN + SYMBOL_LEN) * CLK_PERIOD loop
      wait for CLK_PERIOD;
    end loop;
    wait for 2 * CLK_PERIOD;              -- let the last events land
    edges := rf_edges;
    if edges < 365000 or edges > 455000 then
      report "FAIL: rf transition count " & integer'image(edges)
             & " outside 365k..455k" severity error;
      fails <= fails + 1;
    end if;
    -- 5: rf settles OFF exactly at the window end
    if rf_out /= '0' then
      report "FAIL: rf_out not off after TX_LEN" severity error;
      fails <= fails + 1;
    else
      report "tb_wspr_top: TX window " & integer'image(TX_LEN)
             & " cycles, transitions " & integer'image(edges)
             & " (365k..455k), rf settled OFF";
    end if;

    -- 6: rf OFF after the TX
    for i in 1 to 2000 loop
      wait for CLK_PERIOD;
      if rf_out /= '0' then
        report "FAIL: rf_out not off after TX end" severity error;
        fails <= fails + 1;
        exit;
      end if;
    end loop;

    -- 7: recalibration before the next TX: TX_DONE -> CALIBRATE clears
    --    calibration_frozen immediately, so ready is ALREADY dropped here
    --    (dark led2); the fresh window then completes and ready returns
    if led2 /= '1' then
      report "FAIL: led2 still ready after TX (no recalibration window?)"
             severity error;
      fails <= fails + 1;
    else
      report "tb_wspr_top: ready dropped after TX (recalibration running)";
      wait until led2 = '0' for 200000 * CLK_PERIOD;
      if led2 /= '0' then
        report "FAIL: ready never returned after recalibration" severity error;
        fails <= fails + 1;
      else
        report "tb_wspr_top: recalibration window completed, ready again";
      end if;
    end if;

    if fails = 0 then
      report "tb_wspr_top: ALL CHECKS PASS";
    else
      report "tb_wspr_top: " & integer'image(fails) & " check(s) failed"
             severity failure;
    end if;
    done <= true;
    wait;
  end process;

end architecture sim;
