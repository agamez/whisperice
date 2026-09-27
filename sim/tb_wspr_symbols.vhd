-- ============================================================================
-- tb_wspr_symbols.vhd -- end-to-end WSPR Type-1 symbol testbench
-- ============================================================================
-- Golden reference (pinned WSJT-X 2.7.0):
--     /usr/bin/wsprcode "K1ABC FN42 37"
-- The 162 "Channel symbols" printed by that program are embedded below as
-- TONE_GOLDEN.  This testbench drives the message input "K1ABC FN42 37"
-- through the complete codec chain
--     wspr_message -> wspr_fec -> wspr_interleave -> wspr_symbols
-- and requires all 162 channel symbols to match bit-exactly.  Any single
-- difference fails the simulation (plan §20).
--
-- Message, 50-bit payload and sync vector are also golden-checked, so a
-- failure localises to source encoding, FEC, interleaving or combination.
-- "K1ABC FN42 37" is a bench/simulation vector only -- never radiate (spec §15).
-- ============================================================================
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_wspr_symbols is
end entity tb_wspr_symbols;

architecture sim of tb_wspr_symbols is

  type tone_array is array (natural range <>) of integer range 0 to 3;

  constant K : std_logic_vector(7 downto 0) := x"4B";
  constant D1 : std_logic_vector(7 downto 0) := x"31";
  constant A : std_logic_vector(7 downto 0) := x"41";
  constant B : std_logic_vector(7 downto 0) := x"42";
  constant C : std_logic_vector(7 downto 0) := x"43";
  constant SP : std_logic_vector(7 downto 0) := x"20";
  constant F : std_logic_vector(7 downto 0) := x"46";
  constant N : std_logic_vector(7 downto 0) := x"4E";
  constant D4 : std_logic_vector(7 downto 0) := x"34";
  constant D2 : std_logic_vector(7 downto 0) := x"32";

  -- 50 information bits for "K1ABC FN42 37" (docs/spec.md §2).
  constant PAYLOAD_GOLDEN : std_logic_vector(0 to 49) :=
    "11110111000011000010001110001011000011010001100101";

  -- 162-bit synchronisation vector (docs/spec.md §5; WSPRcode.f90:17-26).
  constant SYNC_GOLDEN : std_logic_vector(0 to 161) :=
    "11000000100011100010010111100000001001010000001011001101000110100001101010101001" &
    "00101100011010100010000010010011101100110100011100000101001100000001101011000110" &
    "00";

  -- 162 channel symbols from wsprcode "K1ABC FN42 37" (WSJT-X 2.7.0).
  constant TONE_GOLDEN : tone_array(0 to 161) := (
    3, 3, 0, 0, 2, 0, 0, 0, 1, 0, 2, 0, 1, 3, 1, 2, 2, 2,
    1, 0, 0, 3, 2, 3, 1, 3, 3, 2, 2, 0, 2, 0, 0, 0, 3, 2,
    0, 1, 2, 3, 2, 2, 0, 0, 2, 2, 3, 2, 1, 1, 0, 2, 3, 3,
    2, 1, 0, 2, 2, 1, 3, 2, 1, 2, 2, 2, 0, 3, 3, 0, 3, 0,
    3, 0, 1, 2, 1, 0, 2, 1, 2, 0, 3, 2, 1, 3, 2, 0, 0, 3,
    3, 2, 3, 0, 3, 2, 2, 0, 3, 0, 2, 0, 2, 0, 1, 0, 2, 3,
    0, 2, 1, 1, 1, 2, 3, 3, 0, 2, 3, 1, 2, 1, 2, 2, 2, 1,
    3, 3, 2, 0, 0, 0, 0, 1, 0, 3, 2, 0, 1, 3, 2, 2, 2, 2,
    2, 0, 2, 3, 3, 2, 3, 2, 3, 3, 2, 0, 0, 3, 1, 2, 2, 2
  );

  -- Bench message "K1ABC FN42 37"; unused callsign char is a space (spec §2).
  signal call0 : std_logic_vector(7 downto 0) := K;
  signal call1 : std_logic_vector(7 downto 0) := D1;
  signal call2 : std_logic_vector(7 downto 0) := A;
  signal call3 : std_logic_vector(7 downto 0) := B;
  signal call4 : std_logic_vector(7 downto 0) := C;
  signal call5 : std_logic_vector(7 downto 0) := SP;
  signal grid0 : std_logic_vector(7 downto 0) := F;
  signal grid1 : std_logic_vector(7 downto 0) := N;
  signal grid2 : std_logic_vector(7 downto 0) := D4;
  signal grid3 : std_logic_vector(7 downto 0) := D2;
  signal power : std_logic_vector(6 downto 0) := std_logic_vector(to_unsigned(37, 7));
  signal payload                                  : std_logic_vector(0 to 49);
  signal coded                                    : std_logic_vector(0 to 161);
  signal interleaved                              : std_logic_vector(0 to 161);
  signal sync_bits                                : std_logic_vector(0 to 161);
  signal tones                                    : std_logic_vector(0 to 323);

begin

  -- Source encoding (plan §13).
  u_msg : entity work.wspr_message
    port map (
      call0 => call0, call1 => call1, call2 => call2,
      call3 => call3, call4 => call4, call5 => call5,
      grid0 => grid0, grid1 => grid1, grid2 => grid2, grid3 => grid3,
      power => power,
      n_value => open, m_value => open,
      payload => payload
    );

  -- Convolutional FEC (plan §14).
  u_fec : entity work.wspr_fec
    port map (
      payload => payload,
      coded   => coded
    );

  -- Interleaver (plan §15).
  u_ilv : entity work.wspr_interleave
    port map (
      data_in  => coded,
      data_out => interleaved
    );

  -- Sync vector + symbol combination (plan §16).
  u_sym : entity work.wspr_symbols
    port map (
      data_bits => interleaved,
      sync_bits => sync_bits,
      tones     => tones
    );

  stim : process
    variable errors : integer;
    variable actual : integer;
  begin
    wait for 10 ns;

    assert payload = PAYLOAD_GOLDEN
      report "tb_wspr_symbols: FAIL: 50-bit payload mismatch" severity failure;
    assert sync_bits = SYNC_GOLDEN
      report "tb_wspr_symbols: FAIL: sync vector mismatch" severity failure;

    errors := 0;
    for i in 0 to 161 loop
      actual := 0;
      if tones(2 * i + 1) = '1' then
        actual := actual + 2;     -- MSB of the 2-bit symbol field
      end if;
      if tones(2 * i) = '1' then
        actual := actual + 1;     -- LSB of the 2-bit symbol field
      end if;
      if actual /= TONE_GOLDEN(i) then
        errors := errors + 1;
        report "tb_wspr_symbols: symbol " & integer'image(i)
               & " = " & integer'image(actual)
               & ", expected " & integer'image(TONE_GOLDEN(i))
          severity note;
      end if;
    end loop;

    assert errors = 0
      report "tb_wspr_symbols: FAIL: " & integer'image(errors)
             & " of 162 channel symbols differ from wsprcode"
      severity failure;

    report "tb_wspr_symbols: PASS: 162/162 channel symbols match wsprcode (WSJT-X 2.7.0)"
      severity note;
    wait;
  end process;

end architecture sim;
