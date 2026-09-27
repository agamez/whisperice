-- ============================================================================
-- wspr_interleave.vhd -- WSPR 162-bit interleaver (bit-reversal permutation)
-- ============================================================================
-- Part of the wspr-icebreaker WSPR codec (plan §15, Phase 11).
--
-- The frozen WSPR interleaver is a fixed permutation of the 162 coded bits,
-- built from the bit-reversal of the 8-bit index:
--
--   for i = 0..255:
--       n = bitreverse8(i)
--       if n <= 161: append n to the table j0 (in increasing-i order)
--
-- j0 is then a permutation of 0..161.  The encoder applies:
--     itmp[ j0(i) ] = id(i)          (interleave)
--
-- Sources (pinned WSJT-X 2.7.0; docs/spec.md §4):
--   * lib/inter_wspr.f90:1-45                (table build + interleave)
--   * lib/wsprcode/wspr_old_subs.f90:378-422 (inter_mept, identical)
--   * lib/wsprd/wsprsim_utils.c:145-163      (C encoder interleave)
--
-- No "equivalent" permutation may be substituted (plan §15); the table is
-- computed here by the exact reference algorithm rather than hard-coded.
--
-- Interface: data_in(0 to 161) -> data_out(0 to 161), same bit indexing.
-- ============================================================================
library ieee;
use ieee.std_logic_1164.all;

entity wspr_interleave is
  port (
    data_in  : in  std_logic_vector(0 to 161);  -- pre-interleave coded bits
    data_out : out std_logic_vector(0 to 161)   -- interleaved coded bits
  );
end entity wspr_interleave;

architecture rtl of wspr_interleave is

  -- Reverse the 8 bits of i (lib/inter_wspr.f90:16-21).
  function bitreverse8(i : integer) return integer is
    variable v : integer;
    variable n : integer;
  begin
    v := i;
    n := 0;
    for j in 0 to 7 loop
      n := n * 2 + (v mod 2);
      v := v / 2;
    end loop;
    return n;
  end function bitreverse8;

  -- j0(k) = the k-th value of bitreverse8(i), for i = 0..255, that is <= 161,
  -- in increasing-i order (lib/inter_wspr.f90:11-25).
  function interleave_index(k : integer) return integer is
    variable p     : integer;
    variable idx   : integer;
    variable rev   : integer;
    variable res   : integer;
    variable found : boolean;
  begin
    p     := 0;
    idx   := 0;
    res   := 0;
    found := false;
    while not found loop
      rev := bitreverse8(idx);
      if rev <= 161 then
        if p = k then
          res   := rev;
          found := true;
        else
          p := p + 1;
        end if;
      end if;
      idx := idx + 1;
    end loop;
    return res;
  end function interleave_index;

begin

  process (data_in)
    variable j : integer;
  begin
    for i in 0 to 161 loop
      j := interleave_index(i);
      data_out(j) <= data_in(i);   -- itmp[j0(i)] = id(i)
    end loop;
  end process;

end architecture rtl;
