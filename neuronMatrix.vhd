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
        SPIKE_ACCUMULATION_LIMIT : positive := 10;
        DECAY_COUNTER_LIMIT : positive := 100;
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
    -- X axis is 0 to 15 clusters of 32 elements. 16*32=512
    -- signal route_x : unsigned(3 downto 0);
    -- Y axis is 0 to 127
    -- signal route_y : unsigned(6 downto 0);

    signal spike_counter : natural range 0 to SPIKE_ACCUMULATION_LIMIT;
    signal spike_counter_hit : std_logic := '0';

    constant INITIAL_WORD : unsigned(MEMBRANE_POTENTIAL_SIZE - 1 downto 0) := (others => '0');
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
    signal flush_out : std_logic_vector(AXIS_TDATA_WIDTH_G - 1 downto 0);-- := (others => '0');
    signal flush_ongoing : std_logic := '0';
    signal flush_ongoing_d : std_logic := '0';
    signal flush_address : integer range 0 to (SNN_FRAME_HEIGHT * SNN_FRAME_WIDTH/NEURONS_PER_CLUSTER) - 1;
    signal flush_buffIdx : natural range 0 to FLUSH_BUFFER_POSITIONS;
    signal flush_buffIdx_d : natural range 0 to FLUSH_BUFFER_POSITIONS;
    signal flush_rowIdx : integer range 0 to SNN_FRAME_HEIGHT - 1;
    signal flush_colIdx : integer range 0 to SNN_FRAME_WIDTH/AXIS_TDATA_WIDTH_G - 1;
    signal flush_chanIdx : std_logic;
    signal flush_chanIdx_d : std_logic;

    -- Signals for reset
    signal reset_ongoing : std_logic := '0';
    signal reset_address : integer range 0 to (SNN_FRAME_HEIGHT * SNN_FRAME_WIDTH/NEURONS_PER_CLUSTER) - 1 := 0;
    signal reset_chanIdx : std_logic;
    -- Signals for decay
    signal decay_address_read : integer range 0 to (SNN_FRAME_HEIGHT * SNN_FRAME_WIDTH/NEURONS_PER_CLUSTER) - 1 := 0;
    signal decay_address_write : integer range 0 to (SNN_FRAME_HEIGHT * SNN_FRAME_WIDTH/NEURONS_PER_CLUSTER) - 1 := 0;
    signal decay_ongoing : std_logic := '0';
    signal decay_has_data : std_logic := '0';
    signal decay_last_read_issued : std_logic := '0';
    signal decay_ongoing_d : std_logic := '0';
    signal decay_chanIdx : std_logic;
    -- Registered AXI output (one-cycle pipeline for flush)
    signal axi_last_reg : std_logic := '0';
    signal axi_last_reg_d : std_logic := '0';
    signal axi_valid_reg : std_logic := '0';
    signal axi_valid_reg_d : std_logic := '0';

    -- Processes to BRAM controller
    type process_memory_interface_t is record
        rd_en : std_logic;
        rd_addr : integer range 0 to (SNN_FRAME_HEIGHT * SNN_FRAME_WIDTH/NEURONS_PER_CLUSTER) - 1;
        wr_en : std_logic;
        wr_addr : integer range 0 to (SNN_FRAME_HEIGHT * SNN_FRAME_WIDTH/NEURONS_PER_CLUSTER) - 1;
    end record;

    signal integrate_positive_frame : process_memory_interface_t;
    signal integrate_positive_state : process_memory_interface_t;
    signal integrate_negative_frame : process_memory_interface_t;
    signal integrate_negative_state : process_memory_interface_t;

    signal flush_positive_frame : process_memory_interface_t;
    signal flush_positive_state : process_memory_interface_t;
    signal flush_negative_frame : process_memory_interface_t;
    signal flush_negative_state : process_memory_interface_t;

    signal reset_positive_frame : process_memory_interface_t;
    signal reset_positive_state : process_memory_interface_t;
    signal reset_negative_frame : process_memory_interface_t;
    signal reset_negative_state : process_memory_interface_t;

    type state_mem_interface_t is record
        ena : std_logic;
        wea : std_logic_vector(0 downto 0);
        addra : std_logic_vector(10 downto 0);
        dina : std_logic_vector(63 downto 0);
        addrb : std_logic_vector(10 downto 0);
        doutb : std_logic_vector(63 downto 0);
        enb : std_logic;
        web : std_logic_vector(0 downto 0);
        dinb : std_logic_vector(63 downto 0);
    end record;
    signal positive_state : state_mem_interface_t;
    signal negative_state : state_mem_interface_t;

    type frame_mem_interface_t is record
        ena : std_logic;
        wea : std_logic_vector(0 downto 0);
        addra : std_logic_vector(10 downto 0);
        dina : std_logic_vector(7 downto 0);
        addrb : std_logic_vector(10 downto 0);
        doutb : std_logic_vector(7 downto 0);
        enb : std_logic;
        web : std_logic_vector(0 downto 0);
        dinb : std_logic_vector(7 downto 0);
    end record;
    signal positive_frame : frame_mem_interface_t;
    signal negative_frame : frame_mem_interface_t;

    -- Pipeline variables. Shared accross stages
    type pipe_meta_t is record
        valid_event : std_logic;
        excitation_polarity : std_logic;
        memory_address : integer range 0 to (SNN_FRAME_HEIGHT * SNN_FRAME_WIDTH/NEURONS_PER_CLUSTER) - 1;
        active_pixel : std_logic_vector(NEURONS_PER_CLUSTER - 1 downto 0);
    end record;
    type pipe_meta_arr_t is array (natural range <>) of pipe_meta_t;
    constant PIPE_STAGES_C : natural := 4;
    signal pipeStage : pipe_meta_arr_t(0 to PIPE_STAGES_C);

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

    positive_frame_mem : blk_mem_activation
    port map(
        clka => aclk,
        ena => positive_frame.ena,
        wea => positive_frame.wea,
        addra => positive_frame.addra,
        dina => positive_frame.dina,
        clkb => aclk,
        enb => positive_frame.enb,
        -- web => positive_frame.web,
        -- dinb => positive_frame.dinb,
        addrb => positive_frame.addrb,
        doutb => positive_frame.doutb
    );

    negative_frame_mem : blk_mem_activation
    port map(
        clka => aclk,
        ena => negative_frame.ena,
        wea => negative_frame.wea,
        addra => negative_frame.addra,
        dina => negative_frame.dina,
        clkb => aclk,
        enb => negative_frame.enb,
        -- web => negative_frame.web,
        -- dinb => negative_frame.dinb,
        addrb => negative_frame.addrb,
        doutb => negative_frame.doutb
    );

    negative_state_mem : blk_mem_state_filter
    port map(
        clka => aclk,
        ena => negative_state.ena,
        wea => negative_state.wea,
        addra => negative_state.addra,
        dina => negative_state.dina,
        clkb => aclk,
        enb => negative_state.enb,
        -- web => negative_state.web,
        -- dinb => negative_state.dinb,
        addrb => negative_state.addrb,
        doutb => negative_state.doutb
    );

    positive_state_mem : blk_mem_state_filter
    port map(
        clka => aclk,
        ena => positive_state.ena,
        wea => positive_state.wea,
        addra => positive_state.addra,
        dina => positive_state.dina,
        clkb => aclk,
        enb => positive_state.enb,
        -- web => positive_state.web,
        -- dinb => positive_state.dinb,
        addrb => positive_state.addrb,
        doutb => positive_state.doutb
    );

    pipeline : process (aclk, aresetn)
        variable cell : unsigned(MEMBRANE_POTENTIAL_SIZE - 1 downto 0);
        variable spike : std_logic_vector(NEURONS_PER_CLUSTER - 1 downto 0);
        variable spike_accum : integer range 0 to NEURONS_PER_CLUSTER;
        variable readOut_memory_address : integer range 0 to (SNN_FRAME_HEIGHT * SNN_FRAME_WIDTH/NEURONS_PER_CLUSTER) - 1 := 0;
        variable decay_positive_word_out : std_logic_vector(MEMBRANE_POTENTIAL_SIZE * NEURONS_PER_CLUSTER - 1 downto 0);
        variable decay_negative_word_out : std_logic_vector(MEMBRANE_POTENTIAL_SIZE * NEURONS_PER_CLUSTER - 1 downto 0);
        variable decay_negative_cell : unsigned(MEMBRANE_POTENTIAL_SIZE - 1 downto 0);
        variable decay_positive_cell : unsigned(MEMBRANE_POTENTIAL_SIZE - 1 downto 0);
    begin
        if rising_edge(aclk) then

            -- Defaults: no writes
            positive_state.ena <= '0';
            negative_state.ena <= '0';
            positive_frame.ena <= '0';
            negative_frame.ena <= '0';
            -- Wea is not enabled, but it needs an input anyways
            negative_frame.wea <= (others => '0');
            positive_frame.wea <= (others => '0');
            positive_state.wea <= (others => '0');
            negative_state.wea <= (others => '0');

            -- Defaults: allow reads (or disable by default if you prefer)
            positive_state.enb <= '0';
            negative_state.enb <= '0';
            positive_frame.enb <= '0';
            negative_frame.enb <= '0';

            -- Move signals to the next stage of registers
            for k in 1 to PIPE_STAGES_C loop
                pipeStage(k) <= pipeStage(k - 1);
            end loop;

            case state is
                when INTEGRATE =>
                    -- STAGE 1: Read the incoming AXI message. If valid, get the neuron address to route it to. Check which neurons in the cluster to activate.
                    -- Defaults to read but not write. This way, output port updates as the address and not one clock after
                    pipeStage(0).valid_event <= '0';
                    negative_state.enb <= '0';
                    positive_state.enb <= '0';
                    positive_frame.enb <= '0';
                    negative_frame.enb <= '0';

                    if s_axis_tvalid = '1' then
                        -- Divide by 4 or 2 shifts right, same as leaving out the 2LSb
                        -- Target dimension is 128, only 7 bits needed. Therefore, get the slice [8:2]
                        -- On the X axis, we divide by 7 (128 in total), as neurons are clustered by EVT2.1
                        --      route_x <= unsigned(s_axis_tdata(51 downto 48));
                        --      route_y <= unsigned(s_axis_tdata(40 downto 34));
                        readOut_memory_address := to_integer(unsigned(s_axis_tdata(40 downto 34))) * CLUSTERS_PER_ROW + to_integer(unsigned(s_axis_tdata(51 downto 48)));
                        if not ((readOut_memory_address = pipeStage(0).memory_address and pipeStage(0).valid_event = '1') or (readOut_memory_address = pipeStage(1).memory_address and pipeStage(1).valid_event = '1') or (readOut_memory_address = pipeStage(2).memory_address and pipeStage(2).valid_event = '1') or (readOut_memory_address = pipeStage(3).memory_address and pipeStage(3).valid_event = '1') or (readOut_memory_address = pipeStage(4).memory_address and pipeStage(4).valid_event = '1')) then
                            -- If there are no hazards, continue
                            pipeStage(0).valid_event <= '1';
                            pipeStage(0).memory_address <= readOut_memory_address;

                            -- Read the value from memory
                            if (s_axis_tdata(63 downto 60) = POS_EVT) then
                                pipeStage(0).excitation_polarity <= POSITIVE_CHANNEL;
                                positive_state.addrb <= std_logic_vector(to_unsigned(readOut_memory_address, positive_state.addrb'length));
                                positive_frame.addrb <= std_logic_vector(to_unsigned(readOut_memory_address, positive_frame.addrb'length));
                                positive_state.enb <= '1';
                                positive_frame.enb <= '1';
                            else
                                pipeStage(0).excitation_polarity <= NEGATIVE_CHANNEL;
                                negative_state.addrb <= std_logic_vector(to_unsigned(readOut_memory_address, negative_state.addrb'length));
                                negative_frame.addrb <= std_logic_vector(to_unsigned(readOut_memory_address, negative_frame.addrb'length));
                                negative_frame.enb <= '1';
                                negative_state.enb <= '1';
                            end if;

                            pipeStage(0).active_pixel(7) <= or_reduce(s_axis_tdata(31 downto 28));
                            pipeStage(0).active_pixel(6) <= or_reduce(s_axis_tdata(27 downto 24));
                            pipeStage(0).active_pixel(5) <= or_reduce(s_axis_tdata(23 downto 20));
                            pipeStage(0).active_pixel(4) <= or_reduce(s_axis_tdata(19 downto 16));
                            pipeStage(0).active_pixel(3) <= or_reduce(s_axis_tdata(15 downto 12));
                            pipeStage(0).active_pixel(2) <= or_reduce(s_axis_tdata(11 downto 8));
                            pipeStage(0).active_pixel(1) <= or_reduce(s_axis_tdata(7 downto 4));
                            pipeStage(0).active_pixel(0) <= or_reduce(s_axis_tdata(3 downto 0));
                        end if;
                    end if;

                    -- STAGE 2: Read from memory the corresponding address containing 8 neuron states.
                    if pipeStage(1).valid_event = '1' then
                        if pipeStage(1).excitation_polarity = POSITIVE_CHANNEL then
                            word_in <= positive_state.doutb;
                            frame_row <= positive_frame.doutb;
                        else
                            word_in <= negative_state.doutb;
                            frame_row <= negative_frame.doutb;
                        end if;
                    end if;

                    -- STAGE 3: Perform integration of the activated neurons
                    -- Write back updated cluster from PREVIOUS cycle's event
                    word_out <= word_in;
                    spike_accum := 0;
                    -- Default value for spike_counter_hit
                    spike_counter_hit <= '0';
                    if pipeStage(2).valid_event = '1' then
                        for i in 0 to NEURONS_PER_CLUSTER - 1 loop
                            spike(i) := '0';
                            if pipeStage(2).active_pixel(i) = '1' then
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
                        if spike_counter >= SPIKE_ACCUMULATION_LIMIT then
                            spike_counter_hit <= '1';
                            spike_counter <= 0;
                        else
                            spike_counter <= spike_counter + spike_accum;
                        end if;
                    end if;

                    -- STAGE 4: Write back to memory the updated neuron states
                    if pipeStage(3).valid_event = '1' then
                        if pipeStage(3).excitation_polarity = POSITIVE_CHANNEL then
                            positive_state.addra <= std_logic_vector(to_unsigned(pipeStage(3).memory_address, positive_state.addra'length));
                            positive_state.dina <= word_out;
                            positive_state.ena <= '1';
                            positive_state.wea <= (others => '1');

                            positive_frame.addra <= std_logic_vector(to_unsigned(pipeStage(3).memory_address, positive_frame.addra'length));
                            positive_frame.dina <= spike_out;
                            positive_frame.ena <= '1';
                            positive_frame.wea <= (others => '1');
                        else
                            negative_state.addra <= std_logic_vector(to_unsigned(pipeStage(3).memory_address, negative_state.addra'length));
                            negative_state.dina <= word_out;
                            negative_state.ena <= '1';
                            negative_state.wea <= (others => '1');

                            negative_frame.addra <= std_logic_vector(to_unsigned(pipeStage(3).memory_address, negative_frame.addra'length));
                            negative_frame.dina <= spike_out;
                            negative_frame.ena <= '1';
                            negative_frame.wea <= (others => '1');
                        end if;
                    end if;

                when DECAY =>
                    if prev_state = INTEGRATE then
                        -- Start DECAY
                        decay_ongoing <= '1';

                        decay_has_data <= '0'; -- have_data = 0 on entry (no doutb yet)
                        decay_last_read_issued <= '0';

                        -- Prime: request read(0) now; next cycle doutb(0) is valid
                        decay_address_read <= 1; -- next read to issue
                        decay_address_write <= 0; -- next write address (matches doutb when have_data=1)

                        positive_state.addrb <= std_logic_vector(to_unsigned(0, positive_state.addrb'length));
                        positive_state.enb <= '1';
                        negative_state.addrb <= std_logic_vector(to_unsigned(0, negative_state.addrb'length));
                        negative_state.enb <= '1';

                        -- No write on entry
                        positive_state.ena <= '0';
                        negative_state.ena <= '0';

                    elsif decay_ongoing = '1' then

                        ----------------------------------------------------------------------
                        -- 1) WRITE stage (consume doutb from the read issued previous cycle)
                        ----------------------------------------------------------------------
                        if decay_has_data = '1' then -- have_data
                            -- Compute decayed words from current doutb
                            for i in 0 to NEURONS_PER_CLUSTER - 1 loop
                                decay_negative_cell := unsigned(
                                    negative_state.doutb((i + 1) * MEMBRANE_POTENTIAL_SIZE - 1 downto i * MEMBRANE_POTENTIAL_SIZE)
                                    );
                                decay_positive_cell := unsigned(
                                    positive_state.doutb((i + 1) * MEMBRANE_POTENTIAL_SIZE - 1 downto i * MEMBRANE_POTENTIAL_SIZE)
                                    );

                                decay_negative_cell := decay_negative_cell srl 1;
                                decay_positive_cell := decay_positive_cell srl 1;

                                decay_negative_word_out((i + 1) * MEMBRANE_POTENTIAL_SIZE - 1 downto i * MEMBRANE_POTENTIAL_SIZE)
                                := std_logic_vector(decay_negative_cell);
                                decay_positive_word_out((i + 1) * MEMBRANE_POTENTIAL_SIZE - 1 downto i * MEMBRANE_POTENTIAL_SIZE)
                                := std_logic_vector(decay_positive_cell);
                            end loop;

                            -- Write back to the address that produced doutb this cycle
                            negative_state.addra <= std_logic_vector(to_unsigned(decay_address_write, negative_state.addra'length));
                            negative_state.dina <= std_logic_vector(decay_negative_word_out);
                            negative_state.ena <= '1';
                            negative_state.wea <= (others => '1');

                            positive_state.addra <= std_logic_vector(to_unsigned(decay_address_write, positive_state.addra'length));
                            positive_state.dina <= std_logic_vector(decay_positive_word_out);
                            positive_state.ena <= '1';
                            positive_state.wea <= (others => '1');

                            -- STOP condition: only stop AFTER we actually write the last address
                            if (decay_last_read_issued = '1') and (decay_address_write = (SNN_FRAME_HEIGHT * SNN_FRAME_WIDTH/NEURONS_PER_CLUSTER) - 1) then
                                decay_ongoing <= '0';
                                decay_has_data <= '0';
                                decay_last_read_issued <= '0';

                                -- Stop further reads
                                positive_state.enb <= '0';
                                negative_state.enb <= '0';
                            else
                                -- Advance write pointer AFTER using it (and after stop check)
                                decay_address_write <= decay_address_write + 1;
                            end if;

                        else
                            -- No valid doutb yet
                            positive_state.ena <= '0';
                            negative_state.ena <= '0';
                        end if;

                        ----------------------------------------------------------------------
                        -- 2) READ stage (issue next read until we've issued the last one)
                        ----------------------------------------------------------------------
                        if decay_last_read_issued = '0' then -- last_read_issued = 0
                            if decay_address_read <= (SNN_FRAME_HEIGHT * SNN_FRAME_WIDTH/NEURONS_PER_CLUSTER) - 1 then
                                positive_state.addrb <= std_logic_vector(to_unsigned(decay_address_read, positive_state.addrb'length));
                                positive_state.enb <= '1';
                                negative_state.addrb <= std_logic_vector(to_unsigned(decay_address_read, negative_state.addrb'length));
                                negative_state.enb <= '1';

                                -- Mark that the last read has now been issued
                                if decay_address_read = (SNN_FRAME_HEIGHT * SNN_FRAME_WIDTH/NEURONS_PER_CLUSTER) - 1 then
                                    decay_last_read_issued <= '1'; -- last_read_issued
                                end if;

                                -- Next read address
                                decay_address_read <= decay_address_read + 1;
                            else
                                -- Safety: no more reads to issue
                                positive_state.enb <= '0';
                                negative_state.enb <= '0';
                                decay_last_read_issued <= '1';
                            end if;
                        else
                            -- Drain phase: do not issue further reads
                            positive_state.enb <= '0';
                            negative_state.enb <= '0';
                        end if;

                        ----------------------------------------------------------------------
                        -- 3) Update have_data for next cycle
                        ----------------------------------------------------------------------
                        -- After we have issued at least one read (entry did), doutb will be valid next cycle.
                        decay_has_data <= '1';

                    end if;
                when RESET =>
                    -- RESET goes address by address setting everything to the initial value
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
                            negative_state.addra <= std_logic_vector(to_unsigned(reset_address, negative_state.addra'length));
                            negative_state.dina <= (others => '0');
                            negative_state.ena <= '1';
                            negative_state.wea <= (others => '1');

                            negative_frame.addra <= std_logic_vector(to_unsigned(reset_address, negative_frame.addra'length));
                            negative_frame.dina <= (others => '0');
                            negative_frame.ena <= '1';
                            negative_frame.wea <= (others => '1');
                        else
                            positive_state.addra <= std_logic_vector(to_unsigned(reset_address, positive_state.addra'length));
                            positive_state.dina <= (others => '0');
                            positive_state.ena <= '1';
                            positive_state.wea <= (others => '1');

                            positive_frame.addra <= std_logic_vector(to_unsigned(reset_address, positive_frame.addra'length));
                            positive_frame.dina <= (others => '0');
                            positive_frame.ena <= '1';
                            positive_frame.wea <= (others => '1');
                        end if;
                    end if;
                when others =>
                    -- Nothing
            end case;

            -- AXI Stream Controller part
            -- AXI Valid and AXI last are driven with 1 clock difference
            axi_valid_reg <= '0';
            axi_valid_reg_d <= axi_valid_reg;
            axi_last_reg <= '0';
            axi_last_reg_d <= axi_last_reg;
            m_axis_tlast <= axi_last_reg_d;
            m_axis_tvalid <= axi_valid_reg_d;
            -- If axi_valid = 1, the data is already is flush_out
            if axi_valid_reg_d = '1' then
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
                    flush_ongoing_d <= flush_ongoing;
                    flush_chanIdx_d <= flush_chanIdx;
                    flush_buffIdx_d <= flush_buffIdx;

                    -- First FLUSH cycle: initialise indices and start negative channel
                    if prev_state /= FLUSH then
                        flush_address <= 0;
                        positive_frame.addrb <= (others => '0');
                        negative_frame.addrb <= (others => '0');
                        flush_rowIdx <= 0;
                        flush_colIdx <= 0;
                        flush_buffIdx <= FLUSH_BUFFER_POSITIONS - 1;
                        flush_chanIdx <= NEGATIVE_CHANNEL;
                        flush_ongoing <= '1';
                        negative_frame.enb <= '1';

                        -- Ongoing FLUSH
                    elsif flush_ongoing_d = '1' then
                        if m_axis_tready = '1' then
                            if flush_chanIdx = POSITIVE_CHANNEL then
                                positive_frame.addrb <= std_logic_vector(unsigned(positive_frame.addrb) + 1);
                                positive_frame.enb <= '1';
                            else
                                negative_frame.addrb <= std_logic_vector(unsigned(negative_frame.addrb) + 1);
                                negative_frame.enb <= '1';
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
                                            positive_frame.enb <= '0';
                                        else
                                            -- If not last frame of the flush, change channel
                                            flush_chanIdx <= POSITIVE_CHANNEL;
                                            positive_frame.enb <= '1';
                                            negative_frame.enb <= '0';
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
                        end if;

                        -- 2) read value
                        if flush_chanIdx_d = POSITIVE_CHANNEL then
                            flush_out((flush_buffIdx_d + 1) * NEURONS_PER_CLUSTER - 1 downto flush_buffIdx_d * NEURONS_PER_CLUSTER) <= positive_frame.doutb;
                        else
                            flush_out((flush_buffIdx_d + 1) * NEURONS_PER_CLUSTER - 1 downto flush_buffIdx_d * NEURONS_PER_CLUSTER) <= negative_frame.doutb;
                        end if;
                    end if; -- flush_ongoing = '1'
            end case;
        end if;
    end process;

    -- bram_controller : process (state)
    -- case state is
    --     when INTEGRATE =>
    --     when FLUSH =>
    --     when DECAY =>
    --     when RESET =>
    -- end case;
    -- begin
    -- end process;

    -- Trigger decay execution
    decayTrigger : process (aclk, state)
    begin
        if rising_edge(aclk) then
            case state is
                when INTEGRATE =>
                    if decay_counter = DECAY_COUNTER_LIMIT then
                        decay_counter <= 0;
                        decay_counter_hit <= '1';
                    else
                        decay_counter <= decay_counter + 1;
                        decay_counter_hit <= '0';
                    end if;
                when others =>
                    decay_counter <= 0;
                    decay_counter_hit <= '0';

            end case;
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