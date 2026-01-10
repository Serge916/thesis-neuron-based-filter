library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library xil_defaultlib;
use xil_defaultlib.constants_pkg.all;

entity cropper is
  generic (
    AXIS_TDATA_WIDTH_G : positive := 64;
    AXIS_TUSER_WIDTH_G : positive := 1;
    ROI_WIDTH_PIXEL_AMOUNT : positive := 512;
    ROI_HEIGHT_PIXEL_AMOUNT : positive := 512;
    LET_THROUGH_ONLY_EVENTS : boolean := false
  );
  port (
    -- Clock and Reset
    aclk : in std_logic;
    aresetn : in std_logic;

    -- Input Data Stream
    s_axis_tready : out std_logic;
    s_axis_tvalid : in std_logic;
    s_axis_tdata : in std_logic_vector(AXIS_TDATA_WIDTH_G - 1 downto 0);
    s_axis_tkeep : in std_logic_vector((AXIS_TDATA_WIDTH_G/8) - 1 downto 0);
    s_axis_tuser : in std_logic_vector(AXIS_TUSER_WIDTH_G - 1 downto 0);
    s_axis_tlast : in std_logic;

    -- Output Data Stream
    m_axis_tready : in std_logic;
    m_axis_tvalid : out std_logic;
    m_axis_tdata : out std_logic_vector(AXIS_TDATA_WIDTH_G - 1 downto 0);
    m_axis_tkeep : out std_logic_vector((AXIS_TDATA_WIDTH_G/8) - 1 downto 0);
    m_axis_tuser : out std_logic_vector(AXIS_TUSER_WIDTH_G - 1 downto 0);
    m_axis_tlast : out std_logic
  );
end entity cropper;

architecture rtl of cropper is
  subtype DATA_BUS_LOW_C is integer range (AXIS_TDATA_WIDTH_G/2) - 1 downto 0;
  constant ROI_WIDTH_BASE_PIXEL : positive := (1280 - ROI_WIDTH_PIXEL_AMOUNT)/2;
  constant ROI_WIDTH_FINAL_PIXEL : positive := 1280 - (1280 - ROI_WIDTH_PIXEL_AMOUNT)/2;
  constant ROI_HEIGHT_BASE_PIXEL : positive := (720 - ROI_HEIGHT_PIXEL_AMOUNT)/2;
  constant ROI_HEIGHT_FINAL_PIXEL : positive := 720 - (720 - ROI_HEIGHT_PIXEL_AMOUNT)/2;

  signal m_axis_tvalid_reg : std_logic := '0';
  signal m_axis_tdata_reg : std_logic_vector(AXIS_TDATA_WIDTH_G - 1 downto 0);
  signal m_axis_tkeep_reg : std_logic_vector((AXIS_TDATA_WIDTH_G/8) - 1 downto 0);
  signal m_axis_tuser_reg : std_logic_vector(AXIS_TUSER_WIDTH_G - 1 downto 0);
  signal m_axis_tlast_reg : std_logic := '0';

  -- Handshake signals
  signal can_accept : std_logic;
  signal do_in_hs : std_logic;
  signal do_out_hs : std_logic;

  signal address_map_x : std_logic_vector(10 downto 0);
  signal address_map_y : std_logic_vector(10 downto 0);

begin
  -- Always ready to receive data when downstream is ready or when we're going to filter out
  can_accept <= (not m_axis_tvalid_reg) or (m_axis_tvalid_reg and m_axis_tready);
  s_axis_tready <= can_accept;

  do_in_hs <= s_axis_tvalid and can_accept;
  do_out_hs <= m_axis_tvalid_reg and m_axis_tready;

  m_axis_tvalid <= m_axis_tvalid_reg;
  m_axis_tdata <= m_axis_tdata_reg;
  m_axis_tkeep <= m_axis_tkeep_reg;
  m_axis_tuser <= m_axis_tuser_reg;
  m_axis_tlast <= m_axis_tlast_reg;

  process (aclk)
    variable forward : std_logic;
    variable address_map_x : std_logic_vector(10 downto 0);
    variable address_map_y : std_logic_vector(10 downto 0);

  begin

    if rising_edge(aclk) then
      if aresetn = '0' then
        m_axis_tvalid_reg <= '0';
        m_axis_tdata_reg <= (others => '0');
        m_axis_tkeep_reg <= (others => '0');
        m_axis_tuser_reg <= (others => '0');
        m_axis_tlast_reg <= '0';

      else
        -- If output handshakes, clear valid (unless overwritten by new forward below)
        if do_out_hs = '1' then
          m_axis_tvalid_reg <= '0';
        end if;

        -- Accept new input beat when possible
        if do_in_hs = '1' then
          address_map_x := std_logic_vector(unsigned(s_axis_tdata(53 downto 43)) - to_unsigned(ROI_WIDTH_BASE_PIXEL, 11));
          address_map_y := std_logic_vector(unsigned(s_axis_tdata(42 downto 32)) - to_unsigned(ROI_HEIGHT_BASE_PIXEL, 11));

          -- address_map_x := s_axis_tdata(53 downto 43);
          -- address_map_y := s_axis_tdata(42 downto 32);
          -- TIME_EVT should always go through if flag is set
          if (s_axis_tdata(63 downto 60) = TIME_HIGH_EVT and not LET_THROUGH_ONLY_EVENTS) or
            -- TRIG_EVT should always go through if flag is set
            (s_axis_tdata(63 downto 60) = TRIG_EVT and not LET_THROUGH_ONLY_EVENTS) or
            -- ROI
            (unsigned(s_axis_tdata(53 downto 43)) >= ROI_WIDTH_BASE_PIXEL and unsigned(s_axis_tdata(53 downto 43)) < ROI_WIDTH_FINAL_PIXEL and
            unsigned(s_axis_tdata(42 downto 32)) >= ROI_HEIGHT_BASE_PIXEL and unsigned(s_axis_tdata(42 downto 32)) < ROI_HEIGHT_FINAL_PIXEL) then

            forward := '1';
          else
            forward := '0';
          end if;

          if forward = '1' then
            m_axis_tvalid_reg <= '1';
            m_axis_tdata_reg <= s_axis_tdata(63 downto 54) & address_map_x & address_map_y & s_axis_tdata(31 downto 0);
            m_axis_tkeep_reg <= s_axis_tkeep;
            m_axis_tuser_reg <= s_axis_tuser;
            m_axis_tlast_reg <= s_axis_tlast;
          end if;

        end if;
      end if;
    end if;
  end process;

end rtl;