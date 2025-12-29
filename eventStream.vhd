-- eventStream.vhd (fixed)
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use ieee.std_logic_textio.all;

entity eventStream is
  generic (
    G_FILE : string := "/home/sergio/Projects/thesis/eventFilter/eventFilter.srcs/sources_1/new/in_evt_file.evt";
    G_TCLK : time := 100 ns;
    G_TS_UNIT : time := 1 us; -- one timestamp tick = 1 us 
    TIME_SPACED_EVENTS : std_logic := '1';
    O_FILE : string := "/home/sergio/Projects/thesis/eventFilter/eventFilter.srcs/sources_1/new/output.txt"
  );
end entity;

architecture sim of eventStream is
  constant C_TDATA_W : positive := 64;
  constant C_TUSER_W : positive := 1;
  constant C_TKEEP_W : positive := C_TDATA_W/8;

  signal aclk : std_logic := '0';
  signal aresetn : std_logic := '0';

  -- AXIS master (TB -> DUT)
  signal s_axis_tdata : std_logic_vector(C_TDATA_W - 1 downto 0) := (others => '0');
  signal s_axis_tkeep : std_logic_vector(C_TKEEP_W - 1 downto 0) := (others => '0');
  signal s_axis_tvalid : std_logic := '0';
  signal s_axis_tready : std_logic;
  signal s_axis_tlast : std_logic := '0';
  signal s_axis_tuser : std_logic_vector(C_TUSER_W - 1 downto 0) := (others => '0');

  -- AXIS slave (DUT -> TB)
  signal m_axis_tdata : std_logic_vector(C_TDATA_W - 1 downto 0);
  signal m_axis_tkeep : std_logic_vector(C_TKEEP_W - 1 downto 0);
  signal m_axis_tvalid : std_logic;
  signal m_axis_tready : std_logic := '1';
  signal m_axis_tlast : std_logic;
  signal m_axis_tuser : std_logic_vector(C_TUSER_W - 1 downto 0);

  file data_f : text open read_mode is G_FILE;
  file log_f : text open write_mode is O_FILE;
begin
  -- clock & reset
  aclk <= not aclk after G_TCLK/2;

  process
  begin
    aresetn <= '0';
    wait for 5 * G_TCLK;
    aresetn <= '1';
    wait;
  end process;

  -- AXIS source driver
  p_src : process
    variable L : line;
    variable v : std_logic_vector(C_TDATA_W - 1 downto 0);

    -- timestamp reconstruction
    variable time_high28 : unsigned(27 downto 0) := (others => '0');
    variable ts : unsigned(33 downto 0); -- 28+6 = 34 bits
    variable ts0 : unsigned(33 downto 0) := (others => '0');
    variable prev_ts : unsigned(33 downto 0) := (others => '0');
    variable first_event : boolean := true;

    -- parts
    variable hdr4 : std_logic_vector(3 downto 0);
    variable low6 : unsigned(5 downto 0);

    variable dt_ticks : integer;
  begin
    s_axis_tvalid <= '0';
    s_axis_tlast <= '0';
    s_axis_tkeep <= (others => '0');
    s_axis_tdata <= (others => '0');
    s_axis_tuser <= (others => '0');

    wait until aresetn = '1';
    wait until rising_edge(aclk);

    while not endfile(data_f) loop
      readline(data_f, L);

      -- Skip empty lines and comments starting with "--"
      if (L = null) or (L.all'length = 0) then
        next;
      elsif (L.all'length >= 2) and (L.all(1) = '-') and (L.all(2) = '-') then
        next;
      end if;

      -- Parse hex word
      hread(L, v);

      -- If events are spaced in time, keep track of delays. Else, source it out directly
      if TIME_SPACED_EVENTS = '1' then

        -- Header nibble
        hdr4 := v(63 downto 60);

        --------------------------------------
        -- TIME HIGH WORD: update time_high28
        --------------------------------------
        if hdr4 = x"8" then
          -- next 28 bits are high time
          time_high28 := unsigned(v(59 downto 32));
          next; -- To avoid raising the Non-monotonic warning. Gotta rework a bit the logic in case printing this is needed
        end if;

        --------------------------------------------------------------------
        -- NORMAL EVENT WORD: reconstruct timestamp and delay appropriately
        --------------------------------------------------------------------
        low6 := unsigned(v(59 downto 54));
        ts := (resize(time_high28, ts'length) sll 6) or resize(low6, ts'length);

        -- shift time so first event is at 0
        if first_event then
          ts0 := ts;
          prev_ts := ts;
          first_event := false;
          -- no delay for first event (it will be sent "now")
        else
          -- dt = current - previous
          dt_ticks := to_integer(ts) - to_integer(prev_ts);
          prev_ts := ts;

          -- If dt_ticks is negative. Something weird happened
          if dt_ticks < 0 then
            report "Non-monotonic timestamp (negative dt)" severity warning;
          else
            -- wait dt * unit before sending next event
            wait for (dt_ticks * G_TS_UNIT);
          end if;
        end if;
      end if;

      -- Align to clock edge if you want events launched on rising edges
      wait until rising_edge(aclk);

      -- Drive this beat
      s_axis_tdata <= v;
      s_axis_tkeep <= (others => '1');
      s_axis_tuser <= (others => '0');
      s_axis_tvalid <= '1';

      -- TLAST only if this is the last *event*, not last line.
      -- We can't easily know that without peeking ahead, so keep TLAST=0
      -- unless format marks it in the word itself.
      s_axis_tlast <= '0';

      -- Handshake
      loop
        wait until rising_edge(aclk);
        exit when s_axis_tready = '1';
      end loop;

      s_axis_tvalid <= '0';
    end loop;

    wait for 10 * G_TCLK;
    std.env.stop;
    wait;
  end process;

  -- monitor DUT output
  p_sink : process
    variable L_row : line; -- for log file (row-based, binary)
    variable L_con : line; -- for console (per word, hex)
  begin
    -- wait for reset
    wait until aresetn = '1';

    L_row := null;

    while true loop
      wait until rising_edge(aclk);

      if m_axis_tvalid = '1' and m_axis_tready = '1' then
        ----------------------------------------------------------------
        -- 1) CONSOLE: print EVERY WORD (hex, one line per beat)
        ----------------------------------------------------------------
        L_con := null; -- new line each beat
        hwrite(L_con, m_axis_tdata); -- hex output
        if m_axis_tlast = '1' then
          write(L_con, string'("  (TLAST)"));
        end if;
        writeline(output, L_con); -- print every beat

        ----------------------------------------------------------------
        -- 2) LOG FILE: keep current behavior (one row per line, binary)
        ----------------------------------------------------------------
        -- accumulate binary words for this row
        -- (add separator if you like)
        -- write(L_row, string'(" "));
        write(L_row, m_axis_tdata); -- binary

        -- end of row?
        if m_axis_tlast = '1' then
          writeline(log_f, L_row); -- write full row to file
          L_row := null; -- reset for next row
        end if;
      end if;
    end loop;
  end process;

  -- DUT
  uut : entity work.neuronFilter
    generic map(
      AXIS_TDATA_WIDTH_G => C_TDATA_W,
      AXIS_TUSER_WIDTH_G => C_TUSER_W
    )
    port map(
      aclk => aclk,
      aresetn => aresetn,
      s_axis_tready => s_axis_tready,
      s_axis_tvalid => s_axis_tvalid,
      s_axis_tdata => s_axis_tdata,
      s_axis_tkeep => s_axis_tkeep,
      s_axis_tuser => s_axis_tuser,
      s_axis_tlast => s_axis_tlast,
      m_axis_tready => m_axis_tready,
      m_axis_tvalid => m_axis_tvalid,
      m_axis_tdata => m_axis_tdata,
      m_axis_tkeep => m_axis_tkeep,
      m_axis_tuser => m_axis_tuser,
      m_axis_tlast => m_axis_tlast
    );

end architecture;