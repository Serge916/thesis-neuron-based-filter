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

    -- Signals for neuron state reading/writing
    signal word_in : unsigned(MEMBRANE_POTENTIAL_SIZE * NEURONS_PER_CLUSTER - 1 downto 0);
    signal word_out : unsigned(MEMBRANE_POTENTIAL_SIZE * NEURONS_PER_CLUSTER - 1 downto 0);

    -- Signals for spike activation tracking
    type activation_t is array (0 to (SNN_FRAME_HEIGHT * SNN_FRAME_WIDTH/NEURONS_PER_CLUSTER) - 1) of std_logic_vector(NEURONS_PER_CLUSTER - 1 downto 0);
    signal negative_frame : activation_t := (others => (others => '0'));
    attribute ram_style of negative_frame : signal is "block";
    signal frame_row : std_logic_vector(NEURONS_PER_CLUSTER - 1 downto 0);
    signal spike_out : std_logic_vector(NEURONS_PER_CLUSTER - 1 downto 0);

    -- Signals for FSM
    type state_t is (INTEGRATE, DECAY, FLUSH, RESET);
    signal state : state_t := INTEGRATE;
    signal prev_state : state_t;

    -- Signals for flush
    constant FLUSH_BUFFER_POSITIONS : natural := (AXIS_TDATA_WIDTH_G/NEURONS_PER_CLUSTER);
    signal flush_out : std_logic_vector(AXIS_TDATA_WIDTH_G - 1 downto 0) := (others => '0');
    signal flush_fetch : std_logic_vector(NEURONS_PER_CLUSTER - 1 downto 0) := (others => '0');
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
    signal axi_data_reg : std_logic_vector(AXIS_TDATA_WIDTH_G - 1 downto 0) := (others => '0');
    signal axi_keep_reg : std_logic_vector((AXIS_TDATA_WIDTH_G/8) - 1 downto 0) := (others => '0');
    signal axi_user_reg : std_logic_vector(AXIS_TUSER_WIDTH_G - 1 downto 0) := (others => '0');
    signal axi_last_reg : std_logic := '0';
    signal axi_valid_reg : std_logic := '0';

    -- Positive activation frame signals
    signal positive_act_ena : std_logic := '0';
    signal positive_act_wea : std_logic_vector(0 downto 0) := (others => '1');
    signal positive_act_addra : std_logic_vector(10 downto 0) := (others => '0');
    signal positive_act_dina : std_logic_vector(7 downto 0) := (others => '0');
    signal positive_act_addrb : std_logic_vector(10 downto 0) := (others => '0');
    signal positive_act_doutb : std_logic_vector(7 downto 0) := (others => '0');
    signal positive_act_enb : std_logic := '1';
    signal positive_act_web : std_logic_vector(0 downto 0) := (others => '0');
    signal positive_act_dinb : std_logic_vector(7 downto 0) := (others => '0');

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

    pipeline : process (aclk, aresetn)
        variable cell : unsigned(MEMBRANE_POTENTIAL_SIZE - 1 downto 0);
        variable spike : std_logic_vector(NEURONS_PER_CLUSTER - 1 downto 0);
        variable spike_accum : integer range 0 to NEURONS_PER_CLUSTER;
        variable readOut_memory_address : integer range 0 to (SNN_FRAME_HEIGHT * SNN_FRAME_WIDTH/NEURONS_PER_CLUSTER) - 1 := 0;
        variable flush_word_v : std_logic_vector(AXIS_TDATA_WIDTH_G - 1 downto 0);
        variable is_last_word : boolean;
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
                        positive_act_addrb <= std_logic_vector(to_unsigned(readOut_memory_address, positive_act_addrb'length));
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

                if valid_event = '1' then
                    if excitation_polarity = POSITIVE_CHANNEL then
                        word_in <= filter_positive_memory(memory_address);
                        frame_row <= positive_act_doutb;
                    else
                        word_in <= filter_negative_memory(memory_address);
                        frame_row <= negative_frame(memory_address);
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
                            -- report "i=" & integer'image(i) &
                            --     " cell=" & integer'image(to_integer(cell)) &
                            --     " spike(i)=" & std_logic'image(spike(i)) &
                            --     " spike_counter=" & integer'image(spike_counter);
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
        end if;

        -- STAGE 4: Write back to memory the updated neuron states
        if rising_edge(aclk) then
            positive_act_ena <= '0';
            case state is
                when INTEGRATE =>
                    if valid_event_dd = '1' then
                        if excitation_polarity_dd = POSITIVE_CHANNEL then
                            filter_positive_memory(memory_address_dd) <= word_out;
                            positive_act_addra <= std_logic_vector(to_unsigned(memory_address_dd, positive_act_addra'length));
                            positive_act_dina <= spike_out;
                            positive_act_ena <= '1';
                        else
                            filter_negative_memory(memory_address_dd) <= word_out;
                            negative_frame(memory_address_dd) <= spike_out;
                        end if;
                    end if;
                when RESET =>
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
                            filter_negative_memory(reset_address) <= (others => '0');
                            negative_frame(reset_address) <= (others => '0');
                        else
                            filter_positive_memory(reset_address) <= (others => '0');
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
                    --Nothing. Here to make the compiler happy.
            end case;
        end if;

        -- AXI Stream Controller part

        -- if rising_edge(aclk) then
        --     -- Default: drive AXI outputs from registered values
        --     -- m_axis_tdata <= axi_data_reg;
        --     -- m_axis_tkeep <= axi_keep_reg;
        --     -- m_axis_tuser <= axi_user_reg;
        --     -- m_axis_tlast <= axi_last_reg;
        --     -- m_axis_tvalid <= axi_valid_reg;

        --     -- By default, no new word this cycle
        --     -- axi_valid_reg <= '0';
        --     -- axi_last_reg <= '0';
        --     m_axis_tvalid <= '0';
        --     m_axis_tlast <= '0';

        --     -- Start with the previous flush_out content
        --     flush_word_v := flush_out;
        --     is_last_word := false;

        --     case state is
        --             -- INTEGRATE: normal operation, no flush output
        --         when INTEGRATE =>
        --             s_axis_tready <= '1';

        --             -- DECAY: no AXI output, just stall input
        --         when DECAY =>
        --             s_axis_tready <= '0';
        --             -- DECAY: no AXI output, just stall input
        --         when RESET =>
        --             s_axis_tready <= '0';

        --             -- FLUSH: walk through frame and emit AXI words
        --         when FLUSH =>
        --             s_axis_tready <= '0';

        --             -- First FLUSH cycle: initialise indices and start negative channel
        --             if prev_state /= FLUSH then
        --                 flush_address <= 0;
        --                 flush_rowIdx <= 0;
        --                 flush_colIdx <= 0;
        --                 flush_buffIdx <= FLUSH_BUFFER_POSITIONS - 1;
        --                 flush_chanIdx <= NEGATIVE_CHANNEL;
        --                 flush_ongoing <= '1';

        --                 -- First read (will be used next cycle)
        --                 flush_fetch <= negative_frame(0);

        --                 -- Ongoing FLUSH
        --             elsif flush_ongoing = '1' then
        --                 -- 1) Assemble current word slice into variable flush_word_v
        --                 --    flush_fetch is the data read in the previous cycle.
        --                 flush_word_v((flush_buffIdx + 1) * NEURONS_PER_CLUSTER - 1 downto flush_buffIdx * NEURONS_PER_CLUSTER) := flush_fetch;

        --                 -- 2) Check if this slice completes the AXI word
        --                 if flush_buffIdx = 0 then
        --                     -- Word fully assembled in flush_word_v:
        --                     --   - register it into axi_*_reg
        --                     --   - it will appear on m_axis_* in the NEXT cycle
        --                     -- axi_data_reg <= flush_word_v;
        --                     -- axi_keep_reg <= (others => '1');
        --                     -- axi_user_reg <= (others => '1');
        --                     -- axi_valid_reg <= '1';

        --                     m_axis_tdata <= flush_out;
        --                     m_axis_tkeep <= (others => '1');
        --                     m_axis_tuser <= (others => '1');
        --                     m_axis_tvalid <= '1';

        --                     -- Is this the last word of the last row of the positive channel?
        --                     if (flush_rowIdx = SNN_FRAME_HEIGHT - 1) and
        --                         (flush_colIdx = SNN_FRAME_WIDTH/AXIS_TDATA_WIDTH_G - 1) and
        --                         (flush_chanIdx = POSITIVE_CHANNEL) then
        --                         axi_last_reg <= '1';
        --                         flush_ongoing <= '0';
        --                     end if;

        --                     -- 3) Update column / row / channel indices for NEXT word
        --                     if flush_colIdx = SNN_FRAME_WIDTH/AXIS_TDATA_WIDTH_G - 1 then
        --                         -- End of row
        --                         flush_colIdx <= 0;
        --                         if flush_rowIdx = SNN_FRAME_HEIGHT - 1 then
        --                             -- End of frame for this channel
        --                             flush_rowIdx <= 0;
        --                             if flush_chanIdx = NEGATIVE_CHANNEL then
        --                                 flush_chanIdx <= POSITIVE_CHANNEL;
        --                             end if;
        --                         else
        --                             flush_rowIdx <= flush_rowIdx + 1;
        --                         end if;
        --                     else
        --                         flush_colIdx <= flush_colIdx + 1;
        --                     end if;

        --                     -- Reset buffer index for next word
        --                     flush_buffIdx <= FLUSH_BUFFER_POSITIONS - 1;

        --                 else
        --                     -- Still filling the current word: just decrement buffer index.
        --                     flush_buffIdx <= flush_buffIdx - 1;
        --                 end if;

        --                 -- 4) Advance memory address and schedule next fetch.
        --                 --    Address wraps at end of frame memory.
        --                 if flush_address = (SNN_FRAME_HEIGHT * SNN_FRAME_WIDTH/NEURONS_PER_CLUSTER) - 1 then
        --                     flush_address <= 0;
        --                 else
        --                     flush_address <= flush_address + 1;
        --                 end if;

        --                 if flush_chanIdx = NEGATIVE_CHANNEL then
        --                     flush_fetch <= negative_frame(flush_address);
        --                 else
        --                     positive_act_addrb <= std_logic_vector(to_unsigned(flush_address, positive_act_addrb'length));
        --                     flush_fetch <= positive_act_doutb;
        --                 end if;

        --             end if; -- flush_ongoing = '1'
        --     end case;

        --     -- Finally, commit the assembled flush word to the signal.
        --     flush_out <= flush_word_v;
        -- end if;
        if rising_edge(aclk) then
            -- Default: drive AXI outputs from registered values
            -- axi_data_reg <= (others => '0');
            axi_valid_reg <= '0';
            axi_last_reg <= '0';

            m_axis_tlast <= axi_last_reg;
            m_axis_tvalid <= axi_valid_reg;
            -- If axi_valid = 1, the data is already is flush_out
            if axi_valid_reg = '1' then
                m_axis_tdata <= flush_out;
            end if;

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
                        is_last_word := false;
                        flush_address <= 0;
                        positive_act_addrb <= (others => '0');
                        flush_rowIdx <= 0;
                        flush_colIdx <= 0;
                        flush_buffIdx <= FLUSH_BUFFER_POSITIONS - 1;
                        flush_chanIdx <= NEGATIVE_CHANNEL;
                        flush_ongoing <= '1';

                        -- First read (will be used next cycle)
                        flush_fetch <= negative_frame(0);

                        -- Ongoing FLUSH
                    elsif flush_ongoing = '1' then
                        -- 1) calculate address
                        if flush_chanIdx = POSITIVE_CHANNEL then
                            positive_act_addrb <= std_logic_vector(unsigned(positive_act_addrb) + 1);
                        else
                            flush_address <= flush_address + 1;
                            -- positive_act_addrb <= std_logic_vector(to_unsigned(flush_address, positive_act_addrb'length));
                        end if;
                        -- 1b) check whether something special happens
                        if flush_buffIdx = 0 then
                            -- Final part of the word
                            flush_buffIdx <= FLUSH_BUFFER_POSITIONS - 1;
                            axi_valid_reg <= '1';
                            axi_data_reg <= flush_out;

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
                                    else
                                        -- If not last frame of the flush, change channel
                                        positive_act_addrb <= (others => '0');
                                        flush_chanIdx <= POSITIVE_CHANNEL;
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
                            flush_out((flush_buffIdx + 1) * NEURONS_PER_CLUSTER - 1 downto flush_buffIdx * NEURONS_PER_CLUSTER) <= negative_frame(flush_address);
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