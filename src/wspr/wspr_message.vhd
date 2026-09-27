-- ============================================================================
-- wspr_message.vhd -- WSPR Type-1 source encoding: "CALLSIGN GRID4 POWER_dBm"
-- ============================================================================
-- Part of the wspr-icebreaker WSPR codec (plan §13, Phase 9).
--
-- This block performs ONLY the WSPR Type-1 *source* encoding: the textual
-- message is compressed into 50 information bits (28 callsign + 15 grid + 7
-- power), exactly as the pinned reference WSJT-X 2.7.0 does it.  FEC,
-- interleaving and symbol generation live in the other wspr_*.vhd blocks.
--
-- Authoritative sources (all citations to the pinned WSJT-X 2.7.0 tree,
-- /tmp/opencode/wsjtx-src/wsjtx-2.7.0+repack/, Phase 0; see docs/spec.md §2):
--   * lib/wsprd/wsprsim_utils.c:29-40   get_callsign_character_code
--   * lib/wsprd/wsprsim_utils.c:16-27   get_locator_character_code
--   * lib/wsprd/wsprsim_utils.c:42-48   pack_grid4_power
--   * lib/wsprd/wsprsim_utils.c:50-79   pack_call (callsign padding/alignment)
--   * lib/wsprd/wsprsim_utils.c:255-275 50-bit -> data[0..6] byte packing
--
-- Interface convention
-- --------------------
--   * Each character is passed as one ASCII byte (std_logic_vector(7 downto 0)).
--   * Characters not used by a callsign/grid field MUST be ASCII space (0x20);
--     this reproduces the C reference, which left-pads or space-pads the
--     6/4-character fields.
--   * payload(0) is the FIRST transmitted information bit (MSB-first packing,
--     spec §2).  payload(0 to 49) therefore maps directly to the FEC input.
--   * n_value / m_value expose the intermediate integers documented in
--     docs/spec.md §2 (n = 259047992, m = 2896997 for "K1ABC FN42 37").
--
-- Frozen bench vector (simulation only -- never radiate, spec §15):
--   "K1ABC FN42 37"  ->  payload = F7 0C 23 8B 0D 19 40
-- ============================================================================
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity wspr_message is
  port (
    -- Callsign field: exactly 6 ASCII characters, left to right.
    call0 : in  std_logic_vector(7 downto 0);
    call1 : in  std_logic_vector(7 downto 0);
    call2 : in  std_logic_vector(7 downto 0);
    call3 : in  std_logic_vector(7 downto 0);
    call4 : in  std_logic_vector(7 downto 0);
    call5 : in  std_logic_vector(7 downto 0);
    -- Grid field: exactly 4 ASCII characters (Maidenhead 4-char locator).
    grid0 : in  std_logic_vector(7 downto 0);
    grid1 : in  std_logic_vector(7 downto 0);
    grid2 : in  std_logic_vector(7 downto 0);
    grid3 : in  std_logic_vector(7 downto 0);
    -- Power field: 7-bit dBm value, 0 .. 60 used by Type 1.
    power : in  std_logic_vector(6 downto 0);
    -- Intermediate values (docs/spec.md §2), for verification and diagnostics.
    n_value : out std_logic_vector(27 downto 0);  -- callsign, 28 bits
    m_value : out std_logic_vector(21 downto 0);  -- grid+power, 22 bits
    -- 50-bit Type-1 payload, payload(0) = first bit (spec §2).
    payload : out std_logic_vector(0 to 49)
  );
end entity wspr_message;

architecture rtl of wspr_message is

  -- Six-character working array for the callsign alignment step.
  type byte_array6 is array (0 to 5) of std_logic_vector(7 downto 0);

  -- True when the ASCII byte is '0'..'9' (spec §2).
  function is_digit(b : std_logic_vector(7 downto 0)) return boolean is
  begin
    return (unsigned(b) >= to_unsigned(48, 8)) and
           (unsigned(b) <= to_unsigned(57, 8));
  end function is_digit;

  -- get_callsign_character_code(): '0'..'9' -> 0..9, ' ' -> 36,
  -- 'A'..'Z' -> 10..35 (lib/wsprd/wsprsim_utils.c:29-40).
  function call_char_code(b : std_logic_vector(7 downto 0)) return integer is
  begin
    if (unsigned(b) >= 48) and (unsigned(b) <= 57) then
      return to_integer(unsigned(b)) - 48;
    elsif b = x"20" then
      return 36;
    elsif (unsigned(b) >= 65) and (unsigned(b) <= 90) then
      return to_integer(unsigned(b)) - 55;
    else
      -- Reference returns -1 for an illegal character; valid Type-1 input
      -- never reaches this branch.
      return -1;
    end if;
  end function call_char_code;

  -- get_locator_character_code(): '0'..'9' -> 0..9, ' ' -> 36,
  -- 'A'..'R' -> 0..17 (lib/wsprd/wsprsim_utils.c:16-27).
  function loc_char_code(b : std_logic_vector(7 downto 0)) return integer is
  begin
    if (unsigned(b) >= 48) and (unsigned(b) <= 57) then
      return to_integer(unsigned(b)) - 48;
    elsif b = x"20" then
      return 36;
    elsif (unsigned(b) >= 65) and (unsigned(b) <= 82) then
      return to_integer(unsigned(b)) - 65;
    else
      return -1;
    end if;
  end function loc_char_code;

begin

  process (call0, call1, call2, call3, call4, call5,
           grid0, grid1, grid2, grid3, power)
    variable c6   : byte_array6;
    variable n    : integer;
    variable m    : integer;
    variable gc0  : integer;
    variable gc1  : integer;
    variable gc2  : integer;
    variable gc3  : integer;
    variable nv   : std_logic_vector(27 downto 0);
    variable mv   : std_logic_vector(21 downto 0);
    variable d0   : std_logic_vector(7 downto 0);
    variable d1   : std_logic_vector(7 downto 0);
    variable d2   : std_logic_vector(7 downto 0);
    variable d3   : std_logic_vector(7 downto 0);
    variable d4   : std_logic_vector(7 downto 0);
    variable d5   : std_logic_vector(7 downto 0);
    variable d6   : std_logic_vector(7 downto 0);
  begin
    ------------------------------------------------------------------
    -- Step 1 -- callsign alignment to a 6-character field (spec §2;
    -- lib/wsprd/wsprsim_utils.c:53-71).
    --   if 3rd char is a digit: use as-is,
    --   else if 2nd char is a digit: shift right one, pad a leading space.
    ------------------------------------------------------------------
    if is_digit(call2) then
      c6(0) := call0;
      c6(1) := call1;
      c6(2) := call2;
      c6(3) := call3;
      c6(4) := call4;
      c6(5) := call5;
    elsif is_digit(call1) then
      c6(0) := x"20";   -- leading space
      c6(1) := call0;
      c6(2) := call1;
      c6(3) := call2;
      c6(4) := call3;
      c6(5) := call4;
    else
      -- Reference leaves the array entirely space-filled in this case.
      c6 := (others => x"20");
    end if;

    ------------------------------------------------------------------
    -- Step 2 -- callsign value n (28 bits) (spec §2;
    -- lib/wsprd/wsprsim_utils.c:72-77).
    ------------------------------------------------------------------
    n := call_char_code(c6(0));
    n := n * 36 + call_char_code(c6(1));
    n := n * 10 + call_char_code(c6(2));
    n := n * 27 + (call_char_code(c6(3)) - 10);
    n := n * 27 + (call_char_code(c6(4)) - 10);
    n := n * 27 + (call_char_code(c6(5)) - 10);

    ------------------------------------------------------------------
    -- Step 3 -- grid + power value m (22 bits) (spec §2;
    -- lib/wsprd/wsprsim_utils.c:42-48).
    --   m = ((179 - 10*g0 - g2)*180 + 10*g1 + g3)*128 + power + 64
    ------------------------------------------------------------------
    gc0 := loc_char_code(grid0);
    gc1 := loc_char_code(grid1);
    gc2 := loc_char_code(grid2);
    gc3 := loc_char_code(grid3);
    m := ((179 - 10 * gc0 - gc2) * 180 + 10 * gc1 + gc3) * 128
         + to_integer(unsigned(power)) + 64;

    -- Mask to the frozen field widths; VHDL "mod" keeps the result
    -- non-negative (two's-complement wrap, matching the C reference).
    nv := std_logic_vector(to_unsigned(n mod 2 ** 28, 28));
    mv := std_logic_vector(to_unsigned(m mod 2 ** 22, 22));

    ------------------------------------------------------------------
    -- Step 4 -- pack the 50 payload bits MSB-first (spec §2;
    -- lib/wsprd/wsprsim_utils.c:255-275).
    --   data[0]=n>>20  data[1]=n>>12  data[2]=n>>4
    --   data[3]=((n&0x0F)<<4)+((m>>18)&0x0F)
    --   data[4]=m>>10  data[5]=m>>2  data[6]=(m&0x03)<<6
    ------------------------------------------------------------------
    d0 := nv(27 downto 20);
    d1 := nv(19 downto 12);
    d2 := nv(11 downto 4);
    d3 := nv(3 downto 0) & mv(21 downto 18);
    d4 := mv(17 downto 10);
    d5 := mv(9 downto 2);
    d6 := mv(1 downto 0) & "000000";

    -- 50 bits = the six whole bytes plus the top two bits of d6.
    payload <= d0 & d1 & d2 & d3 & d4 & d5 & d6(7 downto 6);
    n_value <= nv;
    m_value <= mv;
  end process;

end architecture rtl;
