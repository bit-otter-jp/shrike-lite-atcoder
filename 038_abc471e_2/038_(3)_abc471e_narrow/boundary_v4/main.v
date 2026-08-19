(* top *) module main #(
    parameter integer WIDTH = 8,
    parameter [WIDTH-1:0] MOD = 251,
    parameter [WIDTH-1:0] N_MAX = MOD - 1'b1,
    parameter integer VALUE_BYTES = (WIDTH + 7) / 8
) (
    (* iopad_external_pin, clkbuf_inhibit *) input clk,
    (* iopad_external_pin *) output clk_en,
    (* iopad_external_pin *) input rst_n,

    (* iopad_external_pin *) input  spi_ss_n,
    (* iopad_external_pin *) input  spi_sck,
    (* iopad_external_pin *) input  spi_mosi,
    (* iopad_external_pin *) output spi_miso,
    (* iopad_external_pin *) output spi_miso_en
);

    assign clk_en = 1'b1;

    localparam integer VALUE_BITS = VALUE_BYTES * 8;
    localparam integer BYTE_COUNT_WIDTH =
        (VALUE_BYTES <= 1) ? 1 : $clog2(VALUE_BYTES);
    localparam integer COUNT_WIDTH =
        (N_MAX <= 1) ? 1 : $clog2(N_MAX + 1'b1);

    localparam [7:0] CMD_NOP   = 8'h00;
    localparam [7:0] CMD_START = 8'hFE;
    localparam [7:0] CMD_RESET = 8'hFF;
    localparam [7:0] RESET_ACK = 8'h5A;
    localparam [7:0] START_ACK = 8'hA5;

    localparam [2:0] P_WAIT_START     = 3'd0;
    localparam [2:0] P_WAIT_START_ACK = 3'd1;
    localparam [2:0] P_RECEIVE_N      = 3'd2;
    localparam [2:0] P_RECEIVE_K      = 3'd3;
    localparam [2:0] P_STREAM_A       = 3'd4;
    localparam [2:0] P_WAIT_RESULT    = 3'd5;
    localparam [2:0] P_SEND_REPLY     = 3'd6;

    // One compact sequencer.  Every multiplication is staged through A_LAUNCH
    // and returns through A_WAIT; operation-specific behavior is a context.
    localparam [6:0] A_IDLE       = 7'b000_0001;
    localparam [6:0] A_LAUNCH     = 7'b000_0010;
    localparam [6:0] A_WAIT       = 7'b000_0100;
    localparam [6:0] A_ALU        = 7'b000_1000;
    localparam [6:0] A_COMB_CHECK = 7'b001_0000;
    localparam [6:0] A_POW_CHECK  = 7'b010_0000;
    localparam [6:0] A_PUBLISH    = 7'b100_0000;

    localparam [3:0] M_INPUT       = 4'd0;
    localparam [3:0] M_COMB_NUM    = 4'd1;
    localparam [3:0] M_COMB_DEN    = 4'd2;
    localparam [3:0] M_POW_RESULT  = 4'd3;
    localparam [3:0] M_POW_BASE    = 4'd4;
    localparam [3:0] M_COEFF        = 4'd5;
    localparam [3:0] M_PAIR_STAGE   = 4'd6;
    localparam [3:0] M_PAIR_FINISH  = 4'd7;
    localparam [3:0] M_FINAL_S1     = 4'd8;
    localparam [3:0] M_FINAL_SQUARE = 4'd9;
    localparam [3:0] M_FINAL_PAIR   = 4'd10;

    localparam [1:0] U_INPUT      = 2'd0;
    localparam [1:0] U_INPUT_S1   = 2'd1;
    localparam [1:0] U_FINAL_PAIR = 2'd2;
    localparam [1:0] U_FINAL_ADD  = 2'd3;

    wire [7:0] rx_data;
    wire       rx_data_strobe;
    wire       tx_data_hold;
    reg  [7:0] tx_data;

    reg [2:0] proto_state;
    reg [6:0] arith_state;

    reg [COUNT_WIDTH-1:0] n_reg;
    reg [COUNT_WIDTH-1:0] k_reg;
    reg             x_busy;

    // WIDTH=8 constant-folds these to zero; WIDTH=9..16 uses one held
    // high byte and one shared receive/reply phase bit.
    reg [7:0] rx_high_byte;
    reg       value_phase;

    reg [WIDTH-1:0] s1;
    reg [WIDTH-1:0] s2;

    // Four lifetime-shared words replace the old combination, pow,
    // coefficient, and final-specific register banks.
    // input:       scratch0=current x, scratch3=accepted input count
    // combination: scratch0=num, scratch1=i, scratch2=den, scratch3=r
    // pow:         scratch0=preserved value, scratch1=result,
    //              scratch2=base, scratch3=exponent
    // final:       scratch0=coeff_square, scratch1=coeff_pair,
    //              scratch2=pair term, scratch3=square term
    reg [WIDTH-1:0] scratch0;
    reg [WIDTH-1:0] scratch1;
    reg [WIDTH-1:0] scratch2;
    reg [WIDTH-1:0] scratch3;

    reg [WIDTH-1:0] mul_lhs;
    reg [WIDTH-1:0] mul_rhs;
    reg [3:0]       mul_context;
    reg [1:0]       alu_context;

    reg protocol_error;
    reg reply_valid;
    reg status_loaded;
    reg tx_byte_active;

    reg mul_start;
    wire mul_busy;
    wire mul_done;
    wire [WIDTH-1:0] mul_product;

    localparam [VALUE_BITS-1:0] MOD_EXT =
        {{(VALUE_BITS-WIDTH){1'b0}}, MOD};
    localparam [VALUE_BITS-1:0] N_MAX_EXT =
        {{(VALUE_BITS-WIDTH){1'b0}}, N_MAX};

    // scratch1/scratch3 remain WIDTH-sized lifetime-shared words because
    // they also hold modular pow operands.  Their count-role views are
    // restricted to COUNT_WIDTH so N_MAX still shrinks count comparisons.
    wire [COUNT_WIDTH-1:0] input_count =
        scratch3[COUNT_WIDTH-1:0];
    wire [COUNT_WIDTH-1:0] comb_i_count =
        scratch1[COUNT_WIDTH-1:0];
    wire [COUNT_WIDTH-1:0] comb_r_count =
        scratch3[COUNT_WIDTH-1:0];

    wire [VALUE_BITS-1:0] rx_value_complete =
        (VALUE_BYTES == 1) ?
        {{(VALUE_BITS-8){1'b0}}, rx_data} :
        {rx_high_byte, rx_data};
    wire [WIDTH-1:0] answer = scratch0;
    wire [VALUE_BITS-1:0] answer_value =
        {{(VALUE_BITS-WIDTH){1'b0}}, answer};
    wire value_complete = rx_data_strobe &&
        ((VALUE_BYTES == 1) || value_phase);

    wire control_state =
        (proto_state == P_WAIT_START) ||
        (proto_state == P_WAIT_START_ACK) ||
        (proto_state == P_WAIT_RESULT) ||
        (proto_state == P_SEND_REPLY);
    wire command_reset = rx_data_strobe && control_state &&
        (rx_data == CMD_RESET);

    wire invalid_n_event = value_complete &&
        (proto_state == P_RECEIVE_N) &&
        ((rx_value_complete == {VALUE_BITS{1'b0}}) ||
         (rx_value_complete > N_MAX_EXT));
    wire invalid_k_event = value_complete &&
        (proto_state == P_RECEIVE_K) &&
        ((rx_value_complete == {VALUE_BITS{1'b0}}) ||
         (rx_value_complete > {{(VALUE_BITS-WIDTH){1'b0}}, n_reg}));
    wire invalid_a_event = value_complete &&
        (proto_state == P_STREAM_A) &&
        (x_busy || (input_count >= n_reg) ||
         (rx_value_complete >= MOD_EXT));
    wire arithmetic_abort =
        invalid_n_event || invalid_k_event || invalid_a_event;

    // During combination, factor=(N-1)-r+i is in [1,N-1].
    wire [COUNT_WIDTH:0] comb_factor_count_wide =
        {1'b0, n_reg} - 1'b1 - {1'b0, comb_r_count} +
        {1'b0, comb_i_count};
    wire [WIDTH-1:0] comb_factor =
        {{(WIDTH-COUNT_WIDTH){1'b0}},
         comb_factor_count_wide[COUNT_WIDTH-1:0]};
    wire comb_lower_side =
        (k_reg - 1'b1) <= (n_reg - k_reg);

    // Multiplier's internal addend/multiplier capture registers are the only
    // operand staging layer.  The context selects their input while idle.
    always @(*) begin
        mul_lhs = {WIDTH{1'b0}};
        mul_rhs = {WIDTH{1'b0}};
        case (mul_context)
            M_INPUT: begin
                mul_lhs = scratch0;
                mul_rhs = scratch0;
            end
            M_COMB_NUM: begin
                mul_lhs = scratch0;
                mul_rhs = comb_factor;
            end
            M_COMB_DEN: begin
                mul_lhs = scratch2;
                mul_rhs =
                    {{(WIDTH-COUNT_WIDTH){1'b0}}, comb_i_count};
            end
            M_POW_RESULT: begin
                mul_lhs = scratch1;
                mul_rhs = scratch2;
            end
            M_POW_BASE: begin
                mul_lhs = scratch2;
                mul_rhs = scratch2;
            end
            M_COEFF: begin
                mul_lhs = scratch0;
                mul_rhs = scratch1;
            end
            M_PAIR_STAGE: begin
                mul_lhs = scratch0;
                mul_rhs = k_reg - 1'b1;
            end
            M_PAIR_FINISH: begin
                mul_lhs = scratch2;
                mul_rhs = scratch1;
            end
            M_FINAL_S1: begin
                mul_lhs = s1;
                mul_rhs = s1;
            end
            M_FINAL_SQUARE: begin
                mul_lhs = scratch0;
                mul_rhs = s2;
            end
            M_FINAL_PAIR: begin
                mul_lhs = scratch1;
                mul_rhs = scratch2;
            end
        endcase
    end

    reg [WIDTH-1:0] alu_a;
    reg [WIDTH-1:0] alu_b;
    reg             alu_sub;
    always @(*) begin
        alu_a = {WIDTH{1'b0}};
        alu_b = {WIDTH{1'b0}};
        alu_sub = 1'b0;
        case (alu_context)
            U_INPUT: begin
                alu_a = s2;
                alu_b = mul_product;
            end
            U_INPUT_S1: begin
                alu_a = s1;
                alu_b = scratch0;
            end
            U_FINAL_PAIR: begin
                alu_a = mul_product;
                alu_b = s2;
                alu_sub = 1'b1;
            end
            U_FINAL_ADD: begin
                alu_a = scratch3;
                alu_b = mul_product;
            end
        endcase
    end

    // Canonical modular add/sub.  Adding MOD before subtraction keeps the
    // intermediate non-negative; one reduction canonicalizes both operations.
    wire [WIDTH:0] alu_add_wide =
        {1'b0, alu_a} + {1'b0, alu_b};
    wire [WIDTH:0] alu_sub_wide =
        {1'b0, alu_a} + {1'b0, MOD} - {1'b0, alu_b};
    wire [WIDTH:0] alu_pre = alu_sub ? alu_sub_wide : alu_add_wide;
    wire [WIDTH:0] alu_reduced =
        (alu_pre >= {1'b0, MOD}) ?
        (alu_pre - {1'b0, MOD}) : alu_pre;
    wire [WIDTH-1:0] alu_result = alu_reduced[WIDTH-1:0];

    modular_multiplier #(
        .WIDTH(WIDTH),
        .MOD(MOD)
    ) u_modular_multiplier (
        .i_clk(clk),
        .i_rst_n(rst_n),
        .i_clear(command_reset),
        .i_start(mul_start),
        .i_lhs(mul_lhs),
        .i_rhs(mul_rhs),
        .o_busy(mul_busy),
        .o_done(mul_done),
        .o_product(mul_product)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            proto_state      <= P_WAIT_START;
            arith_state      <= A_IDLE;
            n_reg            <= 'd0;
            k_reg            <= 'd0;
            x_busy           <= 1'b0;
            rx_high_byte     <= 8'd0;
            value_phase      <= 1'b0;
            s1               <= 'd0;
            s2               <= 'd0;
            scratch0         <= 'd0;
            scratch1         <= 'd0;
            scratch2         <= 'd0;
            scratch3         <= 'd0;
            mul_context      <= M_INPUT;
            alu_context      <= U_INPUT;
            protocol_error   <= 1'b0;
            reply_valid      <= 1'b0;
            status_loaded    <= 1'b0;
            tx_byte_active   <= 1'b0;
            mul_start        <= 1'b0;
            tx_data          <= 8'h00;
        end else if (command_reset) begin
            proto_state      <= P_WAIT_START;
            arith_state      <= A_IDLE;
            n_reg            <= 'd0;
            k_reg            <= 'd0;
            x_busy           <= 1'b0;
            rx_high_byte     <= 8'd0;
            value_phase      <= 1'b0;
            s1               <= 'd0;
            s2               <= 'd0;
            scratch0         <= 'd0;
            scratch1         <= 'd0;
            scratch2         <= 'd0;
            scratch3         <= 'd0;
            mul_context      <= M_INPUT;
            alu_context      <= U_INPUT;
            protocol_error   <= 1'b0;
            reply_valid      <= 1'b0;
            status_loaded    <= 1'b0;
            tx_byte_active   <= 1'b0;
            mul_start        <= 1'b0;
            tx_data          <= RESET_ACK;
        end else begin
            mul_start <= 1'b0;

            // Track whether a completed STATUS byte, rather than an in-flight
            // busy byte, was actually loaded into the SPI transmit shifter.
            if (spi_ss_n) begin
                tx_byte_active <= 1'b0;
            end else begin
                if (rx_data_strobe)
                    tx_byte_active <= 1'b0;
                if (tx_data_hold && !tx_byte_active) begin
                    tx_byte_active <= 1'b1;
                    if (proto_state == P_WAIT_RESULT)
                        status_loaded <= reply_valid && tx_data[7];
                end
            end

            case (proto_state)
                P_WAIT_START: begin
                    if (rx_data_strobe) begin
                        if (rx_data == CMD_START) begin
                            arith_state      <= A_IDLE;
                            n_reg            <= 'd0;
                            k_reg            <= 'd0;
                            x_busy           <= 1'b0;
                            rx_high_byte     <= 8'd0;
                            value_phase      <= 1'b0;
                            s1               <= 'd0;
                            s2               <= 'd0;
                            scratch0         <= 'd0;
                            scratch1         <= 'd0;
                            scratch2         <= 'd0;
                            scratch3         <= 'd0;
                            reply_valid      <= 1'b0;
                            status_loaded    <= 1'b0;
                            tx_byte_active   <= 1'b0;
                            tx_data          <= START_ACK;
                            proto_state      <= P_WAIT_START_ACK;
                        end else if (rx_data != CMD_NOP) begin
                            protocol_error <= 1'b1;
                            tx_data        <= 8'h00;
                        end
                    end
                end

                P_WAIT_START_ACK: begin
                    if (rx_data_strobe) begin
                        if (rx_data != CMD_NOP)
                            protocol_error <= 1'b1;
                        rx_high_byte <= 8'd0;
                        value_phase  <= 1'b0;
                        tx_data        <= 8'h00;
                        proto_state    <= P_RECEIVE_N;
                    end
                end

                P_RECEIVE_N: begin
                    if (rx_data_strobe) begin
                        tx_data <= 8'h00;
                        if ((VALUE_BYTES == 1) || value_phase) begin
                            rx_high_byte <= 8'd0;
                            value_phase  <= 1'b0;
                            if (invalid_n_event) begin
                                n_reg            <= 'd0;
                                scratch0         <= 'd0;
                                protocol_error   <= 1'b1;
                                reply_valid      <= 1'b1;
                                status_loaded    <= 1'b0;
                                tx_data          <= 8'hC0;
                                proto_state      <= P_WAIT_RESULT;
                                arith_state      <= A_PUBLISH;
                            end else begin
                                n_reg       <= rx_value_complete[WIDTH-1:0];
                                proto_state <= P_RECEIVE_K;
                            end
                        end else begin
                            rx_high_byte <= rx_data;
                            value_phase  <= 1'b1;
                        end
                    end
                end

                P_RECEIVE_K: begin
                    if (rx_data_strobe) begin
                        tx_data <= 8'h00;
                        if ((VALUE_BYTES == 1) || value_phase) begin
                            rx_high_byte <= 8'd0;
                            value_phase  <= 1'b0;
                            if (invalid_k_event) begin
                                k_reg            <= 'd0;
                                scratch0         <= 'd0;
                                protocol_error   <= 1'b1;
                                reply_valid      <= 1'b1;
                                status_loaded    <= 1'b0;
                                tx_data          <= 8'hC0;
                                proto_state      <= P_WAIT_RESULT;
                                arith_state      <= A_PUBLISH;
                            end else begin
                                k_reg          <= rx_value_complete[WIDTH-1:0];
                                scratch3       <= 'd0;
                                proto_state    <= P_STREAM_A;
                            end
                        end else begin
                            rx_high_byte <= rx_data;
                            value_phase  <= 1'b1;
                        end
                    end
                end

                P_STREAM_A: begin
                    if (rx_data_strobe) begin
                        tx_data <= 8'h00;
                        if ((VALUE_BYTES == 1) || value_phase) begin
                            rx_high_byte <= 8'd0;
                            value_phase  <= 1'b0;
                            if (invalid_a_event) begin
                                protocol_error  <= 1'b1;
                                reply_valid     <= 1'b1;
                                status_loaded   <= 1'b0;
                                scratch0        <= 'd0;
                                x_busy          <= 1'b0;
                                arith_state     <= A_PUBLISH;
                                proto_state     <= P_WAIT_RESULT;
                                tx_data         <= 8'hC0;
                            end else begin
                                scratch0      <= rx_value_complete[WIDTH-1:0];
                                x_busy         <= 1'b1;
                                scratch3       <=
                                    {{(WIDTH-COUNT_WIDTH){1'b0}},
                                     input_count + 1'b1};
                                if ((input_count + 1'b1) == n_reg)
                                    proto_state <= P_WAIT_RESULT;
                            end
                        end else begin
                            rx_high_byte <= rx_data;
                            value_phase  <= 1'b1;
                        end
                    end
                end

                P_WAIT_RESULT: begin
                    if (rx_data_strobe) begin
                        if (rx_data == CMD_NOP) begin
                            if (reply_valid && status_loaded) begin
                                tx_data <= answer_value[VALUE_BITS-1 -: 8];
                                value_phase <= (VALUE_BYTES > 1);
                                status_loaded <= 1'b0;
                                proto_state <= P_SEND_REPLY;
                            end else if (reply_valid) begin
                                tx_data <= protocol_error ? 8'hC0 : 8'h80;
                            end else begin
                                tx_data <= 8'h00;
                            end
                        end else begin
                            // Once N values have been accepted, any non-NOP
                            // byte is extra payload / invalid sequence.
                            protocol_error <= 1'b1;
                            tx_data <= reply_valid ? 8'hC0 : 8'h00;
                        end
                    end
                end

                P_SEND_REPLY: begin
                    if (rx_data_strobe) begin
                        if (rx_data == CMD_NOP) begin
                            if (!value_phase) begin
                                tx_data <= protocol_error ? 8'hC0 : 8'h80;
                                proto_state <= P_WAIT_RESULT;
                            end else begin
                                tx_data <= answer_value[7:0];
                                value_phase <= 1'b0;
                            end
                        end else begin
                            protocol_error  <= 1'b1;
                            tx_data         <= 8'hC0;
                            proto_state     <= P_WAIT_RESULT;
                            value_phase     <= 1'b0;
                        end
                    end
                end

                default: begin
                    proto_state     <= P_WAIT_RESULT;
                    arith_state     <= A_PUBLISH;
                    scratch0        <= 'd0;
                    protocol_error  <= 1'b1;
                    reply_valid     <= 1'b1;
                    status_loaded   <= 1'b0;
                    tx_data         <= 8'hC0;
                end
            endcase

            if (arithmetic_abort) begin
                arith_state <= A_PUBLISH;
                x_busy      <= 1'b0;
            end else begin
                case (arith_state)
                    A_IDLE: begin
                        if (x_busy) begin
                            mul_context <= M_INPUT;
                            arith_state <= A_LAUNCH;
                        end
                    end

                    A_LAUNCH: begin
                        if (!mul_busy) begin
                            mul_start   <= 1'b1;
                            arith_state <= A_WAIT;
                        end
                    end

                    A_WAIT: begin
                        if (mul_done) begin
                            case (mul_context)
                                M_INPUT: begin
                                    alu_context <= U_INPUT;
                                    arith_state <= A_ALU;
                                end
                                M_COMB_NUM: begin
                                    scratch0    <= mul_product;
                                    mul_context <= M_COMB_DEN;
                                    arith_state <= A_LAUNCH;
                                end
                                M_COMB_DEN: begin
                                    scratch2    <= mul_product;
                                    scratch1    <=
                                        {{(WIDTH-COUNT_WIDTH){1'b0}},
                                         comb_i_count + 1'b1};
                                    arith_state <= A_COMB_CHECK;
                                end
                                M_POW_RESULT: begin
                                    scratch1    <= mul_product;
                                    mul_context <= M_POW_BASE;
                                    arith_state <= A_LAUNCH;
                                end
                                M_POW_BASE: begin
                                    scratch2    <= mul_product;
                                    scratch3    <= scratch3 >> 1;
                                    arith_state <= A_POW_CHECK;
                                end
                                M_COEFF: begin
                                    scratch0    <= mul_product;
                                    scratch1    <= {{(WIDTH-1){1'b0}}, 1'b1};
                                    scratch2    <= n_reg - 1'b1;
                                    scratch3    <= MOD - 2'd2;
                                    alu_context <= U_INPUT_S1;
                                    arith_state <= A_POW_CHECK;
                                end
                                M_PAIR_STAGE: begin
                                    scratch2    <= mul_product;
                                    mul_context <= M_PAIR_FINISH;
                                    arith_state <= A_LAUNCH;
                                end
                                M_PAIR_FINISH: begin
                                    scratch1    <= mul_product;
                                    mul_context <= M_FINAL_S1;
                                    arith_state <= A_LAUNCH;
                                end
                                M_FINAL_S1: begin
                                    alu_context <= U_FINAL_PAIR;
                                    arith_state <= A_ALU;
                                end
                                M_FINAL_SQUARE: begin
                                    scratch3    <= mul_product;
                                    mul_context <= M_FINAL_PAIR;
                                    arith_state <= A_LAUNCH;
                                end
                                M_FINAL_PAIR: begin
                                    alu_context <= U_FINAL_ADD;
                                    arith_state <= A_ALU;
                                end
                                default: begin
                                    scratch0       <= 'd0;
                                    protocol_error <= 1'b1;
                                    arith_state     <= A_PUBLISH;
                                end
                            endcase
                        end
                    end

                    A_ALU: begin
                        case (alu_context)
                            U_INPUT: begin
                                s2          <= alu_result;
                                alu_context <= U_INPUT_S1;
                                arith_state <= A_ALU;
                            end
                            U_INPUT_S1: begin
                                s1          <= alu_result;
                                x_busy      <= 1'b0;
                                if (input_count == n_reg) begin
                                    if (k_reg == {{(WIDTH-1){1'b0}}, 1'b1}) begin
                                        scratch0    <= s2;
                                        arith_state <= A_PUBLISH;
                                    end else begin
                                        scratch0   <= {{(WIDTH-1){1'b0}}, 1'b1};
                                        scratch1   <= {{(WIDTH-1){1'b0}}, 1'b1};
                                        scratch2   <= {{(WIDTH-1){1'b0}}, 1'b1};
                                        if (comb_lower_side)
                                            scratch3 <= k_reg - 1'b1;
                                        else
                                            scratch3 <= n_reg - k_reg;
                                        arith_state <= A_COMB_CHECK;
                                    end
                                end else begin
                                    arith_state <= A_IDLE;
                                end
                            end
                            U_FINAL_PAIR: begin
                                scratch2    <= alu_result;
                                mul_context <= M_FINAL_SQUARE;
                                arith_state <= A_LAUNCH;
                            end
                            U_FINAL_ADD: begin
                                scratch0    <= alu_result;
                                arith_state <= A_PUBLISH;
                            end
                        endcase
                    end

                    A_COMB_CHECK: begin
                        if (comb_r_count == {COUNT_WIDTH{1'b0}}) begin
                            scratch0    <= {{(WIDTH-1){1'b0}}, 1'b1};
                            scratch1    <= {{(WIDTH-1){1'b0}}, 1'b1};
                            scratch2    <= n_reg - 1'b1;
                            scratch3    <= MOD - 2'd2;
                            alu_context <= U_INPUT_S1;
                            arith_state <= A_POW_CHECK;
                        end else if (comb_i_count > comb_r_count) begin
                            scratch1    <= {{(WIDTH-1){1'b0}}, 1'b1};
                            scratch3    <= MOD - 2'd2;
                            alu_context <= U_INPUT;
                            arith_state <= A_POW_CHECK;
                        end else begin
                            mul_context <= M_COMB_NUM;
                            arith_state <= A_LAUNCH;
                        end
                    end

                    A_POW_CHECK: begin
                        if (scratch3 == {WIDTH{1'b0}}) begin
                            if (!alu_context[0]) begin
                                mul_context <= M_COEFF;
                            end else begin
                                mul_context <= M_PAIR_STAGE;
                            end
                            arith_state <= A_LAUNCH;
                        end else if (scratch3[0]) begin
                            mul_context <= M_POW_RESULT;
                            arith_state <= A_LAUNCH;
                        end else begin
                            mul_context <= M_POW_BASE;
                            arith_state <= A_LAUNCH;
                        end
                    end

                    A_PUBLISH: begin
                        if (!reply_valid) begin
                            reply_valid   <= 1'b1;
                            status_loaded <= 1'b0;
                            tx_data       <= protocol_error ? 8'hC0 : 8'h80;
                        end
                    end

                    default: begin
                        scratch0       <= 'd0;
                        protocol_error <= 1'b1;
                        reply_valid    <= 1'b1;
                        status_loaded  <= 1'b0;
                        tx_data        <= 8'hC0;
                        arith_state    <= A_PUBLISH;
                    end
                endcase
            end
        end
    end

    spi_target #(
        .CPOL(1'b0),
        .CPHA(1'b0),
        .WIDTH(8),
        .LSB(1'b0)
    ) u_spi_target (
        .i_clk(clk),
        .i_rst_n(rst_n),
        .i_enable(1'b1),
        .i_ss_n(spi_ss_n),
        .i_sck(spi_sck),
        .i_mosi(spi_mosi),
        .o_miso(spi_miso),
        .o_miso_oe(spi_miso_en),
        .o_rx_data(rx_data),
        .o_rx_data_valid(),
        .o_rx_data_strobe(rx_data_strobe),
        .i_tx_data(tx_data),
        .o_tx_data_hold(tx_data_hold)
    );

endmodule


// One WIDTH-bit modular multiplier.  It deliberately avoids Verilog '*'.
// Add and double phases share one WIDTH+1-bit add/reduce datapath, giving
// exactly 2*WIDTH processing clocks after launch.
module modular_multiplier #(
    parameter integer WIDTH = 8,
    parameter [WIDTH-1:0] MOD = 251
) (
    input                  i_clk,
    input                  i_rst_n,
    input                  i_clear,
    input                  i_start,
    input      [WIDTH-1:0] i_lhs,
    input      [WIDTH-1:0] i_rhs,
    output reg             o_busy,
    output reg             o_done,
    output     [WIDTH-1:0] o_product
);

    localparam integer COUNT_WIDTH =
        (WIDTH <= 1) ? 1 : $clog2(WIDTH);
    localparam [COUNT_WIDTH-1:0] LAST_BIT = WIDTH - 1;

    reg [WIDTH-1:0] acc;
    reg [WIDTH-1:0] addend;
    reg [WIDTH-1:0] multiplier;
    reg [COUNT_WIDTH-1:0] bit_count;
    reg phase;

    wire [WIDTH:0] adder_left =
        phase ? {1'b0, addend} : {1'b0, acc};
    wire [WIDTH:0] adder_sum = adder_left + {1'b0, addend};
    wire [WIDTH:0] reduced_sum_wide =
        (adder_sum >= {1'b0, MOD}) ?
        (adder_sum - {1'b0, MOD}) : adder_sum;
    wire [WIDTH-1:0] reduced_sum =
        reduced_sum_wide[WIDTH-1:0];
    assign o_product = acc;

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            o_busy     <= 1'b0;
            o_done     <= 1'b0;
            acc        <= 'd0;
            addend     <= 'd0;
            multiplier <= 'd0;
            bit_count  <= 'd0;
            phase      <= 1'b0;
        end else if (i_clear) begin
            o_busy     <= 1'b0;
            o_done     <= 1'b0;
            acc        <= 'd0;
            addend     <= 'd0;
            multiplier <= 'd0;
            bit_count  <= 'd0;
            phase      <= 1'b0;
        end else begin
            o_done <= 1'b0;
            if (!o_busy) begin
                if (i_start) begin
                    o_busy     <= 1'b1;
                    acc        <= 'd0;
                    addend     <= i_lhs;
                    multiplier <= i_rhs;
                    bit_count  <= 'd0;
                    phase      <= 1'b0;
                end
            end else if (!phase) begin
                if (multiplier[0])
                    acc <= reduced_sum;
                phase <= 1'b1;
            end else begin
                addend     <= reduced_sum;
                multiplier <= multiplier >> 1;
                phase      <= 1'b0;
                if (bit_count == LAST_BIT) begin
                    o_busy    <= 1'b0;
                    o_done    <= 1'b1;
                end else begin
                    bit_count <= bit_count + 1'b1;
                end
            end
        end
    end

endmodule
