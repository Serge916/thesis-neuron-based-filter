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

    --------------------------------------------------------------------
    -- Counters / thresholds
    --------------------------------------------------------------------
    signal spike_counter : natural range 0 to SPIKE_ACCUMULATION_LIMIT := 0;
    signal spike_counter_hit : std_logic := '0';

    signal decay_counter : natural range 0 to DECAY_COUNTER_LIMIT := 0;
    signal decay_counter_hit : std_logic := '0';

    constant INITIAL_WORD : unsigned(MEMBRANE_POTENTIAL_SIZE - 1 downto 0) := (others => '0');

    --------------------------------------------------------------------
    -- State machine
    --------------------------------------------------------------------
    type state_t is (INTEGRATE, DECAY, FLUSH, RESET);
    signal state : state_t := INTEGRATE;
    signal prev_state : state_t := INTEGRATE;
    signal next_state : state_t := INTEGRATE;

    --------------------------------------------------------------------
    -- BRAM interface records
    --------------------------------------------------------------------
    type state_mem_interface_t is record
        ena : std_logic;
        wea : std_logic_vector(0 downto 0);
        addra : std_logic_vector(10 downto 0);
        dina : std_logic_vector(63 downto 0);
        enb : std_logic;
        addrb : std_logic_vector(10 downto 0);
        doutb : std_logic_vector(63 downto 0);
    end record;

    type frame_mem_interface_t is record
        ena : std_logic;
        wea : std_logic_vector(0 downto 0);
        addra : std_logic_vector(10 downto 0);
        dina : std_logic_vector(7 downto 0);
        enb : std_logic;
        addrb : std_logic_vector(10 downto 0);
        doutb : std_logic_vector(7 downto 0);
    end record;

    signal positive_state : state_mem_interface_t;
    signal negative_state : state_mem_interface_t;
    signal positive_frame : frame_mem_interface_t;
    signal negative_frame : frame_mem_interface_t;

    --------------------------------------------------------------------
    -- Address / event types
    --------------------------------------------------------------------
    subtype mem_addr_t is integer range 0 to (SNN_FRAME_HEIGHT * SNN_FRAME_WIDTH/NEURONS_PER_CLUSTER) - 1;

    type event_t is record
        vld : std_logic;
        pol : std_logic;
        addr : mem_addr_t;
        pix : std_logic_vector(NEURONS_PER_CLUSTER - 1 downto 0);
    end record;

    signal evt_q : event_t;

    --------------------------------------------------------------------
    -- Pipeline stage metadata (same shape as original)
    --------------------------------------------------------------------
    type pipe_meta_t is record
        valid_event : std_logic;
        excitation_polarity : std_logic;
        memory_address : mem_addr_t;
        active_pixel : std_logic_vector(NEURONS_PER_CLUSTER - 1 downto 0);
    end record;

    type pipe_meta_arr_t is array (natural range <>) of pipe_meta_t;
    constant PIPE_STAGES_C : natural := 4;
    signal pipeStage : pipe_meta_arr_t(0 to PIPE_STAGES_C);

    --------------------------------------------------------------------
    -- Pipeline data
    --------------------------------------------------------------------
    signal word_in : std_logic_vector(MEMBRANE_POTENTIAL_SIZE * NEURONS_PER_CLUSTER - 1 downto 0) := (others => '0');
    signal word_out : std_logic_vector(MEMBRANE_POTENTIAL_SIZE * NEURONS_PER_CLUSTER - 1 downto 0) := (others => '0');

    signal frame_row : std_logic_vector(NEURONS_PER_CLUSTER - 1 downto 0) := (others => '0');
    signal spike_out : std_logic_vector(NEURONS_PER_CLUSTER - 1 downto 0) := (others => '0');

    --------------------------------------------------------------------
    -- Read/write request structs (generated by pipeline/reset/flush)
    --------------------------------------------------------------------
    type rd_req_t is record
        vld : std_logic;
        addr : mem_addr_t;
    end record;

    type wr_req_state_t is record
        vld : std_logic;
        addr : mem_addr_t;
        data : std_logic_vector(63 downto 0);
    end record;

    type wr_req_frame_t is record
        vld : std_logic;
        addr : mem_addr_t;
        data : std_logic_vector(7 downto 0);
    end record;

    type chan_rd_req_t is record
        st : rd_req_t;
        fr : rd_req_t;
    end record;

    type chan_wr_req_t is record
        st : wr_req_state_t;
        fr : wr_req_frame_t;
    end record;

    signal rd_pos, rd_neg : chan_rd_req_t;
    signal wr_pos, wr_neg : chan_wr_req_t;
    signal flush_rd_pos : rd_req_t;
    signal flush_rd_neg : rd_req_t;
    constant FLUSH_BUFFER_POSITIONS : natural := (AXIS_TDATA_WIDTH_G / NEURONS_PER_CLUSTER);

    signal flush_done : std_logic := '0';
    signal flush_mode : std_logic;
    signal fl_addr : mem_addr_t := 0;
    signal fl_chan : std_logic := NEGATIVE_CHANNEL;
    signal fl_buffIdx : natural range 0 to FLUSH_BUFFER_POSITIONS - 1 := FLUSH_BUFFER_POSITIONS - 1;
    -- Flush assembler
    signal fl_assem : std_logic_vector(AXIS_TDATA_WIDTH_G - 1 downto 0) := (others => '0');

    -- Metadata pipeline for 1-cycle BRAM latency
    signal fl_chan_q : std_logic := NEGATIVE_CHANNEL;
    signal fl_buffIdx_q : natural range 0 to FLUSH_BUFFER_POSITIONS - 1 := FLUSH_BUFFER_POSITIONS - 1;
    signal fl_last_q : std_logic := '0';

    -- Control: whether we are actively issuing reads this cycle
    signal fl_step : std_logic := '0';

    --------------------------------------------------------------------
    -- Reset walker
    --------------------------------------------------------------------
    signal rst_addr : mem_addr_t := 0;
    signal rst_done : std_logic := '0';

    --------------------------------------------------------------------
    -- AXI output regs
    --------------------------------------------------------------------
    signal m_axis_tvalid_r : std_logic := '0';
    signal m_axis_tlast_r : std_logic := '0';
    signal m_axis_tdata_r : std_logic_vector(AXIS_TDATA_WIDTH_G - 1 downto 0) := (others => '0');
    signal m_axis_tkeep_r : std_logic_vector((AXIS_TDATA_WIDTH_G/8) - 1 downto 0) := (others => '1');
    signal m_axis_tuser_r : std_logic_vector(AXIS_TUSER_WIDTH_G - 1 downto 0) := (others => '1');

    --------------------------------------------------------------------
    -- BRAM IP components
    --------------------------------------------------------------------
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

    --------------------------------------------------------------------
    -- Drive AXI output ports
    --------------------------------------------------------------------
    m_axis_tvalid <= m_axis_tvalid_r;
    m_axis_tlast <= m_axis_tlast_r;
    m_axis_tdata <= m_axis_tdata_r;
    m_axis_tkeep <= m_axis_tkeep_r;
    m_axis_tuser <= m_axis_tuser_r;

    -- Match original: tready is purely state-based (no backpressure in INTEGRATE)
    s_axis_tready <= '1' when (state = INTEGRATE) else
        '0';
    -- flush_mode is true while flushing OR on the entry cycle into flush
    flush_mode <= '1' when (state = FLUSH) or ((next_state = FLUSH) and (state /= FLUSH)) else
        '0';

    --------------------------------------------------------------------
    -- BRAM instances
    --------------------------------------------------------------------
    positive_frame_mem : blk_mem_activation
    port map(
        clka => aclk,
        ena => positive_frame.ena,
        wea => positive_frame.wea,
        addra => positive_frame.addra,
        dina => positive_frame.dina,
        clkb => aclk,
        enb => positive_frame.enb,
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
        addrb => positive_state.addrb,
        doutb => positive_state.doutb
    );

    --------------------------------------------------------------------
    -- AXI input decode
    -- IMPORTANT: Matches original externally:
    --   - When state=INTEGRATE, s_axis_tready=1 always
    --   - If tvalid=1, we "accept" the beat regardless of hazards
    --   - Hazards are handled by DROPPING the event internally (like original)
    --------------------------------------------------------------------
    axi_in : process (aclk)
        variable a : mem_addr_t;
    begin
        if rising_edge(aclk) then
            if aresetn = '0' then
                evt_q.vld <= '0';
                evt_q.pol <= NEGATIVE_CHANNEL;
                evt_q.addr <= 0;
                evt_q.pix <= (others => '0');
            else
                -- Default: no buffered event this cycle
                evt_q.vld <= '0';

                if (state = INTEGRATE) and (s_axis_tvalid = '1') then
                    a := to_integer(unsigned(s_axis_tdata(40 downto 34))) * CLUSTERS_PER_ROW
                        + to_integer(unsigned(s_axis_tdata(51 downto 48)));

                    evt_q.vld <= '1';
                    evt_q.addr <= a;

                    if (s_axis_tdata(63 downto 60) = POS_EVT) then
                        evt_q.pol <= POSITIVE_CHANNEL;
                    else
                        evt_q.pol <= NEGATIVE_CHANNEL;
                    end if;

                    evt_q.pix(7) <= or_reduce(s_axis_tdata(31 downto 28));
                    evt_q.pix(6) <= or_reduce(s_axis_tdata(27 downto 24));
                    evt_q.pix(5) <= or_reduce(s_axis_tdata(23 downto 20));
                    evt_q.pix(4) <= or_reduce(s_axis_tdata(19 downto 16));
                    evt_q.pix(3) <= or_reduce(s_axis_tdata(15 downto 12));
                    evt_q.pix(2) <= or_reduce(s_axis_tdata(11 downto 8));
                    evt_q.pix(1) <= or_reduce(s_axis_tdata(7 downto 4));
                    evt_q.pix(0) <= or_reduce(s_axis_tdata(3 downto 0));
                end if;
            end if;
        end if;
    end process;

    --------------------------------------------------------------------
    -- Pipeline + RESET write request generation
    --------------------------------------------------------------------
    pipeline_seq : process (aclk)
        variable cell : unsigned(MEMBRANE_POTENTIAL_SIZE - 1 downto 0);
        variable spike : std_logic_vector(NEURONS_PER_CLUSTER - 1 downto 0);
        variable spike_acc : integer range 0 to NEURONS_PER_CLUSTER;
        variable hazard : boolean;
    begin
        if rising_edge(aclk) then
            if aresetn = '0' then
                for k in 0 to PIPE_STAGES_C loop
                    pipeStage(k).valid_event <= '0';
                    pipeStage(k).excitation_polarity <= NEGATIVE_CHANNEL;
                    pipeStage(k).memory_address <= 0;
                    pipeStage(k).active_pixel <= (others => '0');
                end loop;

                rd_pos.st.vld <= '0';
                rd_pos.fr.vld <= '0';
                rd_neg.st.vld <= '0';
                rd_neg.fr.vld <= '0';
                wr_pos.st.vld <= '0';
                wr_pos.fr.vld <= '0';
                wr_neg.st.vld <= '0';
                wr_neg.fr.vld <= '0';

                word_in <= (others => '0');
                word_out <= (others => '0');
                frame_row <= (others => '0');
                spike_out <= (others => '0');

                spike_counter <= 0;
                spike_counter_hit <= '0';

                rst_addr <= 0;
                rst_done <= '0';

            else
                -- Default: clear all request valids each cycle
                rd_pos.st.vld <= '0';
                rd_pos.fr.vld <= '0';
                rd_neg.st.vld <= '0';
                rd_neg.fr.vld <= '0';
                wr_pos.st.vld <= '0';
                wr_pos.fr.vld <= '0';
                wr_neg.st.vld <= '0';
                wr_neg.fr.vld <= '0';

                spike_counter_hit <= '0';

                if state /= RESET then
                    rst_addr <= 0;
                    rst_done <= '0';
                end if;

                if state = INTEGRATE then
                    -- Shift pipeline
                    for k in PIPE_STAGES_C downto 1 loop
                        pipeStage(k) <= pipeStage(k - 1);
                    end loop;

                    -- Stage0 defaults
                    pipeStage(0).valid_event <= '0';
                    pipeStage(0).excitation_polarity <= NEGATIVE_CHANNEL;
                    pipeStage(0).memory_address <= 0;
                    pipeStage(0).active_pixel <= (others => '0');

                    -- Hazard check exactly like original: drop event if address is in-flight
                    hazard := false;
                    if evt_q.vld = '1' then
                        for h in 0 to PIPE_STAGES_C loop
                            if (pipeStage(h).valid_event = '1') and (pipeStage(h).memory_address = evt_q.addr) then
                                hazard := true;
                            end if;
                        end loop;

                        if not hazard then
                            pipeStage(0).valid_event <= '1';
                            pipeStage(0).excitation_polarity <= evt_q.pol;
                            pipeStage(0).memory_address <= evt_q.addr;
                            pipeStage(0).active_pixel <= evt_q.pix;

                            -- Issue BRAM reads for stage1 capture next cycle
                            if evt_q.pol = POSITIVE_CHANNEL then
                                rd_pos.st.vld <= '1';
                                rd_pos.st.addr <= evt_q.addr;
                                rd_pos.fr.vld <= '1';
                                rd_pos.fr.addr <= evt_q.addr;
                            else
                                rd_neg.st.vld <= '1';
                                rd_neg.st.addr <= evt_q.addr;
                                rd_neg.fr.vld <= '1';
                                rd_neg.fr.addr <= evt_q.addr;
                            end if;
                        else
                            -- DROP (matches original externally since tready stayed high)
                            null;
                        end if;
                    end if;

                    -- Stage1: capture BRAM outputs (assumes 1-cycle read latency)
                    if pipeStage(1).valid_event = '1' then
                        if pipeStage(1).excitation_polarity = POSITIVE_CHANNEL then
                            word_in <= positive_state.doutb;
                            frame_row <= positive_frame.doutb;
                        else
                            word_in <= negative_state.doutb;
                            frame_row <= negative_frame.doutb;
                        end if;
                    end if;

                    -- Stage2: integrate
                    word_out <= word_in;
                    spike_acc := 0;

                    if pipeStage(2).valid_event = '1' then
                        for i in 0 to NEURONS_PER_CLUSTER - 1 loop
                            spike(i) := '0';
                            if pipeStage(2).active_pixel(i) = '1' then
                                cell := unsigned(word_in((i + 1) * MEMBRANE_POTENTIAL_SIZE - 1 downto i * MEMBRANE_POTENTIAL_SIZE));

                                if cell(MEMBRANE_POTENTIAL_SIZE - 1) = '1' then
                                    spike(i) := '1';
                                    spike_acc := spike_acc + 1;
                                end if;

                                if cell = INITIAL_WORD then
                                    cell := to_unsigned(1, MEMBRANE_POTENTIAL_SIZE);
                                else
                                    cell := cell sll 1;
                                end if;

                                word_out((i + 1) * MEMBRANE_POTENTIAL_SIZE - 1 downto i * MEMBRANE_POTENTIAL_SIZE)
                                <= std_logic_vector(cell);
                            end if;
                        end loop;

                        spike_out <= spike or frame_row;

                        -- Spike counter / flush trigger (kept as in your draft: threshold=5)
                        if spike_counter >= 5 then
                            spike_counter_hit <= '1';
                            spike_counter <= 0;
                        else
                            spike_counter <= spike_counter + spike_acc;
                        end if;
                    end if;

                    -- Stage3: issue writes
                    if pipeStage(3).valid_event = '1' then
                        if pipeStage(3).excitation_polarity = POSITIVE_CHANNEL then
                            wr_pos.st.vld <= '1';
                            wr_pos.st.addr <= pipeStage(3).memory_address;
                            wr_pos.st.data <= word_out;

                            wr_pos.fr.vld <= '1';
                            wr_pos.fr.addr <= pipeStage(3).memory_address;
                            wr_pos.fr.data <= spike_out;
                        else
                            wr_neg.st.vld <= '1';
                            wr_neg.st.addr <= pipeStage(3).memory_address;
                            wr_neg.st.data <= word_out;

                            wr_neg.fr.vld <= '1';
                            wr_neg.fr.addr <= pipeStage(3).memory_address;
                            wr_neg.fr.data <= spike_out;
                        end if;
                    end if;

                elsif state = RESET then
                    -- Keep pipeline empty while resetting
                    for k in 0 to PIPE_STAGES_C loop
                        pipeStage(k).valid_event <= '0';
                    end loop;

                    -- Clear BOTH channels, BOTH memories per address (safe: separate BRAMs)
                    wr_pos.st.vld <= '1';
                    wr_pos.st.addr <= rst_addr;
                    wr_pos.st.data <= (others => '0');
                    wr_neg.st.vld <= '1';
                    wr_neg.st.addr <= rst_addr;
                    wr_neg.st.data <= (others => '0');
                    wr_pos.fr.vld <= '1';
                    wr_pos.fr.addr <= rst_addr;
                    wr_pos.fr.data <= (others => '0');
                    wr_neg.fr.vld <= '1';
                    wr_neg.fr.addr <= rst_addr;
                    wr_neg.fr.data <= (others => '0');

                    if rst_addr = (SNN_FRAME_HEIGHT * SNN_FRAME_WIDTH/NEURONS_PER_CLUSTER) - 1 then
                        rst_addr <= 0;
                        rst_done <= '1';
                    else
                        rst_addr <= rst_addr + 1;
                        rst_done <= '0';
                    end if;

                else
                    -- DECAY / FLUSH handled elsewhere, pipeline idle by default
                    null;
                end if;
            end if;
        end if;
    end process;

    --------------------------------------------------------------------
    -- BRAM arbiter (COMBINATIONAL)
    -- - Port B reads come from pipeline or flush
    -- - Port A writes come from pipeline or reset
    -- - Enables asserted only when needed
    --------------------------------------------------------------------
    bram_arbiter : process (aresetn, flush_mode,
        rd_pos, rd_neg, wr_pos, wr_neg,
        flush_rd_pos, flush_rd_neg)
    begin
        ----------------------------------------------------------------
        -- Defaults: fully idle (no latches)
        ----------------------------------------------------------------
        -- Positive state
        positive_state.ena <= '0';
        positive_state.wea <= (others => '0');
        positive_state.addra <= (others => '0');
        positive_state.dina <= (others => '0');
        positive_state.enb <= '0';
        positive_state.addrb <= (others => '0');

        -- Negative state
        negative_state.ena <= '0';
        negative_state.wea <= (others => '0');
        negative_state.addra <= (others => '0');
        negative_state.dina <= (others => '0');
        negative_state.enb <= '0';
        negative_state.addrb <= (others => '0');

        -- Positive frame
        positive_frame.ena <= '0';
        positive_frame.wea <= (others => '0');
        positive_frame.addra <= (others => '0');
        positive_frame.dina <= (others => '0');
        positive_frame.enb <= '0';
        positive_frame.addrb <= (others => '0');

        -- Negative frame
        negative_frame.ena <= '0';
        negative_frame.wea <= (others => '0');
        negative_frame.addra <= (others => '0');
        negative_frame.dina <= (others => '0');
        negative_frame.enb <= '0';
        negative_frame.addrb <= (others => '0');

        if aresetn = '1' then
            ----------------------------------------------------------------
            -- READS (Port B)
            ----------------------------------------------------------------
            -- State reads from pipeline (only meaningful in INTEGRATE)
            if rd_pos.st.vld = '1' then
                positive_state.enb <= '1';
                positive_state.addrb <= std_logic_vector(to_unsigned(rd_pos.st.addr, positive_state.addrb'length));
            end if;

            if rd_neg.st.vld = '1' then
                negative_state.enb <= '1';
                negative_state.addrb <= std_logic_vector(to_unsigned(rd_neg.st.addr, negative_state.addrb'length));
            end if;

            -- Frame reads:
            --   - During flush_mode: ONLY accept flush requests
            --   - Otherwise: pipeline frame reads
            if flush_mode = '1' then
                if flush_rd_pos.vld = '1' then
                    positive_frame.enb <= '1';
                    positive_frame.addrb <= std_logic_vector(to_unsigned(flush_rd_pos.addr, positive_frame.addrb'length));
                end if;

                if flush_rd_neg.vld = '1' then
                    negative_frame.enb <= '1';
                    negative_frame.addrb <= std_logic_vector(to_unsigned(flush_rd_neg.addr, negative_frame.addrb'length));
                end if;

            else
                if rd_pos.fr.vld = '1' then
                    positive_frame.enb <= '1';
                    positive_frame.addrb <= std_logic_vector(to_unsigned(rd_pos.fr.addr, positive_frame.addrb'length));
                end if;

                if rd_neg.fr.vld = '1' then
                    negative_frame.enb <= '1';
                    negative_frame.addrb <= std_logic_vector(to_unsigned(rd_neg.fr.addr, negative_frame.addrb'length));
                end if;
            end if;

            ----------------------------------------------------------------
            -- WRITES (Port A)
            ----------------------------------------------------------------
            -- State writes
            if wr_pos.st.vld = '1' then
                positive_state.ena <= '1';
                positive_state.wea <= (others => '1');
                positive_state.addra <= std_logic_vector(to_unsigned(wr_pos.st.addr, positive_state.addra'length));
                positive_state.dina <= wr_pos.st.data;
            end if;

            if wr_neg.st.vld = '1' then
                negative_state.ena <= '1';
                negative_state.wea <= (others => '1');
                negative_state.addra <= std_logic_vector(to_unsigned(wr_neg.st.addr, negative_state.addra'length));
                negative_state.dina <= wr_neg.st.data;
            end if;

            -- Frame writes
            if wr_pos.fr.vld = '1' then
                positive_frame.ena <= '1';
                positive_frame.wea <= (others => '1');
                positive_frame.addra <= std_logic_vector(to_unsigned(wr_pos.fr.addr, positive_frame.addra'length));
                positive_frame.dina <= wr_pos.fr.data;
            end if;

            if wr_neg.fr.vld = '1' then
                negative_frame.ena <= '1';
                negative_frame.wea <= (others => '1');
                negative_frame.addra <= std_logic_vector(to_unsigned(wr_neg.fr.addr, negative_frame.addra'length));
                negative_frame.dina <= wr_neg.fr.data;
            end if;
        end if;
    end process;
    --------------------------------------------------------------------
    -- FLUSH + AXI output (simplified)
    -- - One BRAM read per cycle while flushing (unless AXI backpressure stalls)
    -- - One AXI word every 8 cycles
    -- - Correct NEG->POS boundary (no slip)
    --------------------------------------------------------------------
    flush_and_axi_out : process (aclk)
        function slice_hi(i : natural) return natural is
        begin
            return (i + 1) * NEURONS_PER_CLUSTER - 1;
        end function;

        function slice_lo(i : natural) return natural is
        begin
            return i * NEURONS_PER_CLUSTER;
        end function;

        constant MAX_ADDR : mem_addr_t := (SNN_FRAME_HEIGHT * SNN_FRAME_WIDTH/NEURONS_PER_CLUSTER) - 1;

        variable entering_flush : boolean;
        variable can_push_axi : boolean;
        variable stall_flush : boolean;
        variable dout_val : std_logic_vector(NEURONS_PER_CLUSTER - 1 downto 0);
        variable word_complete : std_logic_vector(AXIS_TDATA_WIDTH_G - 1 downto 0);

    begin
        if rising_edge(aclk) then
            if aresetn = '0' then
                -- AXI outputs
                m_axis_tvalid_r <= '0';
                m_axis_tdata_r <= (others => '0');
                m_axis_tlast_r <= '0';
                m_axis_tkeep_r <= (others => '1');
                m_axis_tuser_r <= (others => '1');

                flush_done <= '0';

                -- flush requests
                flush_rd_pos.vld <= '0';
                flush_rd_neg.vld <= '0';
                flush_rd_pos.addr <= 0;
                flush_rd_neg.addr <= 0;

                -- flush state
                fl_addr <= 0;
                fl_chan <= NEGATIVE_CHANNEL;
                fl_buffIdx <= FLUSH_BUFFER_POSITIONS - 1;

                -- assembler + metadata pipe
                fl_assem <= (others => '0');
                fl_chan_q <= NEGATIVE_CHANNEL;
                fl_buffIdx_q <= FLUSH_BUFFER_POSITIONS - 1;
                fl_last_q <= '0';
                fl_step <= '0';

            else
                flush_done <= '0';

                -- default: no BRAM read unless we set it below
                flush_rd_pos.vld <= '0';
                flush_rd_neg.vld <= '0';

                entering_flush := (next_state = FLUSH) and (state /= FLUSH);

                ------------------------------------------------------------
                -- AXI handshake: if accepted, clear valid
                ------------------------------------------------------------
                if (m_axis_tvalid_r = '1') and (m_axis_tready = '1') then
                    if m_axis_tlast_r = '1' then
                        flush_done <= '1';
                    end if;
                    m_axis_tvalid_r <= '0';
                    m_axis_tlast_r <= '0';
                end if;

                ------------------------------------------------------------
                -- Determine if we can accept a freshly completed word
                -- (one-word skid buffer)
                ------------------------------------------------------------
                can_push_axi := (m_axis_tvalid_r = '0'); -- only push if empty
                stall_flush := not can_push_axi; -- if full, stall flush (prevents overwrite)

                ------------------------------------------------------------
                -- Leave FLUSH: reset internal flusher state
                ------------------------------------------------------------
                if (state /= FLUSH) and (next_state /= FLUSH) then
                    fl_addr <= 0;
                    fl_chan <= NEGATIVE_CHANNEL;
                    fl_buffIdx <= FLUSH_BUFFER_POSITIONS - 1;

                    fl_assem <= (others => '0');
                    fl_chan_q <= NEGATIVE_CHANNEL;
                    fl_buffIdx_q <= FLUSH_BUFFER_POSITIONS - 1;
                    fl_last_q <= '0';
                    fl_step <= '0';

                    ------------------------------------------------------------
                    -- Entering FLUSH: prime first request immediately
                    ------------------------------------------------------------
                elsif entering_flush then
                    -- reset assembly
                    fl_assem <= (others => '0');

                    -- start at NEG, addr 0, slice = top slice
                    fl_chan <= NEGATIVE_CHANNEL;
                    fl_addr <= 0;
                    fl_buffIdx <= FLUSH_BUFFER_POSITIONS - 1;

                    -- Issue first read NOW (unless stalled; on entry, AXI buffer is typically empty)
                    if not stall_flush then
                        flush_rd_neg.vld <= '1';
                        flush_rd_neg.addr <= 0;

                        -- latch metadata for next cycle consumption
                        fl_chan_q <= NEGATIVE_CHANNEL;
                        fl_buffIdx_q <= FLUSH_BUFFER_POSITIONS - 1;

                        -- last flag for this request? only true on (POS,MAX,idx=0)
                        fl_last_q <= '0';

                        fl_step <= '1';
                    else
                        fl_step <= '0';
                    end if;

                    ------------------------------------------------------------
                    -- In FLUSH: fixed-rate: consume response, maybe publish word,
                    -- then issue next read (unless stalled)
                    ------------------------------------------------------------
                else
                    --------------------------------------------------------
                    -- 1) Consume BRAM response from previous cycle if we stepped
                    --------------------------------------------------------
                    if fl_step = '1' then
                        if fl_chan_q = POSITIVE_CHANNEL then
                            dout_val := positive_frame.doutb;
                        else
                            dout_val := negative_frame.doutb;
                        end if;

                        fl_assem(slice_hi(fl_buffIdx_q) downto slice_lo(fl_buffIdx_q)) <= dout_val;

                        -- If that response completed the word (buffIdx_q = 0), push to AXI
                        if fl_buffIdx_q = 0 then
                            word_complete := fl_assem;
                            word_complete(slice_hi(fl_buffIdx_q) downto slice_lo(fl_buffIdx_q)) := dout_val;

                            if can_push_axi then
                                m_axis_tvalid_r <= '1';
                                m_axis_tdata_r <= word_complete;
                                m_axis_tlast_r <= fl_last_q;
                            end if;

                            fl_assem <= (others => '0');

                        end if;
                    end if;

                    --------------------------------------------------------
                    -- 2) Issue next BRAM read (1 per cycle) unless stalled
                    --------------------------------------------------------
                    if not stall_flush then
                        -- compute next request based on current fl_addr/fl_chan/fl_buffIdx
                        -- Issue read for current state
                        if fl_chan = POSITIVE_CHANNEL then
                            flush_rd_pos.vld <= '1';
                            flush_rd_pos.addr <= fl_addr;
                        else
                            flush_rd_neg.vld <= '1';
                            flush_rd_neg.addr <= fl_addr;
                        end if;

                        -- latch metadata corresponding to this request
                        fl_chan_q <= fl_chan;
                        fl_buffIdx_q <= fl_buffIdx;

                        -- determine TLAST for the AXI word that will complete when this request is slice 0
                        if (fl_chan = POSITIVE_CHANNEL) and (fl_addr = MAX_ADDR) and (fl_buffIdx = 0) then
                            fl_last_q <= '1';
                        else
                            fl_last_q <= '0';
                        end if;

                        fl_step <= '1';

                        -- advance fl_addr/fl_chan/fl_buffIdx for *next* cycle's request
                        if fl_buffIdx = 0 then
                            fl_buffIdx <= FLUSH_BUFFER_POSITIONS - 1;

                            if fl_addr = MAX_ADDR then
                                fl_addr <= 0;
                                if fl_chan = NEGATIVE_CHANNEL then
                                    fl_chan <= POSITIVE_CHANNEL;
                                else
                                    fl_chan <= POSITIVE_CHANNEL; -- stay; FSM will exit after TLAST accepted
                                end if;
                            else
                                fl_addr <= fl_addr + 1;
                            end if;

                        else
                            fl_buffIdx <= fl_buffIdx - 1;
                            fl_addr <= fl_addr + 1;
                        end if;

                    else
                        -- stalled: do not issue read, do not advance pointers
                        fl_step <= '0';
                    end if;
                end if;
            end if;
        end if;
    end process;
    --------------------------------------------------------------------
    -- Decay trigger (same counter behavior as original)
    --------------------------------------------------------------------
    decayTrigger : process (aclk)
    begin
        if rising_edge(aclk) then
            if aresetn = '0' then
                decay_counter <= 0;
                decay_counter_hit <= '0';
            else
                if decay_counter = DECAY_COUNTER_LIMIT then
                    decay_counter <= 0;
                    decay_counter_hit <= '1';
                else
                    decay_counter <= decay_counter + 1;
                    decay_counter_hit <= '0';
                end if;
            end if;
        end if;
    end process;

    --------------------------------------------------------------------
    -- FSM (align with original externally)
    -- - INTEGRATE -> DECAY on counter hit
    -- - INTEGRATE -> FLUSH on spike_counter_hit
    -- - FLUSH -> RESET when flush_done (TLAST accepted)
    -- - RESET -> INTEGRATE when rst_done
    -- DECAY behavior is a placeholder like original (no real decay yet).
    --------------------------------------------------------------------
    fsm_next : process (state, rst_done, decay_counter_hit, flush_done, spike_counter_hit)

    begin
        next_state <= state;

        case state is
            when INTEGRATE =>
                if decay_counter_hit = '1' then
                    next_state <= DECAY;
                elsif spike_counter_hit = '1' then
                    next_state <= FLUSH;
                end if;

            when DECAY =>
                next_state <= INTEGRATE;

            when FLUSH =>
                if flush_done = '1' then
                    next_state <= RESET;
                end if;

            when RESET =>
                if rst_done = '1' then
                    next_state <= INTEGRATE;
                else
                    next_state <= RESET;
                end if;
        end case;
    end process;
    fsm_reg : process (aclk)
    begin
        if rising_edge(aclk) then
            if aresetn = '0' then
                state <= INTEGRATE;
                prev_state <= INTEGRATE;
            else
                prev_state <= state;
                state <= next_state;
            end if;
        end if;
    end process;

end rtl;