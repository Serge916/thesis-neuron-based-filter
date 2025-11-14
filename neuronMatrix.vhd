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
    signal s_axis_tready_signal : std_logic;
    -- X axis is 0 to 15 clusters of 32 elements. 16*32=512
    signal route_x : unsigned(3 downto 0);
    -- Y axis is 0 to 127
    signal route_y : unsigned(6 downto 0);

    signal spike_counter : natural range 0 to SPIKE_ACCUMULATION_LIMIT;
    signal spike_counter_signal : std_logic;

    -- Per message, 8 Processing Elements are needed
    signal active_pixel : std_logic_vector(7 downto 0);

    type filter_memory_t is array (0 to (SNN_FRAME_HEIGHT * SNN_FRAME_WIDTH/NEURONS_PER_CLUSTER) - 1) of unsigned(MEMBRANE_POTENTIAL_SIZE * NEURONS_PER_CLUSTER - 1 downto 0);
    constant INITIAL_WORD : unsigned(MEMBRANE_POTENTIAL_SIZE * NEURONS_PER_CLUSTER - 1 downto 0) := (others => '0');
    signal filter_negative_memory : filter_memory_t := (others => INITIAL_WORD);
    signal filter_positive_memory : filter_memory_t := (others => INITIAL_WORD);
    attribute ram_style : string;
    attribute ram_style of filter_negative_memory : signal is "block";
    attribute ram_style of filter_positive_memory : signal is "block";

    signal valid_event : std_logic;
    signal valid_event_d : std_logic;
    signal valid_event_dd : std_logic;

    signal memory_address : integer range 0 to (SNN_FRAME_HEIGHT * SNN_FRAME_WIDTH/NEURONS_PER_CLUSTER) - 1 := 0;
    signal memory_address_d : integer range 0 to (SNN_FRAME_HEIGHT * SNN_FRAME_WIDTH/NEURONS_PER_CLUSTER) - 1 := 0;
    signal memory_address_dd : integer range 0 to (SNN_FRAME_HEIGHT * SNN_FRAME_WIDTH/NEURONS_PER_CLUSTER) - 1 := 0;

    signal excitation_polarity : std_logic;
    signal excitation_polarity_d : std_logic;
    signal excitation_polarity_dd : std_logic;

    signal decay_trigger : std_logic;
    signal decay_counter : unsigned(7 downto 0);

    signal word_in : unsigned(MEMBRANE_POTENTIAL_SIZE * NEURONS_PER_CLUSTER - 1 downto 0);
    signal word_out : unsigned(MEMBRANE_POTENTIAL_SIZE * NEURONS_PER_CLUSTER - 1 downto 0);
begin
    eventDistribution : process (aclk, aresetn)
    begin
        if rising_edge(aclk) then
            excitation_polarity <= '0';
            if s_axis_tvalid = '1' and s_axis_tready_signal = '1' then
                -- Divide by 4 or 2 shifts right, same as leaving out the 2LSb
                -- Target dimension is 128, only 7 bits needed. Therefore, get the slice [8:2]
                -- On the X axis, we divide by 7 (128 in total), as neurons are clustered by EVT2.1
                route_x <= unsigned(s_axis_tdata(51 downto 48));
                route_y <= unsigned(s_axis_tdata(40 downto 34));
                memory_address <= to_integer(unsigned(s_axis_tdata(40 downto 34))) * CLUSTERS_PER_ROW + to_integer(unsigned(s_axis_tdata(51 downto 48)));
                valid_event <= '1';

                -- Read the value from memory
                if (s_axis_tdata(63 downto 60) = POS_EVT) then
                    excitation_polarity <= POSITIVE_CHANNEL;
                else
                    excitation_polarity <= NEGATIVE_CHANNEL;
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

    readOut : process (aclk)
    begin
        if rising_edge(aclk) then
            excitation_polarity_d <= excitation_polarity;
            valid_event_d <= valid_event;
            memory_address_d <= memory_address;

            if valid_event = '1' then
                if excitation_polarity = POSITIVE_CHANNEL then
                    word_in <= filter_positive_memory(memory_address);
                else
                    word_in <= filter_negative_memory(memory_address);
                end if;
            end if;
        end if;
    end process;

    eventIntegration : process (aclk)
        variable cell : unsigned(MEMBRANE_POTENTIAL_SIZE - 1 downto 0);
    begin
        if rising_edge(aclk) then
            excitation_polarity_dd <= excitation_polarity_d;
            valid_event_dd <= valid_event_d;
            memory_address_dd <= memory_address_d;

            word_out <= word_in;
            -- Write back updated cluster from PREVIOUS cycle's event
            if valid_event_d = '1' then
                for i in 0 to NEURONS_PER_CLUSTER - 1 loop
                    if active_pixel(i) = '1' then
                        -- extract this neuron
                        cell := word_in((i + 1) * MEMBRANE_POTENTIAL_SIZE - 1 downto i * MEMBRANE_POTENTIAL_SIZE);

                        if cell /= INITIAL_WORD then
                            cell := cell sll 1;
                        else
                            cell := to_unsigned(1, MEMBRANE_POTENTIAL_SIZE);
                        end if;

                        -- write updated cell back into word_out
                        word_out((i + 1) * MEMBRANE_POTENTIAL_SIZE - 1 downto i * MEMBRANE_POTENTIAL_SIZE) <= cell;
                    end if;
                end loop;
            end if;
        end if;
    end process;

    writeBack : process (aclk)
    begin
        if rising_edge(aclk) then
            if valid_event_dd = '1' then
                if excitation_polarity_dd = POSITIVE_CHANNEL then
                    filter_positive_memory(memory_address_dd) <= word_out;
                else
                    filter_negative_memory(memory_address_dd) <= word_out;
                end if;
            end if;
        end if;
    end process;
    -- Always ready to receive
    s_axis_tready_signal <= '1';
    s_axis_tready <= s_axis_tready_signal;
end rtl;