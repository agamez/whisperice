-- ============================================================================
-- wspr_sync.vhd -- WSPR 162-bit synchronisation vector
-- ============================================================================
-- Part of the wspr-icebreaker WSPR codec (plan §16, Phase 12).
--
-- The WSPR synchronisation vector is a fixed 162-bit sequence that is added
-- to the FEC data bits to select the transmitted tone:
--
--     tone_symbol(i) = 2 * data_bit(i) + sync_bit(i)     -> {0,1,2,3}
--
-- This file owns the frozen *vector* as a single named constant.  The
-- combination itself is implemented explicitly in wspr_symbols.vhd (spec §5),
-- together with the interleaved FEC data, so each step stays visible.
--
-- Source of truth (pinned WSJT-X 2.7.0; docs/spec.md §5):
--   * lib/wsprd/WSPRcode.f90:17-26   sync(162) data statement
--   * lib/genwspr.f90:9-19           npr3(162) (TX, identical)
--   * lib/wsprd/wsprsim_utils.c:169-178 / lib/wsprd/wsprd.c:55-63 (RX, identical)
--
-- sync_bits(0) is the sync bit for tone symbol 0 (first symbol).
-- ============================================================================
library ieee;
use ieee.std_logic_1164.all;

entity wspr_sync is
  port (
    sync_bits : out std_logic_vector(0 to 161)
  );
end entity wspr_sync;

architecture rtl of wspr_sync is

  -- Frozen 162-bit synchronisation vector, verbatim from
  -- lib/wsprd/WSPRcode.f90:17-26 (also lib/genwspr.f90:9-19).
  -- Read left-to-right = sync_bits(0) .. sync_bits(161).
  constant SYNC_VECTOR : std_logic_vector(0 to 161) :=
    "11000000100011100010010111100000001001010000001011001101000110100001101010101001" &
    "00101100011010100010000010010011101100110100011100000101001100000001101011000110" &
    "00";

begin

  sync_bits <= SYNC_VECTOR;

end architecture rtl;
