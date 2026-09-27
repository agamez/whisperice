--------------------------------------------------------------------------------
-- gps_uart.vhd -- UART receiver for the PmodGPS NMEA link
--
-- Phase 7 of the wspr-icebreaker plan (doc/wspr_icebreaker_orchestrator_plan.md
-- section 11; frozen parameters: docs/spec.md section 10).  PmodGPS default:
-- 9600 baud, 8 data bits, no parity, 1 stop bit (spec section 10).
--
-- Simple oversampling receiver: the RX line is idle-high; a falling edge
-- starts the frame, every bit is sampled at its centre (half a bit period
-- after the previous sample), and the stop bit must be high (otherwise a
-- framing error is flagged and the byte is discarded).  No FIFO: a new byte
-- completing while data_valid has not been consumed raises overrun (plan
-- section 31: corrupt/missed data must not corrupt the valid time -- the
-- parser simply loses a sentence, which is safe).
--
-- The bit period is CLOCK_HZ/BAUD_RATE truncated to an integer.  At 12 MHz /
-- 9600 baud that is 1250 cycles (exact); the truncation error is within the
-- ~2% tolerance of a 10-bit UART frame for any sane clock (testbenches scale
-- CLOCK_HZ per plan section 21; the functional logic is identical).
--
-- VHDL-93 only (explicit sensitivity lists, no process(all)).
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity gps_uart is
  generic (
    CLOCK_HZ  : positive := 12000000;
    BAUD_RATE : positive := 9600
  );
  port (
    clk            : in  std_logic;
    rst            : in  std_logic;
    rx             : in  std_logic;
    data           : out std_logic_vector(7 downto 0);
    data_valid     : out std_logic;
    framing_error  : out std_logic;
    overrun        : out std_logic
  );
end entity gps_uart;

architecture rtl of gps_uart is

  -- Samples per bit (truncated); centre sample is at half this value.
  constant BIT_CYCLES : positive := CLOCK_HZ / BAUD_RATE;
  constant HALF_BIT   : positive := BIT_CYCLES / 2;

  type state_t is (ST_IDLE, ST_START, ST_DATA, ST_STOP);
  signal state    : state_t := ST_IDLE;

  signal rx_sync  : std_logic := '1';   -- 2-FF synchronizer (plan section 2 style)
  signal rx_meta  : std_logic := '1';
  signal rx_prev  : std_logic := '1';

  signal bit_cnt  : natural range 0 to 7 := 0;
  signal wait_cnt : natural range 0 to BIT_CYCLES := 0;
  signal shifter  : std_logic_vector(7 downto 0) := (others => '0');

  signal valid_r  : std_logic := '0';
  signal frame_r  : std_logic := '0';
  signal overrun_r: std_logic := '0';

begin

  -- Synchronize the asynchronous RX line into the clock domain.
  sync : process (clk)
  begin
    if rising_edge(clk) then
      rx_meta <= rx;
      rx_sync <= rx_meta;
      rx_prev <= rx_sync;
    end if;
  end process sync;

  -- RX state machine.
  rx_fsm : process (clk)
  begin
    if rising_edge(clk) then
      valid_r    <= '0';
      frame_r    <= '0';
      overrun_r  <= '0';

      if rst = '1' then
        state   <= ST_IDLE;
        bit_cnt <= 0;
        wait_cnt<= 0;
      else
        case state is

          when ST_IDLE =>
            if rx_prev = '1' and rx_sync = '0' then
              state    <= ST_START;        -- falling edge: start bit begins
              wait_cnt <= 0;
            end if;

          when ST_START =>
            wait_cnt <= wait_cnt + 1;
            if wait_cnt = HALF_BIT - 1 then
              -- centre of the start bit: must still be low
              if rx_sync = '0' then
                state    <= ST_DATA;
                wait_cnt <= 0;
                bit_cnt  <= 0;
              else
                state    <= ST_IDLE;       -- glitch, not a start bit
              end if;
            end if;

          when ST_DATA =>
            wait_cnt <= wait_cnt + 1;
            if wait_cnt = BIT_CYCLES - 1 then
              -- centre of data bit `bit_cnt` (LSB first)
              shifter <= rx_sync & shifter(7 downto 1);
              wait_cnt<= 0;
              if bit_cnt = 7 then
                state   <= ST_STOP;
              else
                bit_cnt <= bit_cnt + 1;
              end if;
            end if;

          when ST_STOP =>
            wait_cnt <= wait_cnt + 1;
            if wait_cnt = BIT_CYCLES - 1 then
              -- centre of the stop bit
              if rx_sync = '1' then
                valid_r   <= '1';
                overrun_r <= valid_r;   -- previous byte not yet consumed?
              else
                frame_r   <= '1';       -- framing error: byte discarded
              end if;
              state   <= ST_IDLE;          -- next falling edge starts a new frame
              wait_cnt<= 0;
            end if;

        end case;
      end if;
    end if;
  end process rx_fsm;

  data          <= shifter;
  data_valid    <= valid_r;
  framing_error <= frame_r;
  overrun       <= overrun_r;

end architecture rtl;
