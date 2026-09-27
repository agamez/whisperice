--------------------------------------------------------------------------------
-- top.vhd -- Autonomous WSPR beacon for the iCEBreaker (full integration)
--
-- Integration of all blocks (Agent F, plan sections 8/17/18/28; contracts in
-- docs/gps.md; frozen constants in docs/spec.md):
--
--   PmodGPS UART --> gps_uart --> gps_parser --> gps_time --+
--   PmodGPS 1PPS --> pps_measure --> clock_calibration -----+--> wspr_scheduler
--                                                                    |
--   wspr_message -> wspr_fec -> wspr_interleave -> wspr_symbols --> wspr_modulator --> rf_out
--                                     (162-tone constant; the modulator
--                                      indexes this vector itself)
--
-- Signal flow:
--   * GPS NMEA bytes arrive on uart_rx, are framed by gps_uart, parsed to
--     UTC by gps_parser (checksum-verified RMC only) and kept by gps_time,
--     which advances the second on each 1PPS tick (1PPS is the primary time
--     reference, plan section 11).
--   * pps_measure counts FPGA clock cycles between 1PPS edges; the scheduler
--     orders clock_calibration to average CALIBRATION_SECONDS of them before
--     EVERY transmission (plan section 7) and gates the TX on success
--     (calibration_valid, plan section 31).
--   * The WSPR codec (wspr_message -> wspr_fec -> wspr_interleave ->
--     wspr_symbols) folds to a constant 162-tone vector for the configured
--     message (default bench message "K1ABC FN42 37" -- SIMULATION/BENCH USE
--     ONLY, never radiated; real operation requires the operator's own
--     callsign, plan section 25).  The modulator owns the symbol counter and
--     indexes this vector itself (no external mux -- review finding M1).
--   * wspr_scheduler fires the TX at second = 1 of an even UTC minute
--     (spec section 7: +1.000 s) when the slot_mask selects the slot; the
--     modulator emits the continuous-phase 4-FSK carrier on rf_out.
--
-- Pins (constraints/icebreaker.pcf; official icebreaker PCF
-- icebreaker-examples @ cb9e674c, docs/spec.md section 11):
--   clk 35, led1 11 (LEDR_N, active-low), led2 37 (LEDG_N, active-low),
--   uart_rx 47 (PMOD1A P1A3 <- PmodGPS TX / NMEA output), pps 45 (P1A4
--   1PPS), rf_out 28 (P1B10).
--
-- LED semantics (plan section 32 diagnostics):
--   led1 : heartbeat -- blinks ~1 Hz from the 12 MHz clock (board alive)
--   led2 : '0' (lit) while the beacon is ready to transmit (UTC valid AND
--          calibration valid); '1' (dark) during recalibration or on a
--          calibration error.
--
-- RF note (documented physical property, docs/protocol.md section 8): with a
-- 12 MHz-sampled 1-bit output the default 10.1402 MHz carrier folds (Nyquist);
-- band selection is addressed in docs/rf.md.  Do not "fix" this in RTL.
--
-- All generics are pass-throughs so testbenches can scale parameters without
-- changing the functional logic (plan section 21).
-- VHDL-93 only (explicit sensitivity lists, no process(all)).
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity top is
  generic (
    CLOCK_HZ            : positive := 12000000;
    BAUD_RATE           : positive := 9600;
    CALIBRATION_SECONDS : positive := 8;
    TIMEOUT_CYCLES      : positive := 24000000;
    CAL_MIN_HZ          : natural  := 11988000;
    CAL_MAX_HZ          : natural  := 12012000;
    SYMBOLS_PER_TX      : positive := 162;
    CARRIER_INCREMENT   : std_logic_vector(39 downto 0) := x"D8530323E9";
    -- Exact half of the rounded tone-spacing increment (12000/8192 Hz);
    -- 2*67109 = 134218 differs from the single-step increment 134217 by
    -- +1 LSB ~ 1.1e-5 Hz -- derivation in the wspr_modulator.vhd header and
    -- tools/calculate_nco.py (review finding S4).
    HALF_TONE_INCREMENT : natural := 67109;
    -- NCO phase-accumulator width.  Pass-through so testbenches can scale
    -- parameters without changing the functional logic (plan section 21);
    -- the synthesis default is 40 bits (spec section 9).
    ACCUMULATOR_BITS    : positive := 40
  );
  port (
    clk     : in  std_logic;
    uart_rx : in  std_logic;
    pps     : in  std_logic;
    rf_out  : out std_logic;
    led1    : out std_logic;
    led2    : out std_logic
  );
end entity top;

architecture rtl of top is

  ---------------------------------------------------------------------------
  -- Bench message "K1ABC FN42 37" (spec section 2; payload F7 0C 23 8B 0D 19
  -- 40).  SIMULATION/BENCH ONLY -- never radiate an example callsign (plan
  -- section 25).  A production build replaces these constants with the
  -- licensed operator's callsign/grid/power.
  ---------------------------------------------------------------------------
  constant MSG_CALL0 : std_logic_vector(7 downto 0) := x"4B";  -- 'K'
  constant MSG_CALL1 : std_logic_vector(7 downto 0) := x"31";  -- '1'
  constant MSG_CALL2 : std_logic_vector(7 downto 0) := x"41";  -- 'A'
  constant MSG_CALL3 : std_logic_vector(7 downto 0) := x"42";  -- 'B'
  constant MSG_CALL4 : std_logic_vector(7 downto 0) := x"43";  -- 'C'
  constant MSG_CALL5 : std_logic_vector(7 downto 0) := x"20";  -- ' '
  constant MSG_GRID0 : std_logic_vector(7 downto 0) := x"46";  -- 'F'
  constant MSG_GRID1 : std_logic_vector(7 downto 0) := x"4E";  -- 'N'
  constant MSG_GRID2 : std_logic_vector(7 downto 0) := x"34";  -- '4'
  constant MSG_GRID3 : std_logic_vector(7 downto 0) := x"32";  -- '2'
  constant MSG_POWER : std_logic_vector(6 downto 0) := "0100101";  -- 37 dBm

  -- Slot mask: bit i enables the even UTC minute 2*i of each hour (plan
  -- section 12).  Initial default: transmit on EVERY slot; WSPR etiquette
  -- suggests reducing the duty cycle later (plan section 35).
  constant SLOT_MASK_C : std_logic_vector(0 to 29) := (others => '1');

  -- Heartbeat divider: hb toggles every HEARTBEAT_DIV2 cycles (6,000,000 at
  -- 12 MHz = 0.5 s), so led1 has period 1 s (0.5 s high, 0.5 s low).
  constant HEARTBEAT_DIV2 : positive := 6000000;

  -- gps_uart -> gps_parser
  signal uart_data  : std_logic_vector(7 downto 0);
  signal uart_dv    : std_logic;
  -- gps_parser -> gps_time
  signal time_strobe : std_logic;
  signal p_hour      : natural range 0 to 23;
  signal p_minute    : natural range 0 to 59;
  signal p_second    : natural range 0 to 59;
  signal p_warning   : std_logic;
  -- pps_measure -> clock_calibration / gps_time
  signal pps_tick    : std_logic;
  signal measured    : std_logic_vector(24 downto 0);
  signal meas_valid  : std_logic;
  -- gps_time -> scheduler
  signal utc_valid   : std_logic;
  signal utc_hour    : natural range 0 to 23;
  signal utc_minute  : natural range 0 to 59;
  signal utc_second  : natural range 0 to 59;
  signal minute_even : std_logic;
  -- clock_calibration -> scheduler
  signal cal_start   : std_logic;
  signal cal_valid   : std_logic;
  signal cal_error   : std_logic;
  signal cal_frozen  : std_logic;
  signal cal_hz      : std_logic_vector(24 downto 0);
  -- scheduler -> modulator (and mux)
  signal tx_enable   : std_logic;
  signal symbol_tick : std_logic;
  signal tx_active   : std_logic;
  -- codec chain
  signal payload     : std_logic_vector(0 to 49);
  signal coded       : std_logic_vector(0 to 161);
  signal interleaved : std_logic_vector(0 to 161);
  signal sync_bits   : std_logic_vector(0 to 161);
  signal tones       : std_logic_vector(0 to 323);
  -- diagnostics
  signal hb_cnt      : natural range 0 to HEARTBEAT_DIV2 - 1 := 0;
  signal hb          : std_logic := '0';
  signal ready       : std_logic;
  signal led2_r      : std_logic := '1';
  -- power-on reset: holds every block in reset for 16 cycles after
  -- configuration (no reset pin on the board; FPGAs start from a known state)
  signal por_cnt     : natural range 0 to 15 := 15;
  signal rst         : std_logic := '1';

begin

  -- Power-on reset generation (plan section 31: a defined start state).
  por : process (clk)
  begin
    if rising_edge(clk) then
      if por_cnt /= 0 then
        por_cnt <= por_cnt - 1;
        rst     <= '1';
      else
        rst     <= '0';
      end if;
    end if;
  end process por;

  ---------------------------------------------------------------------------
  -- GPS receive chain
  ---------------------------------------------------------------------------
  u_uart : entity work.gps_uart
    generic map (CLOCK_HZ => CLOCK_HZ, BAUD_RATE => BAUD_RATE)
    port map (clk => clk, rst => rst, rx => uart_rx, data => uart_data,
              data_valid => uart_dv, framing_error => open);

  u_parser : entity work.gps_parser
    port map (clk => clk, rst => rst, data => uart_data, data_valid => uart_dv,
              time_strobe => time_strobe, hour => p_hour, minute => p_minute,
              second => p_second, fix_valid => open,
              sentence_error => open, fix_warning => p_warning);

  ---------------------------------------------------------------------------
  -- 1PPS measurement + clock calibration
  ---------------------------------------------------------------------------
  u_pps : entity work.pps_measure
    generic map (COUNT_WIDTH => 25, TIMEOUT_CYCLES => TIMEOUT_CYCLES)
    port map (clk => clk, rst => rst, pps_in => pps, pps_tick => pps_tick,
              measured_cycles_per_second => measured,
              measurement_valid => meas_valid);

  -- v1 note (review finding S6): cal_hz is validated and frozen here, but
  -- the modulator's phase increments are BUILD-TIME generics (spec section
  -- 9) -- the calibrated-clock -> increment datapath is not yet wired.
  -- Calibration still gates transmission (scheduler: no valid calibration
  -- -> no TX, plan section 31).
  u_cal : entity work.clock_calibration
    generic map (COUNT_WIDTH => 25, CALIBRATION_SECONDS => CALIBRATION_SECONDS,
                 CAL_MIN_HZ => CAL_MIN_HZ, CAL_MAX_HZ => CAL_MAX_HZ)
    port map (clk => clk, rst => rst, start => cal_start,
              pps_tick => pps_tick, measured_cycles_per_second => measured,
              measurement_valid => meas_valid,
              calibrated_clock_hz => cal_hz, calibration_valid => cal_valid,
              calibration_frozen => cal_frozen, calibration_error => cal_error);

  ---------------------------------------------------------------------------
  -- UTC timekeeping
  ---------------------------------------------------------------------------
  u_time : entity work.gps_time
    port map (clk => clk, rst => rst, pps_tick => pps_tick,
              time_strobe => time_strobe, hour_in => p_hour,
              minute_in => p_minute, second_in => p_second,
              fix_warning => p_warning, utc_valid => utc_valid,
              hour => utc_hour, minute => utc_minute, second => utc_second,
              minute_even => minute_even);

  ---------------------------------------------------------------------------
  -- WSPR codec (constant 162-tone source for the configured message)
  ---------------------------------------------------------------------------
  u_message : entity work.wspr_message
    port map (call0 => MSG_CALL0, call1 => MSG_CALL1, call2 => MSG_CALL2,
              call3 => MSG_CALL3, call4 => MSG_CALL4, call5 => MSG_CALL5,
              grid0 => MSG_GRID0, grid1 => MSG_GRID1, grid2 => MSG_GRID2,
              grid3 => MSG_GRID3, power => MSG_POWER,
              n_value => open, m_value => open, payload => payload);

  u_fec : entity work.wspr_fec
    port map (payload => payload, coded => coded);

  u_interleave : entity work.wspr_interleave
    port map (data_in => coded, data_out => interleaved);

  u_symbols : entity work.wspr_symbols
    port map (data_bits => interleaved, sync_bits => sync_bits,
              tones => tones);

  ---------------------------------------------------------------------------
  -- Scheduler + modulator
  ---------------------------------------------------------------------------
  u_sched : entity work.wspr_scheduler
    generic map (SYMBOLS_PER_TX => SYMBOLS_PER_TX)
    port map (clk => clk, rst => rst, slot_mask => SLOT_MASK_C,
              utc_valid => utc_valid, minute_even => minute_even,
              second => utc_second,
              minute => utc_minute, cal_valid => cal_valid,
              cal_error => cal_error, cal_start => cal_start,
              tx_enable => tx_enable, symbol_tick => symbol_tick,
              tx_active => tx_active, symbol_index => open,
              state_o => open);

  -- The modulator owns the symbol counter and indexes `tones` itself (no
  -- external mux: a scheduler-driven index skewed the sequence by one symbol
  -- -- pedagogical review finding M1).  The scheduler's symbol_index output
  -- is diagnostics-only.
  u_mod : entity work.wspr_modulator
    generic map (CLOCK_HZ => CLOCK_HZ, CARRIER_INCREMENT => CARRIER_INCREMENT,
                 HALF_TONE_INCREMENT => HALF_TONE_INCREMENT,
                 SYMBOLS_PER_TX => SYMBOLS_PER_TX,
                 ACCUMULATOR_BITS => ACCUMULATOR_BITS)
    port map (clk => clk, rst => rst, tx_start => tx_enable,
              tones => tones, rf_out => rf_out,
              tx_active => tx_active, symbol_tick => symbol_tick);

  ---------------------------------------------------------------------------
  -- Diagnostics (plan section 32): heartbeat + ready LED
  ---------------------------------------------------------------------------
  heartbeat : process (clk)
  begin
    if rising_edge(clk) then
      if hb_cnt = HEARTBEAT_DIV2 - 1 then
        hb_cnt <= 0;
        hb     <= not hb;
      else
        hb_cnt <= hb_cnt + 1;
      end if;
    end if;
  end process heartbeat;

  -- Ready = UTC valid AND calibration currently valid.  cal_valid is cleared
  -- at the start of every recalibration window and stays low on an
  -- out-of-bounds result, so led2 goes dark during recalibration AND on a
  -- calibration error (cal_frozen alone would stay high on an error --
  -- clock_calibration sets frozen and error together; review finding M5).
  -- The scheduler gates transmission on the same condition before firing.
  ready  <= utc_valid and cal_valid;
  led2_r <= not ready;

  led1 <= hb;      -- active-low LED driven by the heartbeat toggle
  led2 <= led2_r;

end architecture rtl;
