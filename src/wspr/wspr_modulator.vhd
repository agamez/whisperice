--------------------------------------------------------------------------------
-- wspr_modulator.vhd -- continuous-phase 4-FSK WSPR modulator
--
-- Phase 4/13 of the wspr-icebreaker plan (doc/wspr_icebreaker_orchestrator_plan.md
-- sections 10, 13, 17; frozen constants: docs/spec.md sections 6 and 9).
--
-- Architecture (plan section 17): ONE shared phase accumulator serves the whole
-- transmission, so the carrier phase evolves continuously across symbol
-- boundaries.  The per-clock phase increment is
--
--     phase_increment = CARRIER_INCREMENT + (2*symbol - 3) * HALF_TONE_INCREMENT
--
-- with symbol in 0..3.  This realises the CENTERED tone grid of spec section 6
-- (and WSJT-X wsprsimf.f90: (itone-1.5)*baud): the four tones sit at
-- CARRIER + (-1.5, -0.5, +0.5, +1.5) * tone_spacing, i.e. CARRIER_INCREMENT is
-- the grid CENTRE.  (An earlier tone0-based mapping emitted the whole grid
-- 1.5 spacings high; fixed after documentation review.)  HALF_TONE_INCREMENT
-- is the half-spacing increment: 67109 (tools/calculate_nco.py,
-- exact half-spacing rounding at 12 MHz); adjacent tones are then 2*67109
-- increments apart (+1 LSB = +1.1e-5 Hz against the rounded spacing --
-- irrelevant against the 1.46 Hz tone spacing).  The accumulator is only cleared when a
-- transmission STARTS (RF is off before and after), never mid-TX.
--
-- Interface note (pedagogical review finding M1): the modulator OWNS the
-- symbol counter and indexes the full tone vector (`tones`) itself.  An
-- earlier interface took a 2-bit symbol_index from an external mux driven
-- by the scheduler's counter -- but the registered symbol_tick let the
-- scheduler advance one cycle AFTER the modulator latched, skewing the
-- transmitted sequence by one symbol (scratch sim: tones (0,0,1,2,...)
-- instead of (0,1,2,...), symbol 161 never sent).  Owning the index makes
-- the skew structurally impossible.
--
-- Symbol timing (plan section 10): one WSPR symbol lasts 8192/12000 s
-- (spec section 6).  At CLOCK_HZ = 12,000,000 that is exactly 8,192,000 cycles.
-- For an off-nominal (calibrated) clock the per-symbol cycle count is
-- fractional, so the length of symbol k is distributed by Bresenham on the
-- exact fraction:
--
--     cycles_per_symbol = CLOCK_HZ * 8192 / 12000
--                       = WHOLE + REM/12000        (exact integer split)
--
-- Symbol k gets WHOLE + 1 cycles iff (k*REM mod 12000) + REM >= 12000, i.e. the
-- floor-distribution of the true boundary positions.  The cumulative length of
-- N symbols is therefore EXACTLY floor(N * CLOCK_HZ * 8192 / 12000) cycles --
-- the timing error versus the ideal is bounded by one cycle over the whole
-- 162-symbol transmission (plan section 10: no cumulative rounding error).
-- All intermediate products fit 32-bit integers: (CLOCK_HZ mod 12000) * 8192
-- < 98,296,000.
--
-- Worked example (CLOCK_HZ = 12001): WHOLE = 8192, REM = 8192, so lengths
-- alternate 8192/8193 and the cumulative length of all 162 symbols is
-- EXACTLY floor(162 * 12001 * 8192 / 12000) cycles (review finding S5).
--
-- Provenance of the default increments (tools/calculate_nco.py at 12 MHz,
-- spec section 9 default RF 10140200 Hz):
--     CARRIER_INCREMENT = 929105650665 = 0xd8530323e9  (error +5.3e-6 Hz)
--     TONE_INCREMENT    = 134217      = 12000/8192 Hz tone spacing step
--
-- Known physical property (documented, NOT a defect): with CLOCK_HZ = 12 MHz
-- the 1-bit output cannot represent the 10.1402 MHz carrier (above the 6 MHz
-- Nyquist rate of the sampled pin); the MSB pattern folds to ~1.86 MHz.  The
-- phase arithmetic itself is exact; see docs/rf.md (band selection) when
-- written.  Do not "fix" this in RTL.
--
-- VHDL-93 only (no process(all), explicit sensitivity lists, integer math).
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity wspr_modulator is
  generic (
    CLOCK_HZ          : positive := 12000000;
    CARRIER_INCREMENT      : std_logic_vector(39 downto 0) := x"D8530323E9";
    HALF_TONE_INCREMENT    : natural := 67109;
    SYMBOLS_PER_TX    : positive := 162;
    ACCUMULATOR_BITS  : positive := 40
  );
  port (
    clk          : in  std_logic;
    rst          : in  std_logic;
    tx_start     : in  std_logic;
    -- The full channel-symbol vector (2 bits per symbol, tones(2i)=sync,
    -- tones(2i+1)=data, value = 2*data + sync -- spec section 5).  The
    -- modulator owns the symbol counter and indexes this vector itself:
    -- an external index mux cannot stay cycle-aligned with the registered
    -- symbol_tick (pedagogical review finding M1: a one-symbol skew).
    tones        : in  std_logic_vector(0 to 2 * SYMBOLS_PER_TX - 1);
    rf_out       : out std_logic;
    tx_active    : out std_logic;
    symbol_tick  : out std_logic
  );
end entity wspr_modulator;

architecture rtl of wspr_modulator is

  -- Symbol fraction (spec section 6): duration = SYMBOL_NUM / SYMBOL_DEN seconds.
  constant SYMBOL_NUM : positive := 8192;
  constant SYMBOL_DEN : positive := 12000;

  -- Exact split of cycles_per_symbol = CLOCK_HZ * SYMBOL_NUM / SYMBOL_DEN into
  -- WHOLE + REM/SYMBOL_DEN (fits 32-bit: (CLOCK_HZ mod 12000) * 8192 < 2^31).
  function sym_whole(f_clk : positive) return natural is
  begin
    return (f_clk / SYMBOL_DEN) * SYMBOL_NUM
         + ((f_clk mod SYMBOL_DEN) * SYMBOL_NUM) / SYMBOL_DEN;
  end function sym_whole;

  function sym_rem(f_clk : positive) return natural is
  begin
    return ((f_clk mod SYMBOL_DEN) * SYMBOL_NUM) mod SYMBOL_DEN;
  end function sym_rem;

  constant WHOLE_CYCLES : natural := sym_whole(CLOCK_HZ);
  constant REM_NUM      : natural := sym_rem(CLOCK_HZ);

  -- Carrier increment carried as a 40-bit generic (the real increment does not
  -- fit VHDL-93 integer), resized to the accumulator width.  The increment
  -- VALUE must satisfy value < 2**ACCUMULATOR_BITS (testbenches scale the
  -- accumulator width with proportionally small increments).
  constant CARRIER_RESIZED : unsigned(ACCUMULATOR_BITS-1 downto 0) :=
    resize(unsigned(CARRIER_INCREMENT), ACCUMULATOR_BITS);

  -- Per-symbol increment constants for the centered grid (symbol k sits at
  -- CARRIER + (2k-3) * HALF_TONE_INCREMENT).  Precomputing them keeps the
  -- per-clock path a 4:1 mux plus ONE 40-bit add -- a symbolic multiply by
  -- the 17-bit half-spacing constant would synthesize a ~130 ns combinational
  -- multiplier and fail 12 MHz timing (found in integration P&R).
  constant INC_T0 : unsigned(ACCUMULATOR_BITS-1 downto 0) :=
    CARRIER_RESIZED - to_unsigned(3 * HALF_TONE_INCREMENT, ACCUMULATOR_BITS);
  constant INC_T1 : unsigned(ACCUMULATOR_BITS-1 downto 0) :=
    CARRIER_RESIZED - to_unsigned(HALF_TONE_INCREMENT, ACCUMULATOR_BITS);
  constant INC_T2 : unsigned(ACCUMULATOR_BITS-1 downto 0) :=
    CARRIER_RESIZED + to_unsigned(HALF_TONE_INCREMENT, ACCUMULATOR_BITS);
  constant INC_T3 : unsigned(ACCUMULATOR_BITS-1 downto 0) :=
    CARRIER_RESIZED + to_unsigned(3 * HALF_TONE_INCREMENT, ACCUMULATOR_BITS);

  -- 25-bit symbol-length/cycle counters: WHOLE_CYCLES < 2^25 for any clock
  -- below ~101 GHz; 8,192,068 (at 12.0001 MHz) needs 23 bits.
  constant LEN_BITS : positive := 25;

  signal acc         : unsigned(ACCUMULATOR_BITS-1 downto 0) := (others => '0');
  signal active_r    : std_logic := '0';
  signal symbol_cnt         : natural range 0 to SYMBOLS_PER_TX := 0;
  signal symbol_latched     : natural range 0 to 3 := 0;
  signal symbol_idx         : natural range 0 to SYMBOLS_PER_TX - 1 := 0;
  signal cycle_cnt          : natural range 0 to 2**LEN_BITS-1 := 0;
  signal cur_len            : natural range 1 to 2**LEN_BITS-1 := WHOLE_CYCLES;
  signal err                : natural range 0 to SYMBOL_DEN-1 := 0;
  signal tick_r             : std_logic := '0';
  signal rf_r               : std_logic := '0';

begin

  -- Single synchronous process: phase accumulator + symbol timing FSM.
  process (clk)
    variable err_v : natural;
    variable nxt   : std_logic_vector(1 downto 0);
  begin
    if rising_edge(clk) then
      tick_r <= '0';                      -- default: 1-cycle pulse

      if rst = '1' then
        -- plan section 31: reset during TX -> RF off immediately.
        active_r    <= '0';
        rf_r        <= '0';
        acc         <= (others => '0');
        symbol_cnt  <= 0;
        symbol_latched <= 0;
        symbol_idx  <= 0;
        cycle_cnt   <= 0;
        cur_len     <= WHOLE_CYCLES;
        err         <= 0;
      elsif active_r = '1' then
        -- Phase advance: carrier + tone offset of the latched symbol.
        -- unsigned addition wraps mod 2**ACCUMULATOR_BITS (phase wrap).
        -- centered grid: one 40-bit add of the selected per-symbol constant
        -- (the four constants realize (2k-3) * HALF_TONE_INCREMENT modulo
        -- 2**ACCUMULATOR_BITS; symbols 0/1 subtract via modular wrap)
        case symbol_latched is
          when 0      => acc <= acc + INC_T0;
          when 1      => acc <= acc + INC_T1;
          when 2      => acc <= acc + INC_T2;
          when others => acc <= acc + INC_T3;
        end case;
        rf_r <= acc(ACCUMULATOR_BITS-1);

        -- Symbol timing: boundary when the in-symbol cycle counter expires.
        if cycle_cnt = cur_len - 1 then
          tick_r           <= '1';        -- boundary pulse (1 cycle)
          cycle_cnt        <= 0;
          if symbol_cnt + 1 = SYMBOLS_PER_TX then
            active_r      <= '0';         -- end of transmission
            rf_r          <= '0';
          else
            symbol_cnt    <= symbol_cnt + 1;
            symbol_idx    <= symbol_idx + 1;
            -- the NEXT symbol's tone, from the tone vector at the new index:
            -- field (2i)=sync, (2i+1)=data -> value 2*data+sync
            nxt := tones(2 * (symbol_idx + 1) + 1)  -- data bit (MSB)
                       & tones(2 * (symbol_idx + 1));  -- sync bit (LSB)
            symbol_latched <= to_integer(unsigned(nxt));
            -- Bresenham floor-distribution of REM/SYMBOL_DEN (see header).
            -- The length of the ENTERING symbol k+1 is WHOLE+1 iff
            -- ((k+1)*REM mod DEN) >= DEN-REM, so the error state must be
            -- updated BEFORE the threshold test (err_v = ((k+1)*REM) mod DEN).
            err_v := err + REM_NUM;
            if err_v >= SYMBOL_DEN then
              err_v := err_v - SYMBOL_DEN;
            end if;
            if err_v >= SYMBOL_DEN - REM_NUM then
              cur_len <= WHOLE_CYCLES + 1;
            else
              cur_len <= WHOLE_CYCLES;
            end if;
            err <= err_v;
          end if;
        else
          cycle_cnt <= cycle_cnt + 1;
        end if;
      elsif tx_start = '1' then
        -- Start of transmission: phase restarts (RF was off), symbol 0 begins.
        active_r       <= '1';
        acc            <= (others => '0');
        rf_r           <= '0';
        symbol_cnt     <= 0;
        symbol_idx     <= 0;
        nxt := tones(1) & tones(0);
        symbol_latched <= to_integer(unsigned(nxt));
        cycle_cnt      <= 0;
        err            <= 0;
        cur_len        <= WHOLE_CYCLES;    -- symbol 0: extra = 0 (err = 0 < REM bound)
      end if;
    end if;
  end process;

  -- Outputs: RF gated off whenever not transmitting.
  rf_out      <= rf_r when active_r = '1' else '0';
  tx_active   <= active_r;
  symbol_tick <= tick_r;

end architecture rtl;
