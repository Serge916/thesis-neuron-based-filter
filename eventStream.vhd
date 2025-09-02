-- eventStream.vhd (fixed)
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use ieee.std_logic_textio.all;

entity eventStream is
  generic (
    G_FILE : string := "/home/sergio/Projects/thesis/eventFilter/eventFilter.srcs/sources_1/new/in_evt_file.evt";
    G_TCLK : time   := 10 ns
  );
end entity;

architecture sim of eventStream is
  constant C_TDATA_W : positive := 64;
  constant C_TUSER_W : positive := 1;
  constant C_TKEEP_W : positive := C_TDATA_W/8;

  signal aclk    : std_logic := '0';
  signal aresetn : std_logic := '0';

  -- AXIS master (TB -> DUT)
  signal s_axis_tdata  : std_logic_vector(C_TDATA_W-1 downto 0) := (others => '0');
  signal s_axis_tkeep  : std_logic_vector(C_TKEEP_W-1 downto 0) := (others => '0');
  signal s_axis_tvalid : std_logic := '0';
  signal s_axis_tready : std_logic;
  signal s_axis_tlast  : std_logic := '0';
  signal s_axis_tuser  : std_logic_vector(C_TUSER_W-1 downto 0) := (others => '0');

  -- AXIS slave (DUT -> TB)
  signal m_axis_tdata  : std_logic_vector(C_TDATA_W-1 downto 0);
  signal m_axis_tkeep  : std_logic_vector(C_TKEEP_W-1 downto 0);
  signal m_axis_tvalid : std_logic;
  signal m_axis_tready : std_logic := '1';
  signal m_axis_tlast  : std_logic;
  signal m_axis_tuser  : std_logic_vector(C_TUSER_W-1 downto 0);

  file data_f : text open read_mode is G_FILE;
  file log_f  : text open write_mode is "tb_log.txt";
begin
  -- clock & reset
  aclk <= not aclk after G_TCLK/2;

  process
  begin
    aresetn <= '0';
    wait for 5*G_TCLK;
    aresetn <= '1';
    wait;
  end process;

  -- AXIS source driver
  p_src : process
    variable L : line;
    variable v : std_logic_vector(C_TDATA_W-1 downto 0);
  begin
    s_axis_tvalid <= '0';
    s_axis_tlast  <= '0';
    s_axis_tkeep  <= (others => '0');
    s_axis_tdata  <= (others => '0');
    s_axis_tuser  <= (others => '0');

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

      -- Read hex text -> std_logic_vector
      hread(L, v);

      -- Drive this beat
      s_axis_tdata  <= v;
      s_axis_tkeep  <= (others => '1');
      s_axis_tuser  <= (others => '0');

      -- VHDL doesn't have ?:  use an if-statement
      if endfile(data_f) then
        s_axis_tlast <= '1';
      else
        s_axis_tlast <= '0';
      end if;

      s_axis_tvalid <= '1';

      -- Handshake
      loop
        wait until rising_edge(aclk);
        exit when s_axis_tready = '1';
      end loop;

      s_axis_tvalid <= '0';
      s_axis_tlast  <= '0';
    end loop;

    wait for 10*G_TCLK;
    std.env.stop;
    wait;
  end process;

  -- monitor DUT output
  p_sink : process(aclk)
    variable L : line;
  begin
    if rising_edge(aclk) then
      if m_axis_tvalid = '1' and m_axis_tready = '1' then
        hwrite(L, m_axis_tdata);
        if m_axis_tlast = '1' then
          write(L, string'("  (TLAST)"));
        end if;
        writeline(output, L);
        writeline(log_f, L);
      end if;
    end if;
  end process;

  -- DUT
  uut : entity work.neuronFilter
    generic map (
      AXIS_TDATA_WIDTH_G => C_TDATA_W,
      AXIS_TUSER_WIDTH_G => C_TUSER_W
    )
    port map (
      aclk          => aclk,
      aresetn       => aresetn,
      s_axis_tready => s_axis_tready,
      s_axis_tvalid => s_axis_tvalid,
      s_axis_tdata  => s_axis_tdata,
      s_axis_tkeep  => s_axis_tkeep,
      s_axis_tuser  => s_axis_tuser,
      s_axis_tlast  => s_axis_tlast,
      m_axis_tready => m_axis_tready,
      m_axis_tvalid => m_axis_tvalid,
      m_axis_tdata  => m_axis_tdata,
      m_axis_tkeep  => m_axis_tkeep,
      m_axis_tuser  => m_axis_tuser,
      m_axis_tlast  => m_axis_tlast
    );

end architecture;
