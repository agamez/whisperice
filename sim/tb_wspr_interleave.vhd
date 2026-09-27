-- ============================================================================
-- tb_wspr_interleave.vhd -- testbench for the WSPR interleaver
-- ============================================================================
-- Input : the 162 coded bits for "K1ABC FN42 37" (see tb_wspr_fec.vhd).
-- Golden: the 162 interleaved bits below are exactly the "Data symbols"
--         printed by the pinned reference encoder:
--             /usr/bin/wsprcode "K1ABC FN42 37"   (WSJT-X 2.7.0)
--         The interleaver must reproduce this permutation bit for bit; no
--         "equivalent" permutation is acceptable (plan §15).
-- ============================================================================
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_wspr_interleave is
end entity tb_wspr_interleave;

architecture sim of tb_wspr_interleave is

  -- Pre-interleave coded bits (spec §3), from tb_wspr_fec.vhd.
  constant CODED_GOLDEN : std_logic_vector(0 to 161) :=
    "11101111100011100100110101010100101010111000110110110001111110011111111011101010" &
    "11010101000100010111100000011111110110101000110011110110110101010101100011010011" &
    "11";

  -- Golden interleaved output == wsprcode "Data symbols".
  constant INTERLEAVED_GOLDEN : std_logic_vector(0 to 161) :=
    "11001000001001011100011101111010001100111100111100011110011011011101101010010010" &
    "10110110011110111010101000110100011101101011101110000001100111111011111111100101" &
    "11";

  signal data_in  : std_logic_vector(0 to 161) := CODED_GOLDEN;
  signal data_out : std_logic_vector(0 to 161);

begin

  dut : entity work.wspr_interleave
    port map (
      data_in  => data_in,
      data_out => data_out
    );

  stim : process
    variable errors  : integer;
    variable ones_in : integer;
    variable ones_out : integer;
  begin
    wait for 10 ns;

    errors := 0;
    for i in 0 to 161 loop
      if data_out(i) /= INTERLEAVED_GOLDEN(i) then
        errors := errors + 1;
        report "tb_wspr_interleave: bit " & integer'image(i) & " differs" severity note;
      end if;
    end loop;

    -- A permutation must preserve the number of set bits.
    ones_in  := 0;
    ones_out := 0;
    for i in 0 to 161 loop
      if data_in(i)  = '1' then ones_in  := ones_in  + 1; end if;
      if data_out(i) = '1' then ones_out := ones_out + 1; end if;
    end loop;

    assert errors = 0
      report "tb_wspr_interleave: FAIL: " & integer'image(errors)
             & " interleaved bit(s) differ" severity failure;
    assert ones_in = ones_out
      report "tb_wspr_interleave: FAIL: output is not a permutation" severity failure;

    report "tb_wspr_interleave: PASS: 162/162 bits match wsprcode Data symbols"
      severity note;
    wait;
  end process;

end architecture sim;
