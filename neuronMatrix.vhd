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
    -- signal route_x : unsigned(3 downto 0);
    -- Y axis is 0 to 127
    -- signal route_y : unsigned(6 downto 0);

    signal spike_counter : natural range 0 to SPIKE_ACCUMULATION_LIMIT;
    signal spike_counter_hit : std_logic := '0';

    -- Per message, 8 Processing Elements are needed
    signal active_pixel : std_logic_vector(7 downto 0);
    signal active_pixel_d : std_logic_vector(7 downto 0);

    constant INITIAL_WORD : unsigned(MEMBRANE_POTENTIAL_SIZE - 1 downto 0) := (others => '0');

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

    -- Signals for neuron state reading/writing
    signal word_in : std_logic_vector(MEMBRANE_POTENTIAL_SIZE * NEURONS_PER_CLUSTER - 1 downto 0);
    signal word_out : std_logic_vector(MEMBRANE_POTENTIAL_SIZE * NEURONS_PER_CLUSTER - 1 downto 0);

    -- Signals for spike activation tracking
    signal frame_row : std_logic_vector(NEURONS_PER_CLUSTER - 1 downto 0);
    signal spike_out : std_logic_vector(NEURONS_PER_CLUSTER - 1 downto 0);

    -- Signals for FSM
    type state_t is (INTEGRATE, DECAY, FLUSH, RESET);
    signal state : state_t := INTEGRATE;
    signal prev_state : state_t;

    -- Signals for flush
    constant FLUSH_BUFFER_POSITIONS : natural := (AXIS_TDATA_WIDTH_G/NEURONS_PER_CLUSTER);
    signal flush_out : std_logic_vector(AXIS_TDATA_WIDTH_G - 1 downto 0) := (others => '0');
    signal flush_ongoing : std_logic := '0';
    signal flush_address : integer range 0 to (SNN_FRAME_HEIGHT * SNN_FRAME_WIDTH/NEURONS_PER_CLUSTER) - 1;
    signal flush_buffIdx : natural range 0 to FLUSH_BUFFER_POSITIONS;
    signal flush_rowIdx : integer range 0 to SNN_FRAME_HEIGHT - 1;
    signal flush_colIdx : integer range 0 to SNN_FRAME_WIDTH/AXIS_TDATA_WIDTH_G - 1;
    signal flush_chanIdx : std_logic;

    -- Signals for reset
    signal reset_ongoing : std_logic := '0';
    signal reset_address : integer range 0 to (SNN_FRAME_HEIGHT * SNN_FRAME_WIDTH/NEURONS_PER_CLUSTER) - 1 := 0;
    signal reset_chanIdx : std_logic;
    -- Signals for decay
    signal decay_ongoing : std_logic := '0';
    signal decay_address : integer range 0 to (SNN_FRAME_HEIGHT * SNN_FRAME_WIDTH/NEURONS_PER_CLUSTER) - 1 := 0;
    signal decay_chanIdx : std_logic;
    -- Registered AXI output (one-cycle pipeline for flush)
    signal axi_last_reg : std_logic := '0';
    signal axi_valid_reg : std_logic := '0';

    -- Positive activation frame signals
    signal positive_act_ena : std_logic := '0';
    signal positive_act_wea : std_logic_vector(0 downto 0) := (others => '1');
    signal positive_act_addra : std_logic_vector(10 downto 0) := (others => '0');
    signal positive_act_dina : std_logic_vector(7 downto 0) := (others => '0');
    signal positive_act_addrb : std_logic_vector(10 downto 0) := (others => '0');
    signal positive_act_doutb : std_logic_vector(7 downto 0) := (others => '0');
    signal positive_act_enb : std_logic := '0';
    signal positive_act_web : std_logic_vector(0 downto 0) := (others => '0');
    signal positive_act_dinb : std_logic_vector(7 downto 0) := (others => '0');
    -- Negative activation frame signals
    signal negative_act_ena : std_logic := '0';
    signal negative_act_wea : std_logic_vector(0 downto 0) := (others => '1');
    signal negative_act_addra : std_logic_vector(10 downto 0) := (others => '0');
    signal negative_act_dina : std_logic_vector(7 downto 0) := (others => '0');
    signal negative_act_addrb : std_logic_vector(10 downto 0) := (others => '0');
    signal negative_act_doutb : std_logic_vector(7 downto 0) := (others => '0');
    signal negative_act_enb : std_logic := '0';
    signal negative_act_web : std_logic_vector(0 downto 0) := (others => '0');
    signal negative_act_dinb : std_logic_vector(7 downto 0) := (others => '0');
    -- Negative neuron state signals
    signal negative_state_ena : std_logic := '0';
    signal negative_state_wea : std_logic_vector(0 downto 0) := (others => '1');
    signal negative_state_addra : std_logic_vector(10 downto 0) := (others => '0');
    signal negative_state_dina : std_logic_vector(63 downto 0) := (others => '0');
    signal negative_state_addrb : std_logic_vector(10 downto 0) := (others => '0');
    signal negative_state_doutb : std_logic_vector(63 downto 0) := (others => '0');
    signal negative_state_enb : std_logic := '0';
    signal negative_state_web : std_logic_vector(0 downto 0) := (others => '0');
    signal negative_state_dinb : std_logic_vector(63 downto 0) := (others => '0');
    -- Negative neuron state signals
    signal positive_state_ena : std_logic := '0';
    signal positive_state_wea : std_logic_vector(0 downto 0) := (others => '1');
    signal positive_state_addra : std_logic_vector(10 downto 0) := (others => '0');
    signal positive_state_dina : std_logic_vector(63 downto 0) := (others => '0');
    signal positive_state_addrb : std_logic_vector(10 downto 0) := (others => '0');
    signal positive_state_doutb : std_logic_vector(63 downto 0) := (others => '0');
    signal positive_state_enb : std_logic := '0';
    signal positive_state_web : std_logic_vector(0 downto 0) := (others => '0');
    signal positive_state_dinb : std_logic_vector(63 downto 0) := (others => '0');

    component blk_mem_activation
        port (
            clka : in std_logic;
            ena : in std_logic;
            wea : in std_logic_vector(0 downto 0);
            addra : in std_logic_vector(10 downto 0);
            dina : in std_logic_vector(7 downto 0);
            clkb : in std_logic;
            enb : in std_logic;
            addrb : in std_logic_vector(10 downto 0);
            doutb : out std_logic_vector(7 downto 0)
        );
    end component;

    component blk_mem_state_filter
        port (
            clka : in std_logic;
            ena : in std_logic;
            wea : in std_logic_vector(0 downto 0);
            addra : in std_logic_vector(10 downto 0);
            dina : in std_logic_vector(63 downto 0);
            clkb : in std_logic;
            enb : in std_logic;
            addrb : in std_logic_vector(10 downto 0);
            doutb : out std_logic_vector(63 downto 0)
        );
    end component;

begin

    positive_frame : blk_mem_activation
    port map(
        clka => aclk,
        ena => positive_act_ena,
        wea => positive_act_wea,
        addra => positive_act_addra,
        dina => positive_act_dina,
        clkb => aclk,
        enb => positive_act_enb,
        -- web => positive_act_web,
        -- dinb => positive_act_dinb,
        addrb => positive_act_addrb,
        doutb => positive_act_doutb
    );

    negative_frame : blk_mem_activation
    port map(
        clka => aclk,
        ena => negative_act_ena,
        wea => negative_act_wea,
        addra => negative_act_addra,
        dina => negative_act_dina,
        clkb => aclk,
        enb => negative_act_enb,
        -- web => negative_act_web,
        -- dinb => negative_act_dinb,
        addrb => negative_act_addrb,
        doutb => negative_act_doutb
    );

    negative_state : blk_mem_state_filter
    port map(
        clka => aclk,
        ena => negative_state_ena,
        wea => negative_state_wea,
        addra => negative_state_addra,
        dina => negative_state_dina,
        clkb => aclk,
        enb => negative_state_enb,
        -- web => negative_state_web,
        -- dinb => negative_state_dinb,
        addrb => negative_state_addrb,
        doutb => negative_state_doutb
    );

    positive_state : blk_mem_state_filter
    port map(
        clka => aclk,
        ena => positive_state_ena,
        wea => positive_state_wea,
        addra => positive_state_addra,
        dina => positive_state_dina,
        clkb => aclk,
        enb => positive_state_enb,
        -- web => positive_state_web,
        -- dinb => positive_state_dinb,
        addrb => positive_state_addrb,
        doutb => positive_state_doutb
    );

    pipeline : process (aclk, aresetn)
        variable cell : unsigned(MEMBRANE_POTENTIAL_SIZE - 1 downto 0);
        variable spike : std_logic_vector(NEURONS_PER_CLUSTER - 1 downto 0);
        variable spike_accum : integer range 0 to NEURONS_PER_CLUSTER;
        variable readOut_memory_address : integer range 0 to (SNN_FRAME_HEIGHT * SNN_FRAME_WIDTH/NEURONS_PER_CLUSTER) - 1 := 0;
    begin
        -- STAGE 1: Read the incoming AXI message. If valid, get the neuron address to route it to. Check which neurons in the cluster to activate.
        if rising_edge(aclk) then
            excitation_polarity <= '0';
            case state is
                when INTEGRATE =>
                    if s_axis_tvalid = '1' then
                        -- Divide by 4 or 2 shifts right, same as leaving out the 2LSb
                        -- Target dimension is 128, only 7 bits needed. Therefore, get the slice [8:2]
                        -- On the X axis, we divide by 7 (128 in total), as neurons are clustered by EVT2.1
                        --      route_x <= unsigned(s_axis_tdata(51 downto 48));
                        --      route_y <= unsigned(s_axis_tdata(40 downto 34));
                        readOut_memory_address := to_integer(unsigned(s_axis_tdata(40 downto 34))) * CLUSTERS_PER_ROW + to_integer(unsigned(s_axis_tdata(51 downto 48)));
                        memory_address <= readOut_memory_address;

                        valid_event <= '1';

                        -- Read the value from memory
                        if (s_axis_tdata(63 downto 60) = POS_EVT) then
                            excitation_polarity <= POSITIVE_CHANNEL;
                            positive_state_addrb <= std_logic_vector(to_unsigned(readOut_memory_address, positive_state_addrb'length));
                            positive_act_addrb <= std_logic_vector(to_unsigned(readOut_memory_address, positive_act_addrb'length));
                            positive_state_enb <= '1';
                            positive_act_enb <= '1';
                        else
                            excitation_polarity <= NEGATIVE_CHANNEL;
                            negative_state_addrb <= std_logic_vector(to_unsigned(readOut_memory_address, negative_state_addrb'length));
                            negative_act_addrb <= std_logic_vector(to_unsigned(readOut_memory_address, negative_act_addrb'length));
                            negative_state_enb <= '1';
                            negative_act_enb <= '1';
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
                        negative_state_enb <= '0';
                        positive_state_enb <= '0';
                        positive_act_enb <= '0';
                        negative_act_enb <= '0';
                    end if;

                when FLUSH =>
                    if flush_ongoing = '1' then
                    end if;

                when others =>
                    -- Nothing
            end case;
        end if;

        -- STAGE 2: Read from memory the corresponding address containing 8 neuron states.
        if rising_edge(aclk) then
            if state = INTEGRATE then
                excitation_polarity_d <= excitation_polarity;
                valid_event_d <= valid_event;
                memory_address_d <= memory_address;
                active_pixel_d <= active_pixel;

                if valid_event = '1' then
                    if excitation_polarity = POSITIVE_CHANNEL then
                        word_in <= positive_state_doutb;
                        frame_row <= positive_act_doutb;
                    else
                        word_in <= negative_state_doutb;
                        frame_row <= negative_act_doutb;
                    end if;
                end if;
            end if;
        end if;

        -- STAGE 3: Perform integration of the activated neurons

        if rising_edge(aclk) then
            if state = INTEGRATE then
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
                        if active_pixel_d(i) = '1' then
                            -- extract this neuron
                            cell := unsigned(word_in((i + 1) * MEMBRANE_POTENTIAL_SIZE - 1 downto i * MEMBRANE_POTENTIAL_SIZE));

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
                            -- report "i=" & integer'image(i) &
                            --     " cell=" & integer'image(to_integer(cell)) &
                            --     " spike(i)=" & std_logic'image(spike(i)) &
                            --     " spike_counter=" & integer'image(spike_counter);
                            -- write updated cell back into word_out
                            word_out((i + 1) * MEMBRANE_POTENTIAL_SIZE - 1 downto i * MEMBRANE_POTENTIAL_SIZE) <= std_logic_vector(cell);
                        end if;
                    end loop;
                    spike_out <= spike or frame_row;
                    -- Trigger frame flushing. Check whether there is an operation ongoing with spike_counter_hit. It should be '0' if nothing is happening.
                    -- if spike_counter >= SPIKE_ACCUMULATION_LIMIT and flush_ongoing = '0' then
                    if spike_counter >= 5 then
                        spike_counter_hit <= '1';
                        spike_counter <= 0;
                    else
                        spike_counter <= spike_counter + spike_accum;
                    end if;
                end if;
            end if;
        end if;

        -- STAGE 4: Write back to memory the updated neuron states
        if rising_edge(aclk) then
            positive_act_ena <= '0';
            case state is
                when INTEGRATE =>
                    negative_act_ena <= '0';
                    positive_act_ena <= '0';
                    positive_state_ena <= '0';
                    negative_state_ena <= '0';
                    if valid_event_dd = '1' then

                        if excitation_polarity_dd = POSITIVE_CHANNEL then
                            positive_state_addra <= std_logic_vector(to_unsigned(memory_address_dd, positive_state_addra'length));
                            positive_state_dina <= word_out;
                            positive_state_ena <= '1';

                            positive_act_addra <= std_logic_vector(to_unsigned(memory_address_dd, positive_act_addra'length));
                            positive_act_dina <= spike_out;
                            positive_act_ena <= '1';
                        else
                            negative_state_addra <= std_logic_vector(to_unsigned(memory_address_dd, negative_state_addra'length));
                            negative_state_dina <= word_out;
                            negative_state_ena <= '1';

                            negative_act_addra <= std_logic_vector(to_unsigned(memory_address_dd, negative_act_addra'length));
                            negative_act_dina <= spike_out;
                            negative_act_ena <= '1';
                        end if;
                    end if;
                when RESET =>
                    negative_act_ena <= '0';
                    positive_act_ena <= '0';
                    positive_state_ena <= '0';
                    negative_state_ena <= '0';

                    if prev_state = FLUSH then
                        reset_ongoing <= '1';
                        reset_address <= 0;
                        reset_chanIdx <= NEGATIVE_CHANNEL;
                    end if;

                    if reset_ongoing = '1' then
                        reset_address <= reset_address + 1;
                        if reset_address = (SNN_FRAME_HEIGHT * SNN_FRAME_WIDTH/NEURONS_PER_CLUSTER) - 1 then
                            -- End of memory block
                            reset_address <= 0;
                            if reset_chanIdx = NEGATIVE_CHANNEL then
                                -- Change to second channel
                                reset_chanIdx <= POSITIVE_CHANNEL;
                            else
                                -- Finished resetting
                                reset_ongoing <= '0';
                            end if;
                        end if;

                        if reset_chanIdx = NEGATIVE_CHANNEL then
                            negative_state_addra <= std_logic_vector(to_unsigned(reset_address, negative_state_addra'length));
                            negative_state_dina <= (others => '0');
                            negative_state_ena <= '1';

                            negative_act_addra <= std_logic_vector(to_unsigned(reset_address, negative_act_addra'length));
                            negative_act_dina <= (others => '0');
                            negative_act_ena <= '1';
                        else
                            positive_state_addra <= std_logic_vector(to_unsigned(reset_address, positive_state_addra'length));
                            positive_state_dina <= (others => '0');
                            positive_state_ena <= '1';

                            positive_act_addra <= std_logic_vector(to_unsigned(reset_address, positive_act_addra'length));
                            positive_act_dina <= (others => '0');
                            positive_act_ena <= '1';
                        end if;
                    end if;
                when DECAY =>
                    if prev_state = INTEGRATE then
                        decay_ongoing <= '1';
                        decay_address <= 0;
                        decay_chanIdx <= NEGATIVE_CHANNEL;
                    end if;

                    if decay_ongoing = '1' then
                        -- Nothing for now
                        decay_ongoing <= '0';
                    end if;
                when FLUSH =>
                    -- Make sure nothing is written into memory in this stage.
                    negative_act_ena <= '0';
                    positive_act_ena <= '0';
                    positive_state_ena <= '0';
                    negative_state_ena <= '0';
            end case;
        end if;

        -- AXI Stream Controller part
        if rising_edge(aclk) then
            -- AXI Valid and AXI last are driven with 1 clock difference
            axi_valid_reg <= '0';
            axi_last_reg <= '0';
            m_axis_tlast <= axi_last_reg;
            m_axis_tvalid <= axi_valid_reg;
            -- If axi_valid = 1, the data is already is flush_out
            if axi_valid_reg = '1' then
                m_axis_tdata <= flush_out;
            end if;

            -- The logic for AXI ready must be yet implemented
            -- if m_axis_tready = '1' then ...

            -- The rest of the AXI signals are not used
            m_axis_tkeep <= (others => '1');
            m_axis_tuser <= (others => '1');

            case state is
                    -- INTEGRATE: normal operation, no flush output
                when INTEGRATE =>
                    s_axis_tready <= '1';

                    -- DECAY: no AXI output, just stall input
                when DECAY =>
                    s_axis_tready <= '0';
                    -- DECAY: no AXI output, just stall input
                when RESET =>
                    s_axis_tready <= '0';

                    -- FLUSH: walk through frame and emit AXI words
                when FLUSH =>
                    s_axis_tready <= '0';

                    -- First FLUSH cycle: initialise indices and start negative channel
                    if prev_state /= FLUSH then
                        flush_address <= 0;
                        positive_act_addrb <= (others => '0');
                        negative_act_addrb <= (others => '0');
                        flush_rowIdx <= 0;
                        flush_colIdx <= 0;
                        flush_buffIdx <= FLUSH_BUFFER_POSITIONS - 1;
                        flush_chanIdx <= NEGATIVE_CHANNEL;
                        flush_ongoing <= '1';
                        negative_act_enb <= '1';

                        -- Ongoing FLUSH
                    elsif flush_ongoing = '1' then
                        -- 1) calculate new address
                        if flush_chanIdx = POSITIVE_CHANNEL then
                            positive_act_addrb <= std_logic_vector(unsigned(positive_act_addrb) + 1);
                        else
                            negative_act_addrb <= std_logic_vector(unsigned(negative_act_addrb) + 1);
                        end if;

                        -- 1b) check whether something special happens
                        if flush_buffIdx = 0 then
                            -- Final part of the word
                            flush_buffIdx <= FLUSH_BUFFER_POSITIONS - 1;
                            axi_valid_reg <= '1';

                            if flush_colIdx = SNN_FRAME_WIDTH/AXIS_TDATA_WIDTH_G - 1 then
                                -- Last column of the row
                                flush_colIdx <= 0;
                                if flush_rowIdx = SNN_FRAME_WIDTH - 1 then
                                    flush_rowIdx <= 0;
                                    -- Last row of the frame
                                    if flush_chanIdx = POSITIVE_CHANNEL then
                                        -- Last frame of the flush 
                                        axi_last_reg <= '1';
                                        flush_ongoing <= '0';
                                        positive_act_enb <= '0';
                                    else
                                        -- If not last frame of the flush, change channel
                                        flush_chanIdx <= POSITIVE_CHANNEL;
                                        positive_act_enb <= '1';
                                        negative_act_enb <= '0';
                                    end if;
                                else
                                    -- If not last row of frame, increase one position
                                    flush_rowIdx <= flush_rowIdx + 1;
                                end if;
                            else
                                -- If not last column of row, increase one position
                                flush_colIdx <= flush_colIdx + 1;
                            end if;
                        else
                            -- If not last part of word, decrease one position in buffer
                            flush_buffIdx <= flush_buffIdx - 1;
                        end if;

                        -- 2) read value
                        if flush_chanIdx = POSITIVE_CHANNEL then
                            flush_out((flush_buffIdx + 1) * NEURONS_PER_CLUSTER - 1 downto flush_buffIdx * NEURONS_PER_CLUSTER) <= positive_act_doutb;
                        else
                            flush_out((flush_buffIdx + 1) * NEURONS_PER_CLUSTER - 1 downto flush_buffIdx * NEURONS_PER_CLUSTER) <= negative_act_doutb;
                        end if;
                    end if; -- flush_ongoing = '1'
            end case;
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

    -- TODO: Rework this whole thing
    FSM : process (aclk, aresetn)
    begin
        if rising_edge(aclk) then
            prev_state <= state;
            state <= state;
            case state is
                when INTEGRATE =>
                    if aresetn = '0' then
                        -- state <= RESET;
                    elsif decay_counter_hit = '1' then
                        state <= DECAY;
                    elsif spike_counter_hit = '1' then
                        state <= FLUSH;
                    end if;
                when FLUSH =>
                    if aresetn = '0' then
                        state <= RESET;
                    elsif flush_ongoing = '0' and prev_state = FLUSH then
                        state <= RESET;
                    end if;
                when DECAY =>
                    if decay_ongoing = '0' and prev_state = DECAY then
                        state <= INTEGRATE;
                    else
                        state <= DECAY;
                    end if;
                when RESET =>
                    if reset_ongoing = '0' and prev_state = RESET then
                        state <= INTEGRATE;
                    else
                        state <= RESET;
                    end if;
            end case;
        end if;
    end process;
end rtl;