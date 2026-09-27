--------------------------------------------------------------------------------
-- wspr_scheduler.vhd -- WSPR transmission slot scheduler
--
-- Phase 8 of the wspr-icebreaker plan (section 8; TX start offset: spec
-- section 7 = +1.000 s into the even UTC minute; failure behavior: plan
-- section 31).
--
-- FSM (plan section 8):
--
--     WAIT_GPS -> CALIBRATE -> READY -> WAIT_SLOT -> TX -> TX_DONE -> CALIBRATE -> ...
--
--   WAIT_GPS  : no UTC yet -- NO TX (plan section 31).
--   CALIBRATE : pulse cal_start; the calibration block (clock_calibration)
--               completes a window and RAISES cal_valid (in-bounds) or
--               cal_error (out-of-bounds).  Because both levels persist after
--               the window, only their RISING EDGES are accepted here; on a
--               cal_error edge the window is re-pulsed (retry).  Calibration
--               runs before EVERY transmission (plan section 7).
--   READY     : freshly calibrated; wait for a slot.
--   WAIT_SLOT : minute_even AND second = 1 (spec section 7: +1.000 s into the
--               even UTC minute) AND slot_mask selected -> TX.
--   TX        : tx_enable pulses (1 cycle) to the modulator tx_start; the
--               symbol index advances on each symbol_tick from the modulator
--               (the modulator owns symbol timing); after SYMBOLS_PER_TX
--               ticks -> TX_DONE.  NOTE: symbol_index selects which of the
--               162 channel symbols is next; integration muxes the codec's
--               tone vector (wspr_symbols) with it to feed the modulator's
--               2-bit symbol_index input.
--   TX_DONE   : 1-cycle state -> CALIBRATE (recalibrate before the next TX,
--               plan section 7).
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
    minute_even  : in  std_logic;       -- valid AND even minute (whole minute)
    second       : in  natural range 0 to 59;
    minute       : in  natural range 0 to 59;
    -- calibration handshake (clock_calibration.vhd).  cal_valid/cal_error are
    -- LEVELS that persist after a window; this FSM acts only on their EDGES
    -- so a stale level can never substitute for a fresh calibration window
    -- (plan section 7: calibrate before EVERY transmission).
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
  signal cal_v_prev  : std_logic := '0';   -- rising-edge detects (fresh window)
  signal cal_e_prev  : std_logic := '0';   -- retry calibration after error

begin

  process (clk)
  begin
    if rising_edge(clk) then
      cal_start_r <= '0';
      tx_enable_r <= '0';

      -- edge detects on the calibration handshake (levels persist!)
      cal_v_prev <= cal_valid;
      cal_e_prev <= cal_error;

      if rst = '1' then
        state       <= WAIT_GPS;
        sym_cnt     <= 0;
        cal_start_r <= '0';
        tx_enable_r <= '0';
        cal_v_prev  <= '0';
        cal_e_prev  <= '0';
      else
        case state is

          when WAIT_GPS =>
            if utc_valid = '1' then
              state       <= CALIBRATE;
              cal_start_r <= '1';         -- calibrate before EVERY TX (plan 7)
            end if;

          when CALIBRATE =>
            -- fresh window finished in-bounds: cal_valid RISES
            if cal_valid = '1' and cal_v_prev = '0' then
              state <= READY;
            -- window finished out-of-bounds: cal_error RISES -> re-run
            elsif cal_error = '1' and cal_e_prev = '0' then
              cal_start_r <= '1';
            end if;

          when READY =>
            if utc_valid = '0' then
              state <= WAIT_GPS;          -- GPS lost: no transmission
            else
              state <= WAIT_SLOT;
            end if;
            -- NOTE: a stale cal_valid level cannot re-enter READY; only a
            -- fresh rising edge in CALIBRATE does.

          when TX =>
            -- GPS lost mid-TX: finish the transmission in progress but do
            -- not start a new one (plan section 31: do not START a new TX;
            -- an RF cut mid-symbol would harm the decode more than the
            -- missing second matters).  Deliberately NO assignment here --
            -- the modulator keeps counting symbol_tick, and blocking the
            -- NEXT start happens where tx_enable is produced (review
            -- finding S3: the former `if utc_valid='0' then null` hid this
            -- decision in a no-op).  Revisit docs/protocol.md if field
            -- tests disagree.
            if symbol_tick = '1' then
              if sym_cnt = SYMBOLS_PER_TX - 1 then
                state <= TX_DONE;       -- last symbol just ended
              else
                sym_cnt <= sym_cnt + 1; -- advance to the next symbol
              end if;
            end if;

          when TX_DONE =>
            -- plan section 7: calibrate before EVERY transmission
            state       <= CALIBRATE;
            cal_start_r <= '1';

          when WAIT_SLOT =>
            if utc_valid = '0' then
              state <= WAIT_GPS;          -- recalibrate before the next TX
            elsif minute_even = '1' and second = 1 then
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
