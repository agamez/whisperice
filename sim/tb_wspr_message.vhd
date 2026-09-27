-- ============================================================================
-- tb_wspr_message.vhd -- testbench for WSPR Type-1 source encoding
-- ============================================================================
-- Golden reference (docs/spec.md §2):
--   message      : "K1ABC FN42 37"   (bench/simulation vector only)
--   n (callsign) : 259047992  = 0x0F70C238
--   m (grid+pow) : 2896997    = 0x2C3465
--   50 bits      : 11110111 00001100 00100011 10001011 00001101 00011001 01
--   payload bytes: F7 0C 23 8B 0D 19 40
-- Source: /usr/bin/wsprcode "K1ABC FN42 37" (WSJT-X 2.7.0, Debian
-- 2.7.0+repack-1) and the algorithm in lib/wsprd/wsprsim_utils.c.
-- ============================================================================
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_wspr_message is
end entity tb_wspr_message;

architecture sim of tb_wspr_message is

  -- ASCII bytes of "K1ABC " and "FN42".
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

  constant N_GOLDEN : std_logic_vector(27 downto 0) :=
    std_logic_vector(to_unsigned(259047992, 28));
  constant M_GOLDEN : std_logic_vector(21 downto 0) :=
    std_logic_vector(to_unsigned(2896997, 22));

  -- 50 information bits, MSB-first (docs/spec.md §2).
  constant PAYLOAD_GOLDEN : std_logic_vector(0 to 49) :=
    "11110111000011000010001110001011000011010001100101";

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
  signal n_value                                  : std_logic_vector(27 downto 0);
  signal m_value                                  : std_logic_vector(21 downto 0);
  signal payload                                  : std_logic_vector(0 to 49);

begin

  dut : entity work.wspr_message
    port map (
      call0 => call0, call1 => call1, call2 => call2,
      call3 => call3, call4 => call4, call5 => call5,
      grid0 => grid0, grid1 => grid1, grid2 => grid2, grid3 => grid3,
      power => power,
      n_value => n_value,
      m_value => m_value,
      payload => payload
    );

  stim : process
  begin
    wait for 10 ns;

    assert n_value = N_GOLDEN
      report "tb_wspr_message: FAIL: n mismatch" severity failure;
    assert m_value = M_GOLDEN
      report "tb_wspr_message: FAIL: m mismatch" severity failure;
    assert payload = PAYLOAD_GOLDEN
      report "tb_wspr_message: FAIL: 50-bit payload mismatch" severity failure;

    report "tb_wspr_message: PASS: n=259047992 m=2896997 payload=F7 0C 23 8B 0D 19 40"
      severity note;
    wait;
  end process;

end architecture sim;
