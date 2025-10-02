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
begin 
  cropper: entity work.cropper
  generic map(
    AXIS_TDATA_WIDTH_G =>  64,
    AXIS_TUSER_WIDTH_G =>  1
  )
  port map(
    -- Clock and Reset
    aclk               => aclk,
    aresetn            => aresetn,

    -- Input Data Stream to Cropper
    s_axis_tready      => s_axis_tready,
    s_axis_tvalid      => s_axis_tvalid,
    s_axis_tdata       => s_axis_tdata,
    s_axis_tkeep       => s_axis_tkeep,
    s_axis_tuser       => s_axis_tuser,
    s_axis_tlast       => s_axis_tlast,

    -- Cropper to Output Data Stream
    m_axis_tready      => m_axis_tready,
    m_axis_tvalid      => m_axis_tvalid,
    m_axis_tdata       => m_axis_tdata,
    m_axis_tkeep       => m_axis_tkeep,
    m_axis_tuser       => m_axis_tuser,
    m_axis_tlast       => m_axis_tlast
  );

end rtl;
