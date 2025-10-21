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
        SPIKE_ACCUMULATION_LIMIT : positive := 15000
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
    signal s_axis_tready_signal : std_logic;
    signal route_x : unsigned(4 downto 0);
    signal route_y : unsigned(6 downto 0);
    signal enable_x : unsigned(0 to 127);
    signal enable_y : unsigned(0 to 127);

    signal enable_mat : t_one_hot_encoding_array;
    signal positive_spike_mat : t_one_hot_encoding_array;
    signal negative_spike_mat : t_one_hot_encoding_array;
    signal spike_counter : natural range 0 to SPIKE_ACCUMULATION_LIMIT;
    signal spike_counter_signal : std_logic;

    signal active_pixel : std_logic_vector(3 downto 0);

begin

    -- generate 2D array of neurons
    gen_y : for j in 0 to (GRID_SIZE_Y - 1) generate
        -- In the X axis, neurons are clustered due to the event encoding format (PSEVT2.1)
        gen_x : for i in 0 to (GRID_SIZE_X/4 - 1) generate
            gen_k : for k in 0 to 3 generate
                neuronPositive : entity work.neuron
                    generic map(
                        MEMBRANE_POTENTIAL_SIZE => 5
                    )
                    port map(
                        clk => aclk,
                        areset => aresetn,
                        enable => enable_mat(i, j),
                        active_pixel => active_pixel(k),
                        in_signal => positive_excitation_signal,
                        out_signal => positive_spike_mat(i, j),
                        spike_out_signal => spike_counter_signal
                    );

                neuronNegative : entity work.neuron
                    generic map(
                        MEMBRANE_POTENTIAL_SIZE => 5
                    )
                    port map(
                        clk => aclk,
                        areset => aresetn,
                        enable => enable_mat(i, j),
                        active_pixel => active_pixel(k),
                        in_signal => negative_excitation_signal,
                        out_signal => negative_spike_mat(i, j),
                        spike_out_signal => spike_counter_signal
                    );

            end generate gen_k;
        end generate gen_x;
    end generate gen_y;

    -- generate 2D array of enable signals
    gen_enable_x : for i in 0 to (GRID_SIZE_X/4 - 1) generate
        enable_x(i) <= '1' when route_x = to_unsigned(i, 7) else
        '0';
    end generate;

    gen_enable_y : for j in 0 to (GRID_SIZE_Y - 1) generate
        enable_y(j) <= '1' when route_y = to_unsigned(j, 7) else
        '0';

    end generate;

    gen_enable_xy_outer : for j in 0 to (GRID_SIZE_Y - 1) generate
        gen_enable_xy_inner : for i in 0 to (GRID_SIZE_X/4 - 1) generate
            enable_mat(i, j) <= enable_x(i) and enable_y(j);
        end generate;
    end generate;

    eventDistribution : process (aclk, aresetn)
    begin
        if rising_edge(aclk) then
            positive_excitation_signal <= '0';
            negative_excitation_signal <= '0';
            if s_axis_tvalid = '1' and s_axis_tready_signal = '1' then
                -- Divide by 4 or 2 shifts right, same as leaving out the 2LSb
                -- Target dimension is 128, only 7 bits needed. Therefore, get the slice [8:2]
                -- On the X axis, we divide again by 4, as neurons are clustered

                -- TODO: Coordinates arrive unchanged, I need to substract them here (or in Cropper)
                route_x <= unsigned((s_axis_tdata(51 downto 47)));
                route_y <= unsigned(s_axis_tdata(40 downto 34));

                if (s_axis_tdata(63 downto 60) = POS_EVT) then
                    positive_excitation_signal <= '1';
                else
                    positive_excitation_signal <= '0';
                end if;

                negative_excitation_signal <= not positive_excitation_signal;

                active_pixel(3) <= or_reduce(s_axis_tdata(31 downto 24));
                active_pixel(2) <= or_reduce(s_axis_tdata(23 downto 16));
                active_pixel(1) <= or_reduce(s_axis_tdata(15 downto 8));
                active_pixel(0) <= or_reduce(s_axis_tdata(7 downto 0));
            end if;
        end if;
    end process;

    spikeCountering : process (aclk, aresetn)
    begin
        if rising_edge(aclk) then
            if spike_counter = SPIKE_ACCUMULATION_LIMIT then
                spike_counter <= 0;
            elsif spike_counter_signal = '1' then
                spike_counter <= spike_counter + 1;
            else
                spike_counter <= spike_counter;
            end if;
        end if;
    end process;

    -- Always ready to receive
    s_axis_tready_signal <= '1';
    s_axis_tready <= s_axis_tready_signal;
end rtl;