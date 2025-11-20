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
        DECAY_COUNTER_LIMIT : positive := 10240;
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
    signal spike_counter_hit : std_logic := '0';

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

    signal decay_counter : natural range 0 to DECAY_COUNTER_LIMIT := 0;
    signal decay_counter_hit : std_logic;

    signal word_in : unsigned(MEMBRANE_POTENTIAL_SIZE * NEURONS_PER_CLUSTER - 1 downto 0);
    signal word_out : unsigned(MEMBRANE_POTENTIAL_SIZE * NEURONS_PER_CLUSTER - 1 downto 0);

    type activation_t is array (0 to (SNN_FRAME_HEIGHT * SNN_FRAME_WIDTH/NEURONS_PER_CLUSTER) - 1) of std_logic_vector(NEURONS_PER_CLUSTER - 1 downto 0);
    signal negative_frame : activation_t := (others => (others => '0'));
    signal positive_frame : activation_t := (others => (others => '0'));
    attribute ram_style of negative_frame : signal is "block";
    attribute ram_style of positive_frame : signal is "block";
    signal frame_row : std_logic_vector(NEURONS_PER_CLUSTER - 1 downto 0);
    signal spike_out : std_logic_vector(NEURONS_PER_CLUSTER - 1 downto 0);

    type state_t is (INTEGRATE, DECAY, FLUSH);
    signal state : state_t := INTEGRATE;
    signal prev_state : state_t;

    constant FLUSH_BUFFER_POSITIONS : natural := (AXIS_TDATA_WIDTH_G/NEURONS_PER_CLUSTER);
    signal flush_out : std_logic_vector(AXIS_TDATA_WIDTH_G - 1 downto 0) := (others => '0');
    signal flush_ongoing : std_logic := '0';
    signal flush_address : integer range 0 to (SNN_FRAME_HEIGHT * SNN_FRAME_WIDTH/NEURONS_PER_CLUSTER) - 1;
    signal flush_buffIdx : natural range 0 to FLUSH_BUFFER_POSITIONS;
    signal flush_rowIdx : integer range 0 to SNN_FRAME_HEIGHT - 1;
    signal flush_colIdx : integer range 0 to SNN_FRAME_WIDTH/AXIS_TDATA_WIDTH_G - 1;
begin

    -- STAGE 1: Read the incoming AXI message. If valid, get the neuron address to route it to. Check which neurons in the cluster to activate.
    eventDistribution : process (aclk, aresetn)
    begin
        if rising_edge(aclk) then
            excitation_polarity <= '0';
            if s_axis_tvalid = '1' and state = INTEGRATE then
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

    -- STAGE 2: Read from memory the corresponding address containing 8 neuron states.
    readOut : process (aclk)
    begin
        if rising_edge(aclk) then
            excitation_polarity_d <= excitation_polarity;
            valid_event_d <= valid_event;
            memory_address_d <= memory_address;

            if valid_event = '1' then
                if excitation_polarity = POSITIVE_CHANNEL then
                    word_in <= filter_positive_memory(memory_address);
                    frame_row <= positive_frame(memory_address);
                else
                    word_in <= filter_negative_memory(memory_address);
                    frame_row <= negative_frame(memory_address);
                end if;
            end if;
        end if;
    end process;

    -- STAGE 3: Perform integration of the activated neurons
    eventIntegration : process (aclk)
        variable cell : unsigned(MEMBRANE_POTENTIAL_SIZE - 1 downto 0);
        variable spike : std_logic_vector(NEURONS_PER_CLUSTER - 1 downto 0);
        variable spike_accum : integer range 0 to NEURONS_PER_CLUSTER;
    begin
        if rising_edge(aclk) then
            excitation_polarity_dd <= excitation_polarity_d;
            valid_event_dd <= valid_event_d;
            memory_address_dd <= memory_address_d;

            word_out <= word_in;
            -- Write back updated cluster from PREVIOUS cycle's event
            spike_accum := 0;
            -- Default value for spike_counter_hit
            spike_counter_hit <= '0';
            if valid_event_d = '1' then
                for i in 0 to NEURONS_PER_CLUSTER - 1 loop
                    spike(i) := '0';
                    if active_pixel(i) = '1' then
                        -- extract this neuron
                        cell := word_in((i + 1) * MEMBRANE_POTENTIAL_SIZE - 1 downto i * MEMBRANE_POTENTIAL_SIZE);

                        -- If last bit is 1, fire a spike
                        if cell(MEMBRANE_POTENTIAL_SIZE - 1) = '1' then
                            spike(i) := '1';
                            spike_accum := spike_accum + 1;
                        else
                            spike(i) := '0';
                        end if;

                        -- If it is all 0, initialize it to 1. Else, shift 1 position to the left.
                        if cell = INITIAL_WORD then
                            cell := to_unsigned(1, MEMBRANE_POTENTIAL_SIZE);
                        else
                            cell := cell sll 1;
                        end if;
                        report "i=" & integer'image(i) &
                            " cell=" & integer'image(to_integer(cell)) &
                            " spike(i)=" & std_logic'image(spike(i)) &
                            " spike_counter=" & integer'image(spike_counter);
                        -- write updated cell back into word_out
                        word_out((i + 1) * MEMBRANE_POTENTIAL_SIZE - 1 downto i * MEMBRANE_POTENTIAL_SIZE) <= cell;
                    end if;
                end loop;
                spike_out <= spike or frame_row;
                -- Trigger frame flushing. Check whether there is an operation ongoing with spike_counter_hit. It should be '0' if nothing is happening.
                -- if spike_counter >= SPIKE_ACCUMULATION_LIMIT and flush_ongoing = '0' then
                if spike_counter >= 3 then
                    spike_counter_hit <= '1';
                    spike_counter <= 0;
                else
                    spike_counter <= spike_counter + spike_accum;
                end if;
            end if;
        end if;
    end process;

    -- STAGE 4: Write back to memory the updated neuron states
    writeBack : process (aclk)
    begin
        if rising_edge(aclk) then
            if valid_event_dd = '1' then
                if excitation_polarity_dd = POSITIVE_CHANNEL then
                    filter_positive_memory(memory_address_dd) <= word_out;
                    positive_frame(memory_address_dd) <= spike_out;
                else
                    filter_negative_memory(memory_address_dd) <= word_out;
                    negative_frame(memory_address_dd) <= spike_out;
                end if;
            end if;
        end if;
    end process;

    -- Trigger decay execution
    decayTrigger : process (aclk)
    begin
        if rising_edge(aclk) then
            if decay_counter = DECAY_COUNTER_LIMIT then
                decay_counter <= 0;
                decay_counter_hit <= '1';
            else
                decay_counter <= decay_counter + 1;
                decay_counter_hit <= '0';
            end if;
        end if;
    end process;

    FSM : process (aclk)
    begin
        if rising_edge(aclk) then
            prev_state <= state;
            if decay_counter_hit = '1' then
                state <= DECAY;
            elsif spike_counter_hit = '1' then
                state <= FLUSH;
            else
                state <= state;
            end if;
        end if;
    end process;

    axiStream : process (aclk)
        variable address : integer range 0 to (SNN_FRAME_HEIGHT * SNN_FRAME_WIDTH/NEURONS_PER_CLUSTER) - 1;

    begin
        if rising_edge(aclk) then
            case state is
                when INTEGRATE =>
                    s_axis_tready <= '1';
                    m_axis_tvalid <= '0';
                when DECAY =>
                    s_axis_tready <= '0';
                    m_axis_tvalid <= '0';
                when FLUSH =>
                    -- FLUSH should disappear, I'm creating it for now. To be removed in the future
                    s_axis_tready <= '0';
                    m_axis_tvalid <= '0';
                    m_axis_tdata <= (others => '0');
                    m_axis_tkeep <= (others => '0');
                    m_axis_tuser <= (others => '1');
                    m_axis_tlast <= '0';

                    -- First execution
                    if prev_state /= FLUSH then
                        address := 0;
                        flush_rowIdx <= 0;
                        flush_colIdx <= 0;
                        flush_buffIdx <= FLUSH_BUFFER_POSITIONS - 1;

                        flush_ongoing <= '1';
                    end if;

                    if flush_ongoing = '1' then
                        -- Update indexes for next iteration
                        address := address + 1;
                        if flush_buffIdx = 0 then
                            -- End of word
                            flush_colIdx <= flush_colIdx + 1;
                            flush_buffIdx <= FLUSH_BUFFER_POSITIONS - 1;
                            m_axis_tdata <= flush_out;
                            m_axis_tvalid <= '1';
                            m_axis_tkeep <= (others => '1');
                            if flush_colIdx = SNN_FRAME_WIDTH/AXIS_TDATA_WIDTH_G - 1 then
                                -- End of row
                                flush_rowIdx <= flush_rowIdx + 1;
                                flush_colIdx <= 0;

                                if flush_rowIdx = SNN_FRAME_HEIGHT - 1 then
                                    -- End of frame
                                    --raise tlast
                                    m_axis_tlast <= '1';
                                    flush_ongoing <= '0';
                                    address := address - 1;
                                end if;
                            end if;
                        else
                            --Normal iteration
                            flush_buffIdx <= flush_buffIdx - 1;
                        end if;

                    end if;
                    -- flush_buffIdx has to decrement following this logic to keep the endianness
                    flush_out((flush_buffIdx + 1) * NEURONS_PER_CLUSTER - 1 downto flush_buffIdx * NEURONS_PER_CLUSTER) <= positive_frame(address);
                    flush_address <= address;
            end case;
        end if;
    end process;

end rtl;