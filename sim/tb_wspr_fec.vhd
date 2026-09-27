-- ============================================================================
-- tb_wspr_fec.vhd -- testbench for the WSPR convolutional encoder
-- ============================================================================
-- Input : the frozen 50-bit Type-1 payload for "K1ABC FN42 37"
--         (11110111 00001100 00100011 10001011 00001101 00011001 01).
-- Golden: the 162 coded bits below were produced by the frozen algorithm
--         (spec §3) and cross-checked against the pinned reference: applying
--         the spec §4 interleaver to these bits reproduces, bit for bit, the
--         "Data symbols" printed by
--             /usr/bin/wsprcode "K1ABC FN42 37"   (WSJT-X 2.7.0)
--         Intermediate bits not directly printed by wsprcode were generated
--         with the Phase-0 reference model and validated by that interleave
--         round-trip plus the end-to-end tb_wspr_symbols test.
-- Any single-bit difference must fail (plan §20).
-- ============================================================================
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_wspr_fec is
end entity tb_wspr_fec;

architecture sim of tb_wspr_fec is

  constant PAYLOAD_GOLDEN : std_logic_vector(0 to 49) :=
    "11110111000011000010001110001011000011010001100101";

  -- 162 coded bits, coded(0) first (spec §3).
  constant CODED_GOLDEN : std_logic_vector(0 to 161) :=
    "11101111100011100100110101010100101010111000110110110001111110011111111011101010" &
    "11010101000100010111100000011111110110101000110011110110110101010101100011010011" &
    "11";

  signal payload : std_logic_vector(0 to 49) := PAYLOAD_GOLDEN;
  signal coded   : std_logic_vector(0 to 161);

begin

  dut : entity work.wspr_fec
    port map (
      payload => payload,
      coded   => coded
    );

  stim : process
    variable errors : integer;
  begin
    wait for 10 ns;

    errors := 0;
    for i in 0 to 161 loop
      if coded(i) /= CODED_GOLDEN(i) then
        errors := errors + 1;
        report "tb_wspr_fec: coded bit " & integer'image(i) & " differs" severity note;
      end if;
    end loop;

    assert errors = 0
      report "tb_wspr_fec: FAIL: " & integer'image(errors) & " coded bit(s) differ"
      severity failure;

    report "tb_wspr_fec: PASS: 162/162 coded bits match the golden vector"
      severity note;
    wait;
  end process;

end architecture sim;
