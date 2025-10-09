library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library xil_defaultlib;
use xil_defaultlib.constants_pkg.all;

entity neuron is
    generic (
        MEMBRANE_POTENTIAL_SIZE : positive := 5;
        MEMBRANE_INCREASE_VALUE : positive := 12;
        MEMBRANE_DECAY_VALUE : positive := 1
    );
    port (
        clk : in std_logic;
        areset : in std_logic;
        enable : in std_logic;
        in_signal : in std_logic;
        out_signal : out std_logic
    );
end entity neuron;

architecture rtl of neuron is
    constant initial_potential : std_logic_vector(MEMBRANE_POTENTIAL_SIZE downto 0) := (0 => '1', others => '0');
    signal membrane_potential : std_logic_vector(MEMBRANE_POTENTIAL_SIZE downto 0) := initial_potential;

begin
    process (clk, areset, in_signal)
    begin
        if areset = '0' then
            membrane_potential <= initial_potential;
        elsif rising_edge(clk) then
            if membrane_potential(MEMBRANE_POTENTIAL_SIZE) = '1' then
                membrane_potential <= initial_potential;
            elsif in_signal = '1' and enable = '1' then
                membrane_potential <= std_logic_vector(unsigned(membrane_potential) + MEMBRANE_INCREASE_VALUE);
            else
                if (unsigned(membrane_potential(MEMBRANE_POTENTIAL_SIZE - 1 downto 0)) /= 1) then
                    membrane_potential <= std_logic_vector(unsigned(membrane_potential) - MEMBRANE_DECAY_VALUE);
                end if;
            end if;
        end if;

    end process;
    out_signal <= membrane_potential(MEMBRANE_POTENTIAL_SIZE);
end rtl;