library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package constants_pkg is
  -- constants
  constant TIME_HIGH_EVT: std_logic_vector(3 downto 0) := "1000";
  constant POS_EVT: std_logic_vector(3 downto 0) := "0001";
  constant NEG_EVT: std_logic_vector(3 downto 0) := "0000";
  constant TRIG_EVT: std_logic_vector(3 downto 0) := "1010";

end package constants_pkg;
