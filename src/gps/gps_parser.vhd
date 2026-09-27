--------------------------------------------------------------------------------
-- gps_parser.vhd -- minimal NMEA RMC parser (UTC time + fix validity only)
--
-- Phase 7 of the wspr-icebreaker plan (section 11; spec section 10).  The plan
-- mandates parsing ONLY the fields strictly required and preferring a single
-- stable sentence type.  This parser accepts $--RMC sentences and extracts:
--
--     field 2: UTC time hhmmss.ss  -> hour, minute, second
--     field 3: status A (valid) / V (warning) -> fix_valid
--
-- The sentence type is a named constant (RMC); whether this PmodGPS unit
-- actually emits RMC is PENDING-HARDWARE (spec section 16).
--
-- A sentence is committed only if ALL of: checksum matches (XOR of the bytes
-- between '$' and '*'), address field ends with RMC, field 2 carried exactly
-- six digits forming a valid hhmmss, and field 3 status is 'A'.  Otherwise the
-- previous outputs are retained and sentence_error pulses (plan section 31:
-- corrupt NMEA must not change the existing valid time).
--
-- Interface: byte stream from gps_uart.  On a committed sentence time_strobe
-- pulses and hour/minute/second/fix_valid update together.  NOTE (plan
-- section 11): the NMEA arrival time is NEVER a time reference -- it only
-- says which second it is; gps_time.vhd advances time on the 1PPS tick.
--
-- VHDL-93 only (explicit sensitivity lists, no process(all)).
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity gps_parser is
  port (
    clk            : in  std_logic;
    rst            : in  std_logic;
    -- byte stream from gps_uart
    data           : in  std_logic_vector(7 downto 0);
    data_valid     : in  std_logic;
    -- committed outputs (retained on corrupt sentences)
    time_strobe    : out std_logic;     -- 1-cycle pulse on a committed sentence
    hour           : out natural range 0 to 23;
    minute         : out natural range 0 to 59;
    second         : out natural range 0 to 59;
    fix_valid      : out std_logic;
    sentence_error : out std_logic;     -- 1-cycle pulse on a rejected sentence
    fix_warning    : out std_logic      -- 1-cycle pulse: checksum-valid RMC
  );                                    -- with status V (fix lost -- plan 31)
end entity gps_parser;

architecture rtl of gps_parser is

  constant SENTENCE_TYPE : string := "RMC";
  constant CR : character := character'val(13);
  constant LF : character := character'val(10);

  type state_t is (ST_IDLE, ST_BODY, ST_CHK1, ST_CHK2, ST_COMMIT);
  signal state : state_t := ST_IDLE;

  signal checksum : std_logic_vector(6 downto 0) := (others => '0');
  signal chk_hi   : natural range 0 to 15 := 0;
  signal chk_lo   : natural range 0 to 15 := 0;

  signal field_idx     : natural range 0 to 15 := 0;
  signal char_in_field : natural range 0 to 15 := 0;
  signal addr3 : string(1 to 3) := "   ";  -- last 3 chars of the address field
  signal time_digits : natural range 0 to 999999 := 0;
  signal digit_cnt   : natural range 0 to 15 := 0;
  signal status_ok   : boolean := false;
  signal is_rmc      : boolean := false;

  signal hour_r   : natural range 0 to 23 := 0;
  signal minute_r : natural range 0 to 59 := 0;
  signal second_r : natural range 0 to 59 := 0;
  signal valid_r  : std_logic := '0';
  signal strobe_r : std_logic := '0';
  signal err_r    : std_logic := '0';
  signal warn_r   : std_logic := '0';

  -- address-field match: SENTENCE_TYPE as characters
  function type_char(i : positive) return character is
  begin
    return SENTENCE_TYPE(i);
  end function type_char;

begin

  process (clk)
    variable ch : character;
    variable d  : natural range 0 to 9;
    variable hh, mm, ss : natural range 0 to 99;
    variable rxed : natural range 0 to 255;
    variable ok   : boolean;
  begin
    if rising_edge(clk) then
      strobe_r <= '0';
      err_r    <= '0';
      warn_r   <= '0';

      if rst = '1' then
        state      <= ST_IDLE;
        field_idx  <= 0;
        char_in_field <= 0;
        checksum   <= (others => '0');
        digit_cnt  <= 0;
        status_ok  <= false;
        is_rmc     <= false;
      elsif data_valid = '1' then
        ch    := character'val(to_integer(unsigned(data)));
        rxed  := to_integer(unsigned(data));

        case state is

          when ST_IDLE =>
            if ch = '$' then
              state         <= ST_BODY;
              checksum      <= (others => '0');
              field_idx     <= 0;
              char_in_field <= 0;
              digit_cnt     <= 0;
              status_ok     <= false;
              is_rmc        <= false;
              addr3         <= "   ";
            end if;                        -- ignore bytes between sentences

          when ST_BODY =>
            if ch = '*' then
              state <= ST_CHK1;            -- checksum hex digits follow
            elsif ch = CR or ch = LF then
              state <= ST_IDLE;            -- no checksum: reject
              err_r <= '1';
            else
              checksum <= checksum xor data(6 downto 0);
              if ch = ',' then
                field_idx     <= field_idx + 1;
                char_in_field <= 0;
              else
                char_in_field <= char_in_field + 1;
                -- address field: slide the last three characters
                if field_idx = 0 then
                  addr3(1) <= addr3(2);
                  addr3(2) <= addr3(3);
                  addr3(3) <= ch;
                  if char_in_field >= 2 then
                    is_rmc <= (addr3(2) = type_char(1))
                              and (addr3(3) = type_char(2))
                              and (ch = type_char(3));
                  end if;
                end if;
                -- field 2: time digits hhmmss (ignore any .ss fraction)
                if field_idx = 1 and char_in_field <= 5 then
                  if ch >= '0' and ch <= '9' then
                    d := character'pos(ch) - character'pos('0');
                    time_digits <= (time_digits * 10 + d) mod 1000000;
                    digit_cnt   <= digit_cnt + 1;
                  end if;
                end if;
                -- field 3: status character ('A' = valid)
                if field_idx = 2 and char_in_field = 0 then
                  status_ok <= (ch = 'A');
                end if;
              end if;
            end if;

          when ST_CHK1 =>                   -- first hex digit of the checksum
            if ch >= '0' and ch <= '9' then
              chk_hi <= character'pos(ch) - character'pos('0');
              state  <= ST_CHK2;
            elsif ch >= 'A' and ch <= 'F' then
              chk_hi <= character'pos(ch) - character'pos('A') + 10;
              state  <= ST_CHK2;
            else
              state <= ST_IDLE;             -- malformed checksum
              err_r <= '1';
            end if;

          when ST_CHK2 =>                   -- second hex digit, then commit
            if ch >= '0' and ch <= '9' then
              chk_lo <= character'pos(ch) - character'pos('0');
              state  <= ST_COMMIT;
            elsif ch >= 'A' and ch <= 'F' then
              chk_lo <= character'pos(ch) - character'pos('A') + 10;
              state  <= ST_COMMIT;
            else
              state <= ST_IDLE;
              err_r <= '1';
            end if;

          when ST_COMMIT =>
            -- checksum compares against everything between $ and *
            -- NOTE: status_ok is deliberately NOT part of ok -- a
            -- checksum-valid RMC with status V must reach the warning path
            -- (fix lost), not the rejection path (plan section 31).
            ok := (chk_hi * 16 + chk_lo = to_integer(unsigned(checksum)))
                  and is_rmc
                  and (digit_cnt = 6);
            if ok then
              hh := time_digits / 10000;
              mm := (time_digits / 100) mod 100;
              ss := time_digits mod 100;
              if hh <= 23 and mm <= 59 and ss <= 59 then
                if status_ok then
                  hour_r   <= hh;
                  minute_r <= mm;
                  second_r <= ss;
                  valid_r  <= '1';
                  strobe_r <= '1';
                else
                  warn_r   <= '1';          -- status V: fix lost (plan 31)
                end if;
                state <= ST_IDLE;
              else
                state <= ST_IDLE;           -- impossible time: reject
                err_r <= '1';
              end if;
            else
              state <= ST_IDLE;             -- corrupt sentence: retain outputs
              err_r <= '1';
            end if;

          when others =>
            state <= ST_IDLE;

        end case;
      end if;
    end if;
  end process;

  -- Committed outputs: retained unchanged on any rejected sentence
  -- (plan section 31).
  time_strobe    <= strobe_r;
  hour           <= hour_r;
  minute         <= minute_r;
  second         <= second_r;
  fix_valid      <= valid_r;
  sentence_error <= err_r;
  fix_warning    <= warn_r;

end architecture rtl;
