library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package constants_pkg is
  -- constants
  constant TIME_HIGH_EVT : std_logic_vector(3 downto 0) := "1000";
  constant POS_EVT : std_logic_vector(3 downto 0) := "0001";
  constant NEG_EVT : std_logic_vector(3 downto 0) := "0000";
  constant TRIG_EVT : std_logic_vector(3 downto 0) := "1010";
  constant NEGATIVE_CHANNEL : std_logic := '0';
  constant POSITIVE_CHANNEL : std_logic := '1';
  constant SNN_FRAME_HEIGHT : integer := 128;
  constant SNN_FRAME_WIDTH : integer := 128;

  -- 128 neurons per row. 8 neurons activated per AXI read. 16 clusters per row
  constant NEURONS_PER_CLUSTER : integer := 8;
  constant CLUSTERS_PER_ROW : integer := 128/8;
end package constants_pkg;