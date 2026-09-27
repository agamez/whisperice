--------------------------------------------------------------------------------
-- gps_time.vhd -- UTC timekeeping disciplined by 1PPS
--
-- Phase 7 of the wspr-icebreaker plan (section 11).  Design rule (plan
-- section 11, spec section 10):
--
--     1PPS is the PRIMARY time reference: time advances one second on every
--     pps_tick.
--     NMEA only says WHICH second it is: a committed parser sentence loads
--     hour/minute/second.
--
-- The NMEA sentence arrives with variable latency after the PPS edge it
-- describes, so loads are applied IMMEDIATELY when strobed (the value then
-- stands until the next PPS); the UART arrival time is never used to infer
-- timing.  After a load, utc_valid rises and stays high; it clears only on
-- reset (plan section 31: GPS losing fix invalidates further transmissions --
-- the scheduler also re-checks via the parser's fix_valid through the load
-- value; a 'V' status simply never loads).
--
-- minute_even flags a VALID time inside an even UTC minute (the WSPR slot
-- minute).  It stays high for the whole minute; the scheduler fires TX at
-- second = 1 (spec section 7: +1.000 s into the even minute).  A fix_warning
-- (status-V NMEA sentence) drops utc_valid so the scheduler stops transmitting
-- until a valid fix returns (plan section 31).
--
-- VHDL-93 only.
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity gps_time is
  port (
    clk          : in  std_logic;
    rst          : in  std_logic;
    -- 1PPS (from pps_measure.vhd): single-cycle tick each GPS second
    pps_tick     : in  std_logic;
    -- committed NMEA time (from gps_parser.vhd)
    time_strobe  : in  std_logic;
    hour_in      : in  natural range 0 to 23;
    minute_in    : in  natural range 0 to 59;
    second_in    : in  natural range 0 to 59;
    -- fix lost (from gps_parser.fix_warning): invalidates UTC (plan section 31)
    fix_warning  : in  std_logic;
    -- current UTC
    utc_valid    : out std_logic;
    hour         : out natural range 0 to 23;
    minute       : out natural range 0 to 59;
    second       : out natural range 0 to 59;
    minute_even  : out std_logic       -- valid AND minute even (whole minute)
  );
end entity gps_time;

architecture rtl of gps_time is

  signal hour_r   : natural range 0 to 23 := 0;
  signal minute_r : natural range 0 to 59 := 0;
  signal second_r : natural range 0 to 59 := 0;
  signal valid_r  : std_logic := '0';

begin

  process (clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        hour_r   <= 0;
        minute_r <= 0;
        second_r <= 0;
        valid_r  <= '0';
      elsif fix_warning = '1' then
        valid_r  <= '0';               -- fix lost: no further TX (plan 31)
      else
        if time_strobe = '1' then
          -- NMEA says which second it is (applied immediately; the 1PPS
          -- remains the edge that ENDS a second -- plan section 11).
          hour_r   <= hour_in;
          minute_r <= minute_in;
          second_r <= second_in;
          valid_r  <= '1';
        elsif pps_tick = '1' then
          -- 1PPS: exactly one second has elapsed.
          if second_r = 59 then
            second_r <= 0;
            if minute_r = 59 then
              minute_r <= 0;
              if hour_r = 23 then
                hour_r <= 0;
              else
                hour_r <= hour_r + 1;
              end if;
            else
              minute_r <= minute_r + 1;
            end if;
          else
            second_r <= second_r + 1;
          end if;
        end if;
      end if;
    end if;
  end process;

  utc_valid   <= valid_r;
  hour        <= hour_r;
  minute      <= minute_r;
  second      <= second_r;
  minute_even <= '1' when valid_r = '1' and (minute_r mod 2) = 0 else '0';

end architecture rtl;
