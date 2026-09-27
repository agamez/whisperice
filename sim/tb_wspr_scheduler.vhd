--------------------------------------------------------------------------------
-- tb_wspr_scheduler.vhd -- testbench for wspr_scheduler (plan sections 8, 12,
-- 31; spec section 7: TX starts at second 1 of an even UTC minute)
--
-- Checks (timing scaled: seconds are driven as values, no long waits):
--   1. WAIT_GPS until utc_valid; cal_start pulses once in CALIBRATE
--   2. calibration error -> retry (second cal_start)
--   3. cal_valid -> READY -> WAIT_SLOT
--   4. NO tx_enable while second=0 (even minute rolling over)
--   5. tx_enable exactly when even_minute and second=1 and mask bit set
--   6. 162 symbol_ticks -> TX_DONE -> WAIT_SLOT (tx_active ignored by FSM
--      other than as a diagnostic; the modulator owns symbol timing)
--   7. slot_mask gating: masked slot -> no TX
--   8. utc_valid drop -> back to WAIT_GPS (recalibrates before next TX)
--   9. reset during TX -> immediate stop (no tx_enable, index cleared)
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_wspr_scheduler is
end entity tb_wspr_scheduler;

architecture sim of tb_wspr_scheduler is

  constant NUM_SYMS : positive := 162;

  signal clk   : std_logic := '0';
  signal rst   : std_logic := '1';
  signal uv    : std_logic := '0';
  signal meven : std_logic := '0';
  signal sec   : natural range 0 to 59 := 0;
  signal min   : natural range 0 to 59 := 0;
  signal calv  : std_logic := '0';
  signal calerr: std_logic := '0';
  signal cals  : std_logic;
  signal txe   : std_logic;
  signal tick  : std_logic := '0';
  signal act   : std_logic := '0';
  signal sidx  : natural range 0 to NUM_SYMS-1;
  signal mask  : std_logic_vector(0 to 29) := (others => '1');
  signal st    : natural range 0 to 5;
  signal done  : boolean := false;
  signal fails : integer := 0;

begin

  dut : entity work.wspr_scheduler
    generic map (SYMBOLS_PER_TX => NUM_SYMS)
    port map (clk => clk, rst => rst, slot_mask => mask, utc_valid => uv,
              minute_even => meven,
              second => sec, minute => min, cal_valid => calv,
              cal_error => calerr, cal_start => cals, tx_enable => txe,
              symbol_tick => tick, tx_active => act, symbol_index => sidx,
              state_o => st);

  clk <= not clk after 500 ns when not done else '0';

  main : process
    procedure cycle is
    begin
      wait until rising_edge(clk);
    end procedure;
    procedure run_tx_ticks is
    begin
      for i in 1 to NUM_SYMS loop
        tick <= '1'; cycle; tick <= '0'; cycle;
      end loop;
    end procedure;
    procedure expect_tx(want : in boolean; tag : in string) is
    begin
      if want and txe /= '1' then
        report "FAIL " & tag & ": tx_enable /= 1" severity error;
        fails <= fails + 1;
      elsif not want and txe = '1' then
        report "FAIL " & tag & ": tx_enable = 1 unexpectedly" severity error;
        fails <= fails + 1;
      end if;
    end procedure;
  begin
    rst <= '1';
    wait for 2 us;
    cycle;
    rst <= '0';
    wait for 1 us;

    -- 1. WAIT_GPS: no cal_start while no UTC
    if cals = '1' then
      report "FAIL: cal_start before utc_valid" severity error;
      fails <= fails + 1;
    end if;
    uv <= '1'; cycle; cycle;
    if cals /= '1' then
      report "FAIL: cal_start not pulsed after utc_valid" severity error;
      fails <= fails + 1;
    end if;
    cycle;

    -- 2. calibration error (cal_error RISES) -> cal_start retry pulse
    calerr <= '1'; cycle; cycle;
    if cals /= '1' then
      report "FAIL: no cal_start retry on cal_error edge" severity error;
      fails <= fails + 1;
    end if;
    calerr <= '0'; cycle;
    -- clean window completes: cal_valid RISES -> READY -> WAIT_SLOT
    calv <= '1'; cycle; cycle; cycle;  -- rising edge -> READY, then WAIT_SLOT
    if st /= 3 then
      report "FAIL: state " & integer'image(st) & " /= 3 (WAIT_SLOT) after"
             & " clean calibration" severity error;
      fails <= fails + 1;
    end if;
    -- stale level must NOT matter later: leave calv high through the
    -- GPS-drop/return test below (adversarial-review finding)

    -- 4/5. slot timing: minute_even stays high for the whole even minute
    --      (12:36:xx); no TX at second 0, TX at second 1
    min <= 2; sec <= 0; meven <= '1'; cycle; cycle;
    expect_tx(false, "second 0");
    sec <= 1; cycle;
    cycle;   -- txe was assigned at the previous edge: sample one edge later
             -- (registered outputs read at delta-0 show the previous value)
    expect_tx(true, "second 1");
    cycle;                                 -- pulse ends
    if txe /= '0' then
      report "FAIL: tx_enable not a 1-cycle pulse" severity error;
      fails <= fails + 1;
    end if;

    -- 6. run the 162 symbols
    run_tx_ticks;
    -- real UTC advances during the 110.592 s TX: leave the firing condition
    sec <= 2; meven <= '0'; cycle;
    -- plan section 7: TX_DONE -> CALIBRATE with a fresh cal_start (the
    -- previous calv level is stale and must be ignored).  cal_start is a
    -- 1-cycle pulse set at TX_DONE+1: visible NOW (one cycle after the last
    -- tick), gone one cycle later.
    if cals /= '1' then
      report "FAIL: no cal_start for the second TX" severity error;
      fails <= fails + 1;
    end if;
    cycle;
    if sidx /= NUM_SYMS - 1 then
      report "FAIL: final symbol_index " & integer'image(sidx)
             & " /= " & integer'image(NUM_SYMS-1) severity error;
      fails <= fails + 1;
    end if;
    if st /= 1 then
      report "FAIL: state " & integer'image(st) & " /= 1 (CALIBRATE) after TX"
             severity error;
      fails <= fails + 1;
    end if;
    -- fresh window: drop the stale level, then raise it (new rising edge)
    calv <= '0'; cycle; cycle;
    calv <= '1'; cycle; cycle; cycle;
    if st /= 3 then
      report "FAIL: state " & integer'image(st) & " /= 3 (WAIT_SLOT) after"
             & " second calibration" severity error;
      fails <= fails + 1;
    end if;

    -- 7. slot mask gating: minute 4 -> slot 2; mask it off
    mask(2) <= '0';
    min <= 4; sec <= 0; meven <= '1'; cycle; cycle;
    sec <= 1; cycle; cycle;
    expect_tx(false, "masked slot");
    sec <= 2; cycle;                       -- leave the firing condition first
    mask(2) <= '1';                        -- (else re-masking at second=1 fires)

    -- 8. utc_valid drop -> WAIT_GPS -> recalibration on return.
    --    calv is STILL HIGH from the previous window (stale): the scheduler
    --    must wait for a fresh rising edge, not the level.
    uv <= '0'; cycle; cycle;
    if st /= 0 then
      report "FAIL: state " & integer'image(st) & " /= 0 (WAIT_GPS) after"
             & " utc_valid drop" severity error;
      fails <= fails + 1;
    end if;
    uv <= '1'; cycle; cycle;
    if cals /= '1' then
      report "FAIL: recalibration not requested after GPS return" severity error;
      fails <= fails + 1;
    end if;
    cycle; cycle;
    if st /= 1 then
      report "FAIL: stale cal_valid produced READY (state "
             & integer'image(st) & " /= 1 CALIBRATE)" severity error;
      fails <= fails + 1;
    end if;
    calv <= '0'; cycle;                    -- fresh window now completes
    calv <= '1'; cycle; cycle; cycle;
    if st /= 3 then
      report "FAIL: state " & integer'image(st) & " /= 3 (WAIT_SLOT) after"
             & " fresh post-drop calibration" severity error;
      fails <= fails + 1;
    end if;

    -- 9. reset during TX: get to TX then reset
    min <= 6; sec <= 0; meven <= '1'; cycle; cycle;
    sec <= 1; cycle;
    cycle;                                 -- sample txe one edge after firing
    expect_tx(true, "second TX");
    cycle;
    tick <= '1'; cycle; tick <= '0'; cycle;  -- a few symbols
    tick <= '1'; cycle; tick <= '0'; cycle;
    rst <= '1'; cycle;
    cycle;   -- registered outputs: sample one edge after reset is applied
    if txe /= '0' then
      report "FAIL: tx_enable high after reset mid-TX" severity error;
      fails <= fails + 1;
    end if;
    if sidx /= 0 then
      report "FAIL: symbol_index not cleared by reset" severity error;
      fails <= fails + 1;
    end if;

    if fails = 0 then
      report "tb_wspr_scheduler: PASS - handshake, slot timing, gating,"
             & " GPS-drop recalibration, reset mid-TX";
    else
      report "tb_wspr_scheduler: " & integer'image(fails)
             & " check(s) failed" severity failure;
    end if;
    done <= true;
    wait;
  end process;

end architecture sim;
