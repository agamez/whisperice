-- ============================================================================
-- wspr_symbols.vhd -- WSPR channel symbol formation
-- ============================================================================
-- Part of the wspr-icebreaker WSPR codec (plan §16, Phase 12).
--
-- Combines the interleaved FEC data bits with the frozen synchronisation
-- vector to produce the 162 channel symbols:
--
--     tone_symbol(i) = 2 * data_bit(i) + sync_bit(i)     -> {0,1,2,3}
--
-- The rule is written out explicitly, and each symbol is stored as a 2-bit
-- field in `tones`: symbol i occupies tones(2*i+1 downto 2*i), with the LSB
-- at 2*i.  So  tones(2*i) = sync_bit(i)  and  tones(2*i+1) = data_bit(i).
--
-- Sources (pinned WSJT-X 2.7.0; docs/spec.md §5):
--   * lib/wsprd/WSPRcode.f90:118    (2*dat(i)+sync(i))
--   * lib/genwspr.f90:24-26         (itone(i)=npr3(i)+2*symbol(i))
--   * lib/wsprd/wsprsim_utils.c:306-308 (symbols[i]=2*channelbits[i]+pr3[i])
--
-- The 162-bit synchronisation vector itself is the named constant in
-- wspr_sync.vhd, instantiated here.
-- ============================================================================
library ieee;
use ieee.std_logic_1164.all;

entity wspr_symbols is
  port (
    data_bits : in  std_logic_vector(0 to 161);  -- interleaved FEC bits
    sync_bits : out std_logic_vector(0 to 161);  -- exposed sync vector
    tones     : out std_logic_vector(0 to 323)   -- 162 x 2-bit symbols
  );
end entity wspr_symbols;

architecture rtl of wspr_symbols is
  signal sync_vec : std_logic_vector(0 to 161);
begin

  -- Frozen synchronisation vector (spec §5, WSPRcode.f90:17-26).
  sync_gen : entity work.wspr_sync
    port map (
      sync_bits => sync_vec
    );

  sync_bits <= sync_vec;

  -- tone_symbol = 2*data_bit + sync_bit, one symbol per data/sync bit.
  process (data_bits, sync_vec)
    variable tone : integer range 0 to 3;
  begin
    for i in 0 to 161 loop
      tone := 0;
      if data_bits(i) = '1' then
        tone := tone + 2;          -- 2 * data_bit
      end if;
      if sync_vec(i) = '1' then
        tone := tone + 1;          -- + sync_bit
      end if;

      -- LSB at 2*i, MSB at 2*i+1 (the output vector is ascending, so the two
      -- bits of a symbol are assigned individually rather than as a slice).
      case tone is
        when 0 =>
          tones(2 * i)     <= '0';
          tones(2 * i + 1) <= '0';
        when 1 =>
          tones(2 * i)     <= '1';
          tones(2 * i + 1) <= '0';
        when 2 =>
          tones(2 * i)     <= '0';
          tones(2 * i + 1) <= '1';
        when 3 =>
          tones(2 * i)     <= '1';
          tones(2 * i + 1) <= '1';
      end case;
    end loop;
  end process;

end architecture rtl;
