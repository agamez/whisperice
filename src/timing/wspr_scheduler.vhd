--------------------------------------------------------------------------------
-- wspr_scheduler.vhd -- WSPR transmission slot scheduler
--
-- Phase 8 of the wspr-icebreaker plan (section 8; TX start offset: spec
-- section 7 = +1.000 s into the even UTC minute; failure behavior: plan
-- section 31).
--
-- FSM (plan section 8):
--
--     WAIT_GPS -> CALIBRATE -> READY -> WAIT_SLOT -> TX -> TX_DONE -> WAIT_SLOT
--
--   WAIT_GPS  : no UTC yet -- NO TX (plan section 31).
--   CALIBRATE : pulse cal_start; the calibration block (clock_calibration)
--               answers cal_valid (frozen value).  cal_error -> retry the
--               window.  Calibration runs before EVERY transmission (plan
--               section 7).
--   READY     : calibrated; wait for a slot.
--   WAIT_SLOT : even UTC minute AND second = 1 (spec section 7: +1.000 s)
--               AND slot selected by slot_mask -> TX.
--   TX        : tx_enable pulses (1 cycle) to the modulator tx_start; the
--               symbol index advances on each symbol_tick from the modulator
--               (the modulator owns symbol timing); after SYMBOLS_PER_TX
--               ticks -> TX_DONE.
--   TX_DONE   : 1-cycle state -> WAIT_SLOT.
--
-- Failure behavior (plan section 31): utc_valid drops -> back to WAIT_GPS
-- (no new TX); calibration invalid/error -> CALIBRATE; reset -> tx off.
-- A mid-TX reset kills RF via the modulator's own reset behavior.
--
-- slot_mask selects which even-minute slots of the hour transmit: bit i
-- corresponds to minute 2*i (initial default: every slot, plan section 12;
-- WSPR etiquette suggests a fraction of slots later on).  The slot index is
-- minute/2 of the CURRENT minute when second becomes 1.
--
-- VHDL-93 only.
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity wspr_scheduler is
  generic (
    SYMBOLS_PER_TX : positive := 162
  );
  port (
    clk          : in  std_logic;
    rst          : in  std_logic;
    -- slot selection: bit i enables the even minute 2*i of each hour
    -- (runtime-configurable per plan section 12; default all-ones from top)
    slot_mask    : in  std_logic_vector(0 to 29);
    -- UTC from gps_time.vhd
    utc_valid    : in  std_logic;
    even_minute  : in  std_logic;
    second       : in  natural range 0 to 59;
    minute       : in  natural range 0 to 59;
    -- calibration handshake (clock_calibration.vhd)
    cal_valid    : in  std_logic;
    cal_error    : in  std_logic;
    cal_start    : out std_logic;
    -- modulator interface (wspr_modulator.vhd)
    tx_enable    : out std_logic;       -- 1-cycle pulse -> modulator tx_start
    symbol_tick  : in  std_logic;       -- 1 pulse per symbol from the modulator
    tx_active    : in  std_logic;       -- modulator busy (diagnostics)
    symbol_index : out natural range 0 to SYMBOLS_PER_TX - 1;
    -- diagnostics (plan section 32)
    state_o      : out natural range 0 to 5
  );
end entity wspr_scheduler;

architecture rtl of wspr_scheduler is

  type state_t is (WAIT_GPS, CALIBRATE, READY, WAIT_SLOT, TX, TX_DONE);
  signal state : state_t := WAIT_GPS;

  signal cal_start_r : std_logic := '0';
  signal tx_enable_r : std_logic := '0';
  signal sym_cnt     : natural range 0 to SYMBOLS_PER_TX := 0;
  signal restart     : boolean := false;   -- retry calibration after error

begin

  process (clk)
  begin
    if rising_edge(clk) then
      cal_start_r <= '0';
      tx_enable_r <= '0';

      if rst = '1' then
        state       <= WAIT_GPS;
        sym_cnt     <= 0;
        cal_start_r <= '0';
        tx_enable_r <= '0';
      else
        case state is

          when WAIT_GPS =>
            if utc_valid = '1' then
              state       <= CALIBRATE;
              cal_start_r <= '1';         -- calibrate before EVERY TX (plan 7)
              restart     <= false;
            end if;

          when CALIBRATE =>
            -- calibration answers asynchronously via cal_valid/cal_error
            if cal_error = '1' then
              restart     <= true;        -- request a fresh window
            elsif cal_valid = '1' and restart = false then
              state       <= READY;
            elsif cal_valid = '1' and restart = true then
              restart     <= false;
              cal_start_r <= '1';         -- re-run the calibration window
            end if;

          when READY =>
            if utc_valid = '0' then
              state <= WAIT_GPS;          -- GPS lost: no transmission
            else
              state <= WAIT_SLOT;
            end if;

          when TX =>
            if utc_valid = '0' then
              -- GPS lost mid-TX: finish the transmission in progress but do
              -- not start a new one (plan section 31: do not START a new TX;
              -- an RF cut mid-symbol would harm the decode more than the
              -- missing second matters).  Documented decision; revisit in
              -- docs/protocol.md if field tests disagree.
              null;
            end if;
            if symbol_tick = '1' then
              if sym_cnt = SYMBOLS_PER_TX - 1 then
                state <= TX_DONE;       -- last symbol just ended
              else
                sym_cnt <= sym_cnt + 1; -- advance to the next symbol
              end if;
            end if;

          when TX_DONE =>
            state <= WAIT_SLOT;

          when WAIT_SLOT =>
            if utc_valid = '0' then
              state <= WAIT_GPS;          -- recalibrate before the next TX
            elsif even_minute = '1' and second = 1 then
              if slot_mask(minute / 2) = '1' then
                state       <= TX;
                tx_enable_r <= '1';
                sym_cnt     <= 0;
              end if;
            end if;

        end case;
      end if;
    end if;
  end process;

  cal_start    <= cal_start_r;
  tx_enable    <= tx_enable_r;
  symbol_index <= sym_cnt;
  state_o      <= state_t'pos(state);

end architecture rtl;
