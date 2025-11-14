library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.std_logic_misc.all;

library xil_defaultlib;
use xil_defaultlib.constants_pkg.all;

entity neuronMatrix is
    generic (
        AXIS_TDATA_WIDTH_G : positive := 64;
        AXIS_TUSER_WIDTH_G : positive := 1;
        GRID_SIZE_Y : positive := 128;
        GRID_SIZE_X : positive := 128;
        SPIKE_ACCUMULATION_LIMIT : positive := 15000;
        MEMBRANE_POTENTIAL_SIZE : positive := 8
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
    signal s_axis_tready_signal : std_logic;
    -- X axis is 0 to 15 clusters of 32 elements. 16*32=512
    signal route_x : unsigned(3 downto 0);
    -- Y axis is 0 to 127
    signal route_y : unsigned(6 downto 0);
    signal enable_x : unsigned(0 to 127);
    signal enable_y : unsigned(0 to 127);

    signal spike_counter : natural range 0 to SPIKE_ACCUMULATION_LIMIT;
    signal spike_counter_signal : std_logic;

    -- Per message, 8 Processing Elements are needed
    signal active_pixel : std_logic_vector(7 downto 0);

    type filter_memory_t is array (0 to 127, 0 to 127, 0 to 1) of unsigned(MEMBRANE_POTENTIAL_SIZE - 1 downto 0);
    signal filter_memory : filter_memory_t := (others => (others => (others => (others => '0'))));
    signal valid_event : std_logic;

    signal decay_trigger : std_logic;
    signal decay_counter : unsigned(7 downto 0);
begin
    eventDistribution : process (aclk, aresetn)
    begin
        if rising_edge(aclk) then
            positive_excitation_signal <= '0';
            if s_axis_tvalid = '1' and s_axis_tready_signal = '1' then
                -- Divide by 4 or 2 shifts right, same as leaving out the 2LSb
                -- Target dimension is 128, only 7 bits needed. Therefore, get the slice [8:2]
                -- On the X axis, we divide by 7 (128 in total), as neurons are clustered by EVT2.1
                route_x <= unsigned(s_axis_tdata(51 downto 48));
                route_y <= unsigned(s_axis_tdata(40 downto 34));

                valid_event <= '1';

                if (s_axis_tdata(63 downto 60) = POS_EVT) then
                    positive_excitation_signal <= '1';
                else
                    positive_excitation_signal <= '0';
                end if;

                active_pixel(7) <= or_reduce(s_axis_tdata(31 downto 28));
                active_pixel(6) <= or_reduce(s_axis_tdata(27 downto 24));
                active_pixel(5) <= or_reduce(s_axis_tdata(23 downto 20));
                active_pixel(4) <= or_reduce(s_axis_tdata(19 downto 16));
                active_pixel(3) <= or_reduce(s_axis_tdata(15 downto 12));
                active_pixel(2) <= or_reduce(s_axis_tdata(11 downto 8));
                active_pixel(1) <= or_reduce(s_axis_tdata(7 downto 4));
                active_pixel(0) <= or_reduce(s_axis_tdata(3 downto 0));
            else
                valid_event <= '0';
            end if;
        end if;
    end process;

    eventIntegration : process (aclk, aresetn)
        variable xi : integer;
        variable yi : integer;
    begin

        if rising_edge(aclk) then
            if valid_event = '1' then
                for i in 0 to 7 loop
                    xi := to_integer(route_x) * 8 + i;
                    yi := to_integer(route_y);

                    if active_pixel(i) = '1' then
                        if positive_excitation_signal = '1' then
                            -- If initialized, shift
                            if filter_memory(yi, xi, POSITIVE_CHANNEL) /= x"00" then
                                filter_memory(yi, xi, POSITIVE_CHANNEL) <= filter_memory(yi, xi, POSITIVE_CHANNEL) sll 1;
                            else
                                -- If not initialized, make it 1
                                filter_memory(yi, xi, POSITIVE_CHANNEL) <= x"01";
                            end if;
                        else
                            -- Same for the NEG channel
                            if filter_memory(yi, xi, NEGATIVE_CHANNEL) /= x"00" then
                                filter_memory(yi, xi, NEGATIVE_CHANNEL) <= filter_memory(yi, xi, NEGATIVE_CHANNEL) sll 1;
                            else
                                filter_memory(yi, xi, NEGATIVE_CHANNEL) <= x"01";
                            end if;
                        end if;
                    end if;
                end loop;
            end if;
        end if;
    end process;

    -- Always ready to receive
    s_axis_tready_signal <= '1';
    s_axis_tready <= s_axis_tready_signal;
end rtl;