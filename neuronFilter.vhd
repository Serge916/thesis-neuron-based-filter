library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library xil_defaultlib;
use xil_defaultlib.constants_pkg.all;

entity neuronFilter is
  generic (
    AXIS_TDATA_WIDTH_G : positive := 64;
    AXIS_TUSER_WIDTH_G : positive := 1
  );
  port (
    -- Clock and Reset
    aclk               : in  std_logic;
    aresetn            : in  std_logic;

    -- Input Data Stream
    s_axis_tready      : out std_logic;
    s_axis_tvalid      : in  std_logic;
    s_axis_tdata       : in  std_logic_vector(AXIS_TDATA_WIDTH_G-1 downto 0);
    s_axis_tkeep       : in  std_logic_vector((AXIS_TDATA_WIDTH_G/8)-1 downto 0);
    s_axis_tuser       : in  std_logic_vector(AXIS_TUSER_WIDTH_G-1 downto 0);
    s_axis_tlast       : in  std_logic;

    -- Output Data Stream
    m_axis_tready      : in  std_logic;
    m_axis_tvalid      : out std_logic;
    m_axis_tdata       : out std_logic_vector(AXIS_TDATA_WIDTH_G-1 downto 0);
    m_axis_tkeep       : out std_logic_vector((AXIS_TDATA_WIDTH_G/8)-1 downto 0);
    m_axis_tuser       : out std_logic_vector(AXIS_TUSER_WIDTH_G-1 downto 0);
    m_axis_tlast       : out std_logic
  );
end entity neuronFilter;

architecture rtl of neuronFilter is
  subtype DATA_BUS_LOW_C  is integer range (AXIS_TDATA_WIDTH_G/2)-1 downto 0;

  signal forward_packet        : std_logic := '0';
  signal s_axis_tready_signal  : std_logic;

  signal m_axis_tvalid_reg     : std_logic := '0';
  signal m_axis_tdata_reg      : std_logic_vector(AXIS_TDATA_WIDTH_G-1 downto 0);
  signal m_axis_tkeep_reg      : std_logic_vector((AXIS_TDATA_WIDTH_G/8)-1 downto 0);
  signal m_axis_tuser_reg      : std_logic_vector(AXIS_TUSER_WIDTH_G-1 downto 0);
  signal m_axis_tlast_reg      : std_logic := '0';
begin

  process(aclk, aresetn)
    variable forward : std_logic;
    variable count : unsigned(5 downto 0);
  begin
    if aresetn = '0' then
      forward := '0';
      count := (others => '0');
      forward_packet      <= '0';
      m_axis_tvalid_reg   <= '0';
      m_axis_tdata_reg    <= (others => '0');
      m_axis_tkeep_reg    <= (others => '0');
      m_axis_tuser_reg    <= (others => '0');
      m_axis_tlast_reg    <= '0';
      
    elsif rising_edge(aclk) then
      m_axis_tvalid_reg <= '0';
      
      if s_axis_tvalid = '1' and s_axis_tready_signal = '1' then

        -- TIME_EVT should always go through
        if s_axis_tdata(63 downto 60) = TIME_HIGH_EVT or 
        -- TRIG_EVT should always go through
        s_axis_tdata(63 downto 60) = TIME_HIGH_EVT or 
        -- ROI
         (unsigned(s_axis_tdata(53 downto 43)) > 384 and unsigned(s_axis_tdata(53 downto 43)) < (1280-384) and
         unsigned(s_axis_tdata(42 downto 32)) > 40 and unsigned(s_axis_tdata(42 downto 32)) < (720-40)) then

          forward := '1';
        else
          forward := '0';
        end if;
        
        if forward = '1' then
          m_axis_tvalid_reg <= '1';
          m_axis_tdata_reg  <= s_axis_tdata;
          m_axis_tkeep_reg  <= s_axis_tkeep;
          m_axis_tuser_reg  <= s_axis_tuser;
          m_axis_tlast_reg  <= s_axis_tlast;
        end if;
        forward_packet <= forward;
      end if;
    end if;
  end process;

  -- Always ready to receive data when downstream is ready or when we're going to filter out
  s_axis_tready_signal <= m_axis_tready or not forward_packet;
  s_axis_tready <= s_axis_tready_signal;

  m_axis_tvalid <= m_axis_tvalid_reg;
  m_axis_tdata  <= m_axis_tdata_reg;
  m_axis_tkeep  <= m_axis_tkeep_reg;
  m_axis_tuser  <= m_axis_tuser_reg;
  m_axis_tlast  <= m_axis_tlast_reg;

end rtl;
