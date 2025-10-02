library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library xil_defaultlib;
use xil_defaultlib.constants_pkg.all;

entity neuronMatrix is
    generic (
        AXIS_TDATA_WIDTH_G : positive := 64;
        AXIS_TUSER_WIDTH_G : positive := 1
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
end entity neuronMatrix;

architecture rtl of neuronMatrix is
    signal positive_excitation_signal : std_logic;
    signal negative_excitation_signal : std_logic;
    signal positive_spike_signal : std_logic;
    signal negative_spike_signal : std_logic;
    signal s_axis_tready_signal : std_logic;

begin
    neuronPositive : entity work.neuron
        generic map(
            MEMBRANE_POTENTIAL_SIZE => 5
        )
        port map(
            -- I prob want a faster clock in the neurons?
            clk => aclk,
            areset => aresetn,
            in_signal => positive_excitation_signal,
            out_signal => positive_spike_signal
        );

    neuronNegative : entity work.neuron
        generic map(
            MEMBRANE_POTENTIAL_SIZE => 5
        )
        port map(
            -- I prob want a faster clock in the neurons?
            clk => aclk,
            areset => aresetn,
            in_signal => negative_excitation_signal,
            out_signal => negative_spike_signal
        );

    eventDistribution : process (aclk, aresetn)
    begin
        if s_axis_tvalid = '1' and s_axis_tready_signal = '1' then
            if (s_axis_tdata(63 downto 60) = POS_EVT) then
                positive_excitation_signal <= '1';
            else
                positive_excitation_signal <= '0';
            end if;

            negative_excitation_signal <= not positive_excitation_signal;
        end if;
    end process;

    -- Always ready to receive
    s_axis_tready_signal <= '1';
    s_axis_tready <= s_axis_tready_signal;
end rtl;