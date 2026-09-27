-- ============================================================================
-- wspr_fec.vhd -- WSPR forward error correction (K=32, r=1/2 convolutional)
-- ============================================================================
-- Part of the wspr-icebreaker WSPR codec (plan §14, Phase 10).
--
-- 50 information bits + 31 zero tail bits = 81 input bits, encoded by a
-- rate-1/2, constraint-length-32 Layland-Lushbaugh convolutional code into
-- 162 coded bits (the first 162 of the 2*81 = 162 produced -- exactly 162).
--
-- Authoritative sources and conventions (pinned WSJT-X 2.7.0; docs/spec.md §3):
--   * lib/wsprd/fano.c:50-51      POLY1 = 0xf2d05351, POLY2 = 0xe4613c47
--   * lib/wsprd/fano.c:13         #define LL 1  -> Layland-Lushbaugh branch
--   * lib/wsprd/fano.c:65-82      encode(): input bytes read MSB first,
--                                 encstate = (encstate << 1) | bit,
--                                 POLY1 parity emitted first, then POLY2.
--   * lib/wsprd/fano.h:28-37      ENCODE macro (parity of state & POLY)
--   * lib/encode232.f90:12-25     identical FORTRAN reference
--   * lib/wsprd/WSPRcode.f90:94   nbits = 50 + 31
--
-- Bit conventions reproduced here:
--   * Input bits are consumed MSB-first: payload(0) is the first bit in.
--   * State is a 32-bit shift register, newest bit in the LSB.
--   * For input bit k: coded(2k) = parity(state & POLY1),
--                      coded(2k+1) = parity(state & POLY2).
--   * Parity is the even parity (XOR reduction) of the 32-bit AND, which is
--     algebraically identical to the reference's
--     tmp ^= tmp>>16; Partab[(tmp ^ tmp>>8) & 0xff] folding.
--
-- Output: coded(0 to 161), coded(0) = first transmitted coded bit.
-- ============================================================================
library ieee;
use ieee.std_logic_1164.all;

entity wspr_fec is
  port (
    payload : in  std_logic_vector(0 to 49);   -- Type-1 information bits
    coded   : out std_logic_vector(0 to 161)   -- convolutional code bits
  );
end entity wspr_fec;

architecture rtl of wspr_fec is

  -- Generator polynomials, verbatim from the pinned reference
  -- (lib/wsprd/fano.c:50-51; identical in lib/conv232.f90:4).
  constant POLY1 : std_logic_vector(31 downto 0) := x"F2D05351";
  constant POLY2 : std_logic_vector(31 downto 0) := x"E4613C47";

  -- 50 payload bits followed by 31 zero tail bits (spec §3).
  signal inbits : std_logic_vector(0 to 80);

  -- Even parity of every bit of v (XOR reduction).
  function parity_even(v : std_logic_vector) return std_logic is
    variable p : std_logic := '0';
  begin
    for i in v'range loop
      p := p xor v(i);
    end loop;
    return p;
  end function parity_even;

begin

  inbits(0 to 49)  <= payload;
  inbits(50 to 80) <= (others => '0');   -- 31 zero tail bits

  process (inbits)
    variable state : std_logic_vector(31 downto 0);
  begin
    state := (others => '0');
    for k in 0 to 80 loop
      -- Shift register, newest input bit into the LSB (fano.c:74).
      state := state(30 downto 0) & inbits(k);
      -- POLY1 parity first, POLY2 parity second (fano.c:76-77).
      coded(2 * k)     <= parity_even(state and POLY1);
      coded(2 * k + 1) <= parity_even(state and POLY2);
    end loop;
  end process;

end architecture rtl;
